#!/usr/bin/env python3
"""Make the packaged app safe for any re-signing tool.

Re-sign tools break on three things this project produces by default:

* npm's CLI shims (``node_modules/.bin``) are symlinks that point at files
  outside the bundle's sealed layout. iOS never runs them, and several signing
  tools copy them as plain files, which leaves a sealed resource invalid.
* files copied out of a release archive frequently keep mode 0644, including
  ``NodeMobile`` itself, so dyld cannot map it after installation.
* leftover ``.DS_Store`` / ``.package-lock.json`` noise ends up sealed.

The script removes the shims, dereferences what is left, normalises permission
bits (directories 0755, files 0644, every Mach-O 0755) and reports which paths
still need a code signature.
"""
import json
import os
import pathlib
import shutil
import stat
import sys

MACHO_MAGICS = {
    b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
    b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce',
    b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
    b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca',
}
DROP_FILES = {'.DS_Store', '.package-lock.json'}


def is_macho(path):
    try:
        with open(path, 'rb') as handle:
            return handle.read(4) in MACHO_MAGICS
    except OSError:
        return False


ARM64 = 0x0100000C


def macho_architectures(path):
    """Return the CPU types a Mach-O carries; empty when it cannot be read."""
    import struct
    try:
        with open(path, 'rb') as handle:
            head = handle.read(8)
            if len(head) < 8:
                return []
            if head[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
                count = struct.unpack('>I', head[4:8])[0]
                stride = 20 if head[:4] == b'\xca\xfe\xba\xbe' else 32
                body = handle.read(stride * count)
                return [struct.unpack('>I', body[i * stride:i * stride + 4])[0] for i in range(count)]
            if head[:4] in (b'\xbe\xba\xfe\xca', b'\xbf\xba\xfe\xca'):
                return []
            endian = '<' if head[:4] in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe') else '>'
            return [struct.unpack(endian + 'I', head[4:8])[0]]
    except OSError:
        return []


def drop_cli_shims(app):
    dropped = 0
    for root, dirs, _files in os.walk(app):
        if os.path.basename(root) == 'node_modules' and '.bin' in dirs:
            shutil.rmtree(os.path.join(root, '.bin'))
            dirs.remove('.bin')
            dropped += 1
    return dropped


def drop_noise(app):
    dropped = 0
    for root, _dirs, files in os.walk(app):
        for name in files:
            if name in DROP_FILES:
                os.unlink(os.path.join(root, name))
                dropped += 1
    return dropped


def dereference_symlinks(app):
    links = []
    for root, dirs, files in os.walk(app):
        for name in list(dirs) + list(files):
            path = os.path.join(root, name)
            if os.path.islink(path):
                links.append(path)
    removed = replaced = 0
    for path in links:
        if not os.path.lexists(path):
            continue
        target = os.path.realpath(path)
        inside = target.startswith(os.path.realpath(app) + os.sep)
        if inside and os.path.exists(target):
            staged = path + '.deref'
            if os.path.isdir(target):
                shutil.copytree(target, staged, symlinks=False)
            else:
                shutil.copy2(target, staged)
            os.unlink(path)
            os.rename(staged, path)
            replaced += 1
        else:
            os.unlink(path)
            removed += 1
    return {'dereferenced': replaced, 'removedBroken': removed}


def normalise_modes(app):
    for root, dirs, files in os.walk(app):
        os.chmod(root, 0o755)
        for name in dirs:
            path = os.path.join(root, name)
            if not os.path.islink(path):
                os.chmod(path, 0o755)
        for name in files:
            path = os.path.join(root, name)
            if os.path.islink(path):
                continue
            os.chmod(path, 0o755 if is_macho(path) else 0o644)


def executables(app):
    """Return (framework bundles, loose Mach-O paths, non-arm64 Mach-O paths)."""
    app_path = pathlib.Path(app).resolve()
    frameworks, binaries, foreign = set(), set(), []
    for root, _dirs, files in os.walk(app):
        for name in files:
            path = pathlib.Path(root, name).resolve()
            if path.is_symlink() or not is_macho(path):
                continue
            if ARM64 not in macho_architectures(path):
                foreign.append(str(path.relative_to(app_path)))
            bundle = None
            for parent in path.parents:
                if parent == app_path:
                    break
                if parent.name.endswith('.framework'):
                    bundle = parent  # keep walking outwards: outermost wins
            if bundle is not None:
                frameworks.add(bundle)
            elif path.parent != app_path:
                # The bundle's own executable is sealed by signing the .app.
                binaries.add(path)
    depth = lambda p: len(p.parts)
    return (sorted(frameworks, key=depth, reverse=True),
            sorted(binaries, key=depth, reverse=True),
            sorted(foreign))


def main(argv):
    if len(argv) != 3:
        print('usage: prepare-bundle.py <NativeTavern.app> <macho-list-dir>', file=sys.stderr)
        return 2
    app, outdir = argv[1], pathlib.Path(argv[2])
    outdir.mkdir(parents=True, exist_ok=True)
    report = {
        'nodeModulesBinDirsRemoved': drop_cli_shims(app),
        'noiseFilesRemoved': drop_noise(app),
    }
    report.update(dereference_symlinks(app))
    normalise_modes(app)
    frameworks, binaries, foreign = executables(app)
    (outdir / 'frameworks.txt').write_text(''.join(f'{p}\n' for p in frameworks))
    (outdir / 'binaries.txt').write_text(''.join(f'{p}\n' for p in binaries))
    total = sum(len(files) for _r, _d, files in os.walk(app))
    report.update({
        'bundledFiles': total,
        'frameworkBundles': [p.name for p in frameworks],
        'looseMachO': len(binaries),
        'machOWithoutArm64': foreign[:20],
        'machOWithoutArm64Count': len(foreign),
    })
    remaining = [os.path.join(r, n) for r, d, f in os.walk(app) for n in d + f if os.path.islink(os.path.join(r, n))]
    report['symlinksRemaining'] = len(remaining)
    print(json.dumps(report, indent=2))
    return 1 if remaining else 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
