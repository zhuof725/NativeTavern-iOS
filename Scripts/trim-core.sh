#!/bin/sh
# Trims files from the vendored dependency tree that this app can never load.
#
# The goal is not a smaller dependency set — the core imports what it imports —
# but removing payloads that only exist for features the app does not offer.
# Each removal below is justified by where the file would be loaded from.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/Engine/core"
MODULES="$CORE/node_modules"

[ -d "$MODULES" ] || { echo "Engine/core/node_modules is missing" >&2; exit 1; }

# Let an interrupted or repeated run be a no-op rather than an error.
remove_if_present() {
    [ -e "$1" ] && rm -rf "$1" && echo "removed ${1#$CORE/}"
    return 0
}

# ONNX WebAssembly runtimes. These are the inference kernels for local embedding,
# captioning and speech models. They are fetched only when such a model actually
# runs; the app's chat path never does. The loader JS that references them stays,
# so nothing changes if a user later enables a local model — it would download.
for wasm in "$MODULES"/onnxruntime-web/dist/*.wasm; do
    remove_if_present "$wasm"
done

# Source maps: several megabytes of debug data no app build ever reads.
find "$MODULES" -name '*.map' -type f -delete 2>/dev/null || true

# The Webpack bundler itself. scripts/patch-core.sh skips compilation when the
# prebuilt bundle is present, and the import is dynamic, so this never loads.
remove_if_present "$MODULES/webpack"
remove_if_present "$MODULES/webpack-sources"
remove_if_present "$MODULES/terser-webpack-plugin"

# protobufjs's command-line frontend, which model runtimes do not use (they
# import the library, not the CLI).
remove_if_present "$MODULES/protobufjs/cli"

echo "Trimmed vendored dependency tree"
