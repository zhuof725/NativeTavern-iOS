#!/bin/sh
# Installs the packages the engine's own scaffolding needs.
#
# The vendored core (Engine/core) keeps upstream's full dependency tree, because
# its server imports them. The scaffolding next to it — transport, API, DOM,
# loader — needs only a DOM implementation and jQuery, declared in
# Engine/package.json. Both trees are installed separately and deliberately.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Engine"
npm install --omit=dev --no-audit --no-fund
echo "Engine scaffolding dependencies installed"
