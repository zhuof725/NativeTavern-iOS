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
