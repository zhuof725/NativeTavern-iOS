// Registers the module resolution hooks the upstream frontend needs.
//
// Upstream's page modules import root-absolute paths ('/scripts/utils.js') and a
// Webpack entry ('../lib.js'). Plain Node cannot resolve either, so a loader
// hook maps them onto the engine's own files. Registration is idempotent, and
// the caller must await it before importing any upstream module.
import { register } from 'node:module';

let pending = null;

export function registerResolvers() {
    pending ??= register(new URL('./loader.mjs', import.meta.url).href);
    return pending;
}
