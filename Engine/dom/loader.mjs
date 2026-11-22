// ESM resolve hook for running SillyTavern's browser modules under Node.
//
// Upstream's frontend is written for a page: it imports root-absolute paths
// ('/scripts/utils.js') and bundles a Webpack entry as ../lib.js. Node needs a
// real file path for the first and the built bundle for the second.
import path from 'node:path';
import fs from 'node:fs';

// The core location travels in the hook URL: this code runs in a worker thread
// whose environment and location differ from the engine's.
const CORE = new URL(import.meta.url).searchParams.get('core')
    || new URL('../core', import.meta.url).pathname;
const PUBLIC = path.join(CORE, 'public');
const BUNDLE = path.join(CORE, 'public/lib.bundle.js');

function existingFile(candidate) {
    for (const option of [candidate, candidate + '.js', candidate + '.mjs', path.join(candidate, 'index.js')]) {
        if (fs.existsSync(option) && fs.statSync(option).isFile()) return option;
    }
    return null;
}

export async function resolve(specifier, context, next) {
    // Webpack bundle: public/lib.js is a source entry, dist/lib.js is the build.
    if (specifier === '/lib.js' || specifier === './lib.js' || specifier === '../lib.js'
        || (specifier.endsWith('/lib.js') && path.basename(specifier) === 'lib.js')) {
        const base = context.parentURL ? path.dirname(new URL(context.parentURL).pathname) : PUBLIC;
        const target = specifier.startsWith('/') ? path.join(PUBLIC, specifier) : path.resolve(base, specifier);
        if (path.basename(target) === 'lib.js' && path.dirname(target) === PUBLIC) {
            return { url: `file://${BUNDLE}`, shortCircuit: true };
        }
    }
    // Root-absolute imports are page URLs, not filesystem paths.
    if (specifier.startsWith('/') && !specifier.startsWith('//')) {
        const hit = existingFile(path.join(PUBLIC, specifier));
        if (hit) return { url: new URL(`file://${hit}`).href, shortCircuit: true };
    }
    return next(specifier, context);
}
