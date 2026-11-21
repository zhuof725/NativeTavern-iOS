#!/bin/sh
# Prebuilds the library bundle the original frontend imports as '../lib.js'.
#
# Upstream runs Webpack on every server start. A phone should not: the bundle is
# a pure function of the pinned dependency versions, so it is built once here and
# shipped in the app. Scripts/patch-core.sh makes the server prefer it.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/Engine/core"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -d "$CORE/node_modules" ]; then
    echo "Engine/core/node_modules is missing; run Scripts/sync-core.sh first" >&2
    exit 1
fi

echo "Bundling frontend libraries"
npx --yes esbuild@0.25.10 "$ROOT/Engine/shim/lib-source.mjs" \
    --bundle --format=esm --platform=node --target=es2022 \
    --outfile="$CORE/public/lib.bundle.js" --log-level=warning

echo "Wrote $CORE/public/lib.bundle.js"
