// Loads SillyTavern's classic (non-module) page scripts in index.html order.
// They attach jQuery plugins (jQuery UI, select2, toastr, cropper…) that the
// original modules call directly, so they cannot simply be skipped.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

// Order matters and mirrors public/index.html.
export const CLASSIC_SCRIPTS = [
    'lib/polyfill.js',
    'lib/jquery-ui.min.js',
    'lib/jquery.transit.min.js',
    'lib/jquery-cookie-1.4.1.min.js',
    'lib/jquery.ui.touch-punch.min.js',
    'lib/cropper.min.js',
    'lib/jquery-cropper.min.js',
    'lib/toastr.min.js',
    'lib/select2.min.js',
    'lib/select2-search-placeholder.js',
    'lib/pagination.js',
    'lib/toolcool-color-picker.js',
    'lib/jquery.izoomify.js',
];

/**
 * Makes script insertion behave like a browser, for the core's own module loads.
 *
 * SillyTavern activates page extensions by inserting <script type=module src=…>
 * and awaiting the element's load event. Nothing fetches those URLs here, so
 * without this the await never settles and the core's first load stalls. The
 * engine runs the same module file and then fires load, which is exactly what a
 * browser does — the extension code itself is upstream's, unmodified.
 */
export function installScriptExecution(publicDir, window) {
    const body = window.document.body;
    const head = window.document.head;

    // Stylesheets carry no behaviour, but the core still awaits their load
    // events before it considers an extension active.
    head.appendChild = ((original) => (node) => {
        if (node?.tagName === 'LINK' && node.getAttribute('href')) {
            queueMicrotask(() => node.dispatchEvent(new window.Event('load')));
            return node;
        }
        return original(node);
    })(head.appendChild.bind(head));

    // Script elements are handled entirely here: appending them to the real DOM
    // would make the DOM implementation try to fetch them (it cannot) and emit
    // an error event before the module has even been executed.
    const appendChild = body.appendChild.bind(body);
    body.appendChild = (node) => {
        if (node?.tagName !== 'SCRIPT' || !node.getAttribute('src')) {
            return appendChild(node);
        }

        const source = String(node.getAttribute('src'));
        const file = path.join(publicDir, source.replace(/^\/+/, ''));

        // The core awaits this element's load event; settle it after the module
        // has actually run, which is what a browser does.
        queueMicrotask(() => {
            if (!fs.existsSync(file)) {
                node.dispatchEvent(new window.Event('error'));
                return;
            }
            import(new URL(`file://${file}`).href).then(
                () => node.dispatchEvent(new window.Event('load')),
                () => node.dispatchEvent(new window.Event('error')),
            );
        });

        // Keep the element visible to the core's "already inserted?" check
        // without handing it to the DOM's own script fetcher.
        return node;
    };
}

export function loadClassicScripts(publicDir, window) {
    const loaded = [];
    const failed = [];
    const context = window.happyDOM?.context ?? vm.createContext(window);

    for (const relative of CLASSIC_SCRIPTS) {
        const file = path.join(publicDir, relative);
        if (!fs.existsSync(file)) {
            failed.push([relative, 'missing']);
            continue;
        }
        try {
            vm.runInContext(fs.readFileSync(file, 'utf8'), context, { filename: file, timeout: 20000 });
            loaded.push(relative);
        } catch (error) {
            failed.push([relative, error.message.split('\n')[0]]);
        }
    }
    return { loaded, failed };
}
