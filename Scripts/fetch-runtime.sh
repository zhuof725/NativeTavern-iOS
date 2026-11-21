#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This script prepares the iOS framework on macOS; it does not compile iOS on Linux.' >&2
  exit 1
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
lock="$root/Runtime/node-mobile.lock.json"
repository="$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).repository' "$lock")"
version="$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version' "$lock")"
asset="$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).asset' "$lock")"
expected="$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).sha256' "$lock")"
mkdir -p "$root/Vendor"
if [[ -e "$root/Vendor/NodeMobile.xcframework" ]]; then
  echo 'Vendor/NodeMobile.xcframework already exists; refusing to replace it implicitly.' >&2
  exit 1
fi
stage="$(mktemp -d "$root/Vendor/.runtime.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
curl --fail --location --retry 3 --output "$stage/runtime.zip" \
  "https://github.com/$repository/releases/download/v$version/$asset"
printf '%s  %s\n' "$expected" "$stage/runtime.zip" | shasum -a 256 -c -
unzip -q "$stage/runtime.zip" -d "$stage/unpacked"
[[ -d "$stage/unpacked/NodeMobile.xcframework" ]] || { echo 'Archive layout is not the expected NodeMobile.xcframework.' >&2; exit 1; }
mv "$stage/unpacked/NodeMobile.xcframework" "$root/Vendor/NodeMobile.xcframework"
echo 'Pinned NodeMobile framework prepared. Native app compilation and signing are separate steps.'
