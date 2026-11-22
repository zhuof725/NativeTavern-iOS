# Vendored upstream core

This directory is a copy of SillyTavern, not a fork of its source. Details:

| Field | Value |
|---|---|
| Upstream | https://github.com/SillyTavern/SillyTavern |
| Revision | `82b64a45c34facbc98ff4b9f33c067d3ccab6a17` (release, 2026-11-19) |
| Regenerate | `npm run core:sync` |
| Patched files | `src/middleware/webpack-serve.js` only |

## Why it is vendored rather than installed

The app must run SillyTavern's own server and its own frontend modules inside
the app process. That requires the source tree, not a package dependency: the
frontend core is not published as a package and its module graph refers to page
URLs (`/scripts/…`) that only exist inside this tree.

## What differs from upstream

One file, one behaviour: `src/middleware/webpack-serve.js` skips the Webpack run
when `public/lib.bundle.js` is present. Upstream compiles that bundle on every
server start; a phone should not run a bundler on cold start, so the bundle is
built once by `Scripts/build-lib-bundle.sh` and shipped.

`Scripts/patch-core.sh` contains the exact edit and fails loudly if the upstream
file no longer matches the expected shape.

## Removed for size

`public/webfonts`, `public/sounds`, `public/css`, most of `public/img`,
`src/electron`, `src/tokenizers` (16 MB of model files the app does not load),
and the demo character/background content. `public/img/ai4.png` is kept because
upstream's character creation writes every new card from that default avatar.
Nothing else is removed.

## Dependencies

`Engine/core/node_modules` holds upstream's production dependency tree, copied
by `Scripts/sync-core.sh`. It is not committed; it is regenerated.

## Page extensions removed

`public/scripts/extensions/` keeps only `regex/` (whose `engine.js` the core
imports directly) and `shared.js`. Everything else there is a web-frontend
plugin: each one activates by injecting `<script>`/`<link>` tags and expecting a
browser to load them. The engine runs the core headlessly, so those activations
never complete and the first load stalls.

They are not part of the chat core: world info, macros and prompt assembly do
not import them. Removing them is a deployment decision, not a behaviour change,
and it is documented here so it is not mistaken for upstream content.
