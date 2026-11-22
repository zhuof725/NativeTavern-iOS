#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'iOS archives require macOS/Xcode.' >&2; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
bundle_id="${BUNDLE_IDENTIFIER:-org.example.nativetavern}"
[[ "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$ ]] || { echo 'Invalid bundle identifier.' >&2; exit 1; }
# "-" signs ad hoc. Every Mach-O then carries a real LC_CODE_SIGNATURE and the
# bundle carries a valid CodeResources seal, so a re-signing tool only has to
# replace the signature instead of inventing the slot itself. Override with
# SIGN_IDENTITY=<identity> when a keychain identity is available.
sign_identity="${SIGN_IDENTITY:--}"
artifact="NativeTavern-adhoc-signed.ipa"
output="$root/artifacts"
mkdir -p "$output"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/native-tavern-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT
archive="$work/NativeTavern.xcarchive"
xcodebuild \
  -project NativeTavern.xcodeproj \
  -scheme NativeTavern \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  COMPILER_INDEX_STORE_ENABLE=NO \
  archive 2>&1 | tee "$output/xcodebuild.log"
app="$archive/Products/Applications/NativeTavern.app"
[[ -d "$app" ]] || { echo 'Xcode did not produce the device app.' >&2; exit 1; }
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
[[ -f "$app/$executable" && -f "$app/Frameworks/NodeMobile.framework/NodeMobile" && -f "$app/Engine/boot.mjs" ]] || {
  echo 'Archive is missing the app executable, embedded runtime or engine entry.' >&2; exit 1;
}
# The engine must ship the vendored core it runs, not just its entry point.
[[ -f "$app/Engine/core/server.js" && -f "$app/Engine/core/public/script.js" ]] || {
  echo 'Archive is missing the embedded SillyTavern core.' >&2; exit 1;
}
[[ -d "$app/Engine/core/node_modules" ]] || {
  echo 'Archive is missing the core runtime dependencies.' >&2; exit 1;
}
xcrun lipo "$app/$executable" -verify_arch arm64
xcrun lipo "$app/Frameworks/NodeMobile.framework/NodeMobile" -verify_arch arm64

# npm ships CLI shims as symlinks and the runtime archive ships mode 0644
# binaries; both break re-signing tools and dyld. Normalise before sealing.
python3 Scripts/prepare-bundle.py "$app" "$work/bundle"
xattr -cr "$app"

echo "Signing identity: $sign_identity"
signed=0
for list in "$work/bundle/frameworks.txt" "$work/bundle/binaries.txt"; do
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    codesign --force --sign "$sign_identity" --timestamp=none "$target"
    signed=$((signed + 1))
  done < "$list"
done
codesign --force --sign "$sign_identity" --timestamp=none "$app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dvv "$app" 2>&1 | sed -n '1,8p'
echo "Sealed $signed nested binaries and the app bundle."

mkdir -p "$work/package/Payload"
ditto "$app" "$work/package/Payload/NativeTavern.app"
ipa="$output/$artifact"
[[ ! -e "$ipa" ]] || { echo 'Refusing to replace an existing IPA.' >&2; exit 1; }
(cd "$work/package" && /usr/bin/zip -qry "$ipa" Payload)
python3 Scripts/validate-ipa.py "$ipa"
node --input-type=module - "$output/BUILD-INFO.json" "$artifact" <<'NODE'
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
const receipt = {
  artifact: process.argv[3],
  signing: 'ad hoc signed on the runner; a device certificate must re-sign it before installation',
  signatureState: 'Mach-O CodeDirectory and bundle CodeResources already present',
  applicationStage: 'M1 upstream core embedded',
  sillyTavernCoreIntegrated: true,
  sourceCommit: process.env.GITHUB_SHA || null,
  repository: process.env.GITHUB_REPOSITORY || null,
  workflowRun: process.env.GITHUB_RUN_ID || null,
  builtAt: new Date().toISOString(),
  xcode: execFileSync('xcodebuild', ['-version'], { encoding: 'utf8' }).trim(),
};
fs.writeFileSync(process.argv[2], JSON.stringify(receipt, null, 2) + '\n');
NODE
(cd "$output" && shasum -a 256 "$artifact" BUILD-INFO.json > SHA256SUMS)
echo "$artifact packaged with the upstream SillyTavern core, ad hoc signed and ready to re-sign."
