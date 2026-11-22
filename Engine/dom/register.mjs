// Registers the module resolution hooks the upstream frontend needs.
//
// Upstream's page modules import root-absolute paths ('/scripts/utils.js') and a
// Webpack entry ('../lib.js'). Plain Node cannot resolve either, so a loader
// hook maps them onto the engine's own files. Registration is idempotent, and
// the caller must await it before importing any upstream module: Node finishes
// hooking asynchronously, and a module graph loaded in between resolves against
// the built-in loader only.
import { register } from 'node:module';
import path from 'node:path';

let pending = null;

export function registerResolvers() {
    pending ??= (async () => {
        // Hooks run in a separate thread with their own environment, so the core
        // location is passed as a URL parameter rather than read from env vars.
        const coreRoot = path.resolve(new URL('../core', import.meta.url).pathname);
        const hook = new URL('./loader.mjs', import.meta.url);
        hook.searchParams.set('core', coreRoot);
        await register(hook.href);
        // Let the hook worker come up before the first upstream import.
        await new Promise((resolve) => setTimeout(resolve, 100));
    })();
    return pending;
}
