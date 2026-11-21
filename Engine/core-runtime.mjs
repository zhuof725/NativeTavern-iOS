// Runs the ORIGINAL SillyTavern frontend core (public/script.js and its module
// graph) inside the app's Node runtime, headlessly.
//
// Why this exists: SillyTavern's real "chat brain" — world info scanning, macro
// evaluation, prompt assembly — lives in the frontend modules, not in src/.
// Reimplementing those in Swift would be a different program. So the original
// modules run here on a minimal DOM and talk to the original backend.
import path from 'node:path';
import { registerResolvers } from './dom/register.mjs';
import { loadDomEnvironment } from './dom/environment.mjs';
import { loadClassicScripts } from './dom/classic.mjs';
import { installFetchXHR } from './dom/xhr.mjs';
import { installLoopbackFetch } from './dom/loopback.mjs';

/**
 * @param {object} options
 * @param {string} options.upstream loopback base URL of the upstream core
 * @param {string} options.coreRoot directory containing upstream public/ and src/
 * @param {(message: string) => void} [options.log]
 */
export async function startCore({ upstream, coreRoot, log = () => {} }) {
    // The page's module graph needs these before the first upstream import.
    await registerResolvers();
    const publicDir = path.join(coreRoot, 'public');

    const { window } = loadDomEnvironment({ url: `${upstream}/`, coreRoot });
    await loadJQuery(window);
    installToastr(window);
    globalThis.fixToastrForDialogs = () => {};
    installFetchXHR(window);
    installLoopbackFetch({ upstream });

    const classic = loadClassicScripts(publicDir, window);
    if (classic.failed.length) log(`classic scripts not loaded: ${JSON.stringify(classic.failed)}`);

    // index.html loads these as separate module entries before script.js.
    for (const entry of ['lib/structured-clone/monkey-patch.js', 'lib/swiped-events.js', 'lib/eventemitter.js', 'scripts/i18n.js']) {
        await import(`file://${path.join(publicDir, entry)}`);
    }

    const core = await import(`file://${path.join(publicDir, 'script.js')}`);

    const modules = {
        worldInfo: await import(`file://${path.join(publicDir, 'scripts/world-info.js')}`),
        macros: await import(`file://${path.join(publicDir, 'scripts/macros.js')}`),
        openai: await import(`file://${path.join(publicDir, 'scripts/openai.js')}`),
        powerUser: await import(`file://${path.join(publicDir, 'scripts/power-user.js')}`),
        tokenizers: await import(`file://${path.join(publicDir, 'scripts/tokenizers.js')}`),
        chats: await import(`file://${path.join(publicDir, 'scripts/chats.js')}`),
        charData: await import(`file://${path.join(publicDir, 'scripts/char-data.js')}`),
        extensions: await import(`file://${path.join(publicDir, 'scripts/extensions.js')}`),
    };

    await waitForFirstLoad(log);

    return { core, modules, window };
}

/**
 * Waits until the core's own first-load path has finished.
 *
 * script.js runs firstLoadInit on DOM ready; it fetches settings and builds the
 * prompt manager. Calling into world info or the prompt pipeline before that
 * gives silently wrong answers (no books, empty prompts), so this waits for the
 * observable end state instead of a fixed delay.
 */
async function waitForFirstLoad(log, timeoutMs = 180000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (macroRegistrySize() > 0) return;
        await new Promise((resolve) => setTimeout(resolve, 200));
    }
    log('first load did not complete in time; continuing');
}

/** Macro registration count, read through the original parser's own API. */
function macroRegistrySize() {
    try {
        const context = globalThis.SillyTavern?.getContext?.();
        if (!context) return 0;
        // A loaded core resolves macros through this function.
        return String(context.substituteParams?.('{{noop}}') ?? '').includes('{{') === false ? 1 : 0;
    } catch {
        return 0;
    }
}

async function loadJQuery(window) {
    const jq = (await import('jquery')).default;
    const $ = jq.fn?.jquery ? jq : jq(window);
    globalThis.jQuery = $;
    globalThis.$ = $;
    window.jQuery = $;
    window.$ = $;
    return $;
}

function installToastr(window) {
    const container = () => {
        const $ = globalThis.jQuery;
        let node = $('#toast-container');
        if (!node.length) node = $('<div id="toast-container"></div>').appendTo('body');
        return node;
    };
    const make = () => {
        const fn = () => null;
        fn.error = fn; fn.success = fn; fn.info = fn; fn.warning = fn; fn.warn = fn;
        fn.remove = () => {}; fn.clear = () => {}; fn.subscribe = () => ({ unsubscribe() {} });
        fn.options = {}; fn.getContainer = container;
        return fn;
    };
    globalThis.toastr = make();
    window.toastr = globalThis.toastr;
}
