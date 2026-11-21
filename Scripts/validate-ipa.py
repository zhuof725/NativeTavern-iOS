#!/usr/bin/env python3
"""Validate an unsigned device IPA without extracting or executing its contents."""
import json
import pathlib
import plistlib
import struct
import sys
import zipfile

ARM64 = 0x0100000C


def cpu_types(header):
    magic = header[:4]
    thin = {b'\xcf\xfa\xed\xfe': '<', b'\xfe\xed\xfa\xcf': '>'}
    if magic in thin and len(header) >= 8:
        return [struct.unpack_from(thin[magic] + 'I', header, 4)[0]]
    fat = {b'\xca\xfe\xba\xbe': ('>', 20), b'\xbe\xba\xfe\xca': ('<', 20),
           b'\xca\xfe\xba\xbf': ('>', 32), b'\xbf\xba\xfe\xca': ('<', 32)}
    if magic in fat and len(header) >= 8:
        endian, stride = fat[magic]
        count = struct.unpack_from(endian + 'I', header, 4)[0]
        if 0 < count <= 32 and len(header) >= 8 + stride * count:
            return [struct.unpack_from(endian + 'I', header, 8 + stride * index)[0] for index in range(count)]
    raise ValueError('A required executable is not a supported Mach-O file.')


def validate(filename):
    with zipfile.ZipFile(filename) as archive:
        names = set(archive.namelist())
        for name in names:
            path = pathlib.PurePosixPath(name)
            if path.is_absolute() or '..' in path.parts:
                raise ValueError('Unsafe archive path.')
        apps = {name.split('/')[1] for name in names if name.startswith('Payload/')
                and len(name.split('/')) > 2 and name.split('/')[1].endswith('.app')}
        if len(apps) != 1:
            raise ValueError('Expected exactly one app under Payload/.')
        prefix = 'Payload/' + apps.pop() + '/'
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        if 'iPhoneOS' not in info.get('CFBundleSupportedPlatforms', []):
            raise ValueError('This is not an iPhoneOS device archive.')
        executable = info.get('CFBundleExecutable', '')
        if not executable or '/' in executable or executable in ('.', '..'):
            raise ValueError('Invalid app executable name.')
        required = [executable, 'Frameworks/NodeMobile.framework/NodeMobile',
                    'Engine/boot.mjs', 'Engine/host.mjs']
        for relative in required:
            if prefix + relative not in names:
                raise ValueError('Missing archive component: ' + relative)
        for relative in required[:2]:
            with archive.open(prefix + relative) as binary:
                if ARM64 not in cpu_types(binary.read(4096)):
                    raise ValueError('ARM64 is missing: ' + relative)
        damaged = archive.testzip()
        if damaged:
            raise ValueError('CRC verification failed.')
        return {'bundleIdentifier': info.get('CFBundleIdentifier'),
                'minimumOSVersion': info.get('MinimumOSVersion'),
                'deviceARM64': True, 'embeddedNodeMobile': True, 'crc': 'valid'}


if __name__ == '__main__':
    try:
        print(json.dumps(validate(sys.argv[1]), indent=2))
    except (ValueError, KeyError, IndexError, OSError, zipfile.BadZipFile) as error:
        print('IPA validation failed: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
