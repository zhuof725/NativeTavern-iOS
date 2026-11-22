#!/bin/sh
# Vendors upstream SillyTavern into Engine/core and applies the engine patches.
#
# Run this to move to a newer upstream revision. It is deliberately explicit:
# the vendored core is a copy, so the patch script is the whole record of how
# the app's engine differs from upstream.
set -eu

REVISION="${1:-82b64a45c34facbc98ff4b9f33c067d3ccab6a17}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/Engine/core"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Fetching SillyTavern at $REVISION"
git clone --filter=blob:none --no-checkout https://github.com/SillyTavern/SillyTavern.git "$WORK/upstream" >/dev/null
git -C "$WORK/upstream" fetch --depth 1 origin "$REVISION" >/dev/null
git -C "$WORK/upstream" checkout -q FETCH_HEAD

echo "Installing production dependencies"
(cd "$WORK/upstream" && npm install --omit=dev --no-audit --no-fund >/dev/null 2>&1) || {
    echo "npm install failed; the engine cannot start without upstream's runtime dependencies" >&2
    exit 1
}

echo "Vendoring into Engine/core"
rm -rf "$CORE"
mkdir -p "$CORE"
cp -R "$WORK/upstream/src" "$WORK/upstream/public" "$CORE/"
cp "$WORK/upstream/server.js" "$WORK/upstream/webpack.config.js" "$WORK/upstream/plugins.js" "$CORE/"
cp "$WORK/upstream/package.json" "$CORE/package.json"
cp -R "$WORK/upstream/node_modules" "$CORE/node_modules"
cp -R "$WORK/upstream/default" "$CORE/default"

# Files a phone never serves or executes.
rm -rf "$CORE/public/webfonts" "$CORE/public/sounds" "$CORE/public/css" \
       "$CORE/src/electron" "$CORE/src/tokenizers" \
       "$CORE/default/content/backgrounds" "$CORE/default/content/Seraphina"
mkdir -p "$CORE/default/content/backgrounds"

# `public/img` is removed except for the default character avatar. Upstream's
# /api/characters/create writes every new card from DEFAULT_AVATAR_PATH
# (public/img/ai4.png); without it, creating a character fails on the device.
mkdir -p "$CORE/public/img"
if [ -f "$ROOT/Engine/default-avatar.png" ]; then
    cp "$ROOT/Engine/default-avatar.png" "$CORE/public/img/ai4.png"
fi

echo "Applying engine patches"
sh "$ROOT/Scripts/patch-core.sh" "$CORE"

echo "Building the frontend library bundle"
sh "$ROOT/Scripts/build-lib-bundle.sh"

echo "Done. Vendored revision: $REVISION"
