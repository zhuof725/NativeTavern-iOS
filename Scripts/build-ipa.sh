#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'iOS archives require macOS/Xcode.' >&2; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
bundle_id="${BUNDLE_IDENTIFIER:-org.example.nativetavern}"
[[ "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$ ]] || { echo 'Invalid bundle identifier.' >&2; exit 1; }
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
mkdir -p "$work/package/Payload"
ditto "$app" "$work/package/Payload/NativeTavern.app"
ipa="$output/NativeTavern-unsigned.ipa"
[[ ! -e "$ipa" ]] || { echo 'Refusing to replace an existing IPA.' >&2; exit 1; }
(cd "$work/package" && /usr/bin/zip -qry "$ipa" Payload)
python3 Scripts/validate-ipa.py "$ipa"
node --input-type=module - "$output/BUILD-INFO.json" <<'NODE'
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
const receipt = {
  artifact: 'NativeTavern-unsigned.ipa',
  signing: 'unsigned; re-signing is required before installation',
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
(cd "$output" && shasum -a 256 NativeTavern-unsigned.ipa BUILD-INFO.json > SHA256SUMS)
echo 'Unsigned device IPA packaged, with the upstream SillyTavern core embedded.'
