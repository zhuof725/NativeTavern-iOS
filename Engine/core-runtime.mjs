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
import { loadClassicScripts, installScriptExecution } from './dom/classic.mjs';
import { installFetchXHR } from './dom/xhr.mjs';
import { installLoopbackFetch } from './dom/loopback.mjs';

/**
 * @param {object} options
 * @param {string} options.upstream loopback base URL of the upstream core
 * @param {string} options.coreRoot directory containing upstream public/ and src/
 * @param {(message: string) => void} [options.log]
 */
/** Remembers the prompt order the manager started with, across settings reloads. */
let initialPromptOrder = null;

export async function startCore({ upstream, coreRoot, log = () => {} }) {
    // Re-initialising means new module instances; nothing from a previous run applies.
    initialPromptOrder = null;
    // The page's module graph needs these before the first upstream import.
    await registerResolvers();
    const publicDir = path.join(coreRoot, 'public');

    const { window } = loadDomEnvironment({ url: `${upstream}/`, coreRoot });
    await loadJQuery(window);
    installToastr(window);
    globalThis.fixToastrForDialogs = () => {};
    installFetchXHR(window);
    installLoopbackFetch({ upstream, window, coreRoot });
    installScriptExecution(publicDir, window);

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
        personas: await import(`file://${path.join(publicDir, 'scripts/personas.js')}`),
    };

    const appReady = await waitForSettings(core, log);
    await completeInit(core, modules, log);

    // The page's own startup keeps running after settings are applied — model
    // lists, personas, tokenizers, slash commands. Generating before it ends
    // makes upstream wait on initialisation events that are still in flight,
    // which can hang the request. The engine is only "ready" once the core
    // itself says so.
    await appReady;

    return { core, modules, window };
}

/**
 * Waits until the core has loaded its settings.
 *
 * script.js runs its own initialisation when the page reports ready; that path
 * ends with the settings being applied. Everything the engine exposes (world
 * info, prompts, model choice) depends on that having happened, so it is waited
 * for explicitly rather than assumed.
 */
async function waitForSettings(core, log, timeoutMs = 180000) {
    const appReady = new Promise((resolve) => {
        const hook = setInterval(() => {
            const eventSource = globalThis.SillyTavern?.getContext?.()?.eventSource;
            if (!eventSource?.once) return;
            clearInterval(hook);
            eventSource.once('app_ready', () => {
                log('core app ready');
                resolve();
            });
        }, 100);
        // A startup step can legitimately never finish in a headless runtime.
        // The engine still has to come up, so this is a warning, not a failure.
        setTimeout(() => {
            clearInterval(hook);
            log('WARNING: core app_ready was not observed in time');
            resolve();
        }, timeoutMs).unref?.();
    });

    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        const context = globalThis.SillyTavern?.getContext?.();
        // A loaded core reports a character list; settings populate the prompt
        // manager lazily on first use, so this is the observable end state.
        if (context && Array.isArray(context.characters)) {
            const usernames = context.name1;
            if (usernames) {
                log('core settings loaded');
                return appReady;
            }
        }
        await new Promise((resolve) => setTimeout(resolve, 200));
    }
    log('WARNING: core settings did not load in time');
    return appReady;
}

/**
 * Finishes the initialisation the page's own load path would have completed.
 *
 * The core's startup continues after the settings step (macro registry, world
 * info list, prompt manager). When that sequence is interrupted — a step that
 * touches browser-only APIs — the engine runs the remaining registration
 * itself, using the core's own exported functions.
 */
async function completeInit(core, modules, log) {
    try {
        modules.macros.initMacros();
    } catch (error) {
        log(`macro registration failed: ${error.message}`);
    }

    try {
        await modules.worldInfo.updateWorldInfoList();
    } catch (error) {
        log(`world info list unavailable: ${error.message}`);
    }

    // Characters back the chat list, world-info bindings and the prompt's
    // character fields; the page loads them during startup. This is required
    // for chats to open at all, so a failure is reported rather than ignored.
    try {
        await core.getCharacters();
        log(`characters loaded: ${globalThis.SillyTavern.getContext().characters.length}`);
    } catch (error) {
        log(`character list unavailable: ${error.message}`);
    }

    try {
        // The prompt manager is created lazily when the API changes in the UI.
        // The engine has no UI, so it creates it now; this is upstream's own
        // constructor, and it reads the settings the core just loaded.
        modules.openai.setupChatCompletionPromptManager(modules.openai.oai_settings);

        // The saved settings key their prompt order by a different sentinel id
        // than the manager's own configuration uses. Upstream's sanitizer adds a
        // matching entry when it first starts; do the same so the manager has a
        // prompt order to build a collection from.
        const manager = modules.openai.promptManager;
        const dummyId = manager?.configuration?.promptOrder?.dummyId;
        if (manager && dummyId !== undefined) {
            const order = manager.serviceSettings.prompt_order ?? [];
            if (!order.some((entry) => String(entry.character_id) === String(dummyId))) {
                order.push({ character_id: dummyId, order: order[0]?.order ?? [] });
                manager.serviceSettings.prompt_order = order;
                if (typeof manager.updatePrompts === 'function') {
                    manager.updatePrompts(manager.serviceSettings.prompts);
                }
            }
        }
        const collection = manager?.getPromptCollection('normal');
        log(`prompt manager ready: ${(collection?.collection ?? []).length} prompts`);
    } catch (error) {
        log(`prompt manager unavailable: ${error.message}`);
    }

    // The native client only speaks chat completions, but upstream's default
    // settings use the Horde. Leaving it on Horde makes the first generation
    // wait on an external service that the app never exposes. Selecting the
    // chat-completion API here is the same state change the settings UI makes.
    try {
        const context = globalThis.SillyTavern.getContext();
        if (context.mainApi !== 'openai') {
            // The select's change handler is not bound yet at this point in the
            // page's startup, so the core's own switch function is called
            // directly; it assigns main_api and refreshes its dependent state.
            core.changeMainAPI('openai');
            globalThis.$('#main_api').val('openai');
            log(`main API set to openai (was ${context.mainApi ?? 'undefined'})`);
        }
    } catch (error) {
        log(`main API switch failed: ${error.message}`);
    }
}

/**
 * Keeps the prompt order alive across a settings reload.
 *
 * The core's settings loader replaces the whole service settings object from the
 * saved file, whose prompt order is keyed by a different sentinel id than the
 * manager uses. Upstream only fixes that up on first initialisation, so a reload
 * otherwise leaves the manager with no prompt order and silently drops chat
 * history and the main prompt from every request.
 */
export function restorePromptOrder(modules) {
    const manager = modules?.openai?.promptManager;
    const dummyId = manager?.configuration?.promptOrder?.dummyId;
    if (!manager || dummyId === undefined) return;

    const order = manager.serviceSettings.prompt_order ?? [];
    const hasOwnEntry = order.some((entry) => String(entry.character_id) === String(dummyId));

    // Snapshot the good state while it exists, so a later reload can be undone.
    if (hasOwnEntry && !initialPromptOrder) {
        initialPromptOrder = order.map((entry) => ({ ...entry, order: (entry.order ?? []).map((item) => ({ ...item })) }));
        return;
    }
    if (hasOwnEntry) return;

    const template = initialPromptOrder?.find((entry) => String(entry.character_id) === String(dummyId));
    order.push({ character_id: dummyId, order: template?.order ?? order[0]?.order ?? [] });
    manager.serviceSettings.prompt_order = order;
    if (typeof manager.updatePrompts === 'function') manager.updatePrompts(manager.serviceSettings.prompts);
}

async function loadJQuery(window) {
    const jq = (await import('jquery')).default;
    const $ = jq.fn?.jquery ? jq : jq(window);
    globalThis.jQuery = $;
    globalThis.$ = $;
    window.jQuery = $;
    window.$ = $;
    installSelectedPseudoClass($, window);
    return $;
}

/**
 * Teaches jQuery's `:selected` selector to work on this DOM.
 *
 * The core's own settings loader ends with `$('#chat_completion_source').trigger('change')`,
 * and that handler reads `$(this).find(':selected').val()`. In happy-dom,
 * `querySelectorAll` accepts `:selected` but matches nothing, so jQuery never
 * falls back to its own selector engine and the handler receives `undefined`.
 * Upstream then stores the literal string "undefined" as the chat completion
 * source, which makes every generation request fail with a 400 — on a code path
 * the app cannot avoid. Handling the selector here keeps upstream's code intact.
 */
function installSelectedPseudoClass($, window) {
    const nativeFind = $.find;
    if (!nativeFind || nativeFind.__ntSelected) return;

    function findWithSelected(selector, context, results, seed) {
        if (typeof selector === 'string' && selector.includes(':selected')) {
            const base = selector.replace(/:selected/g, '').trim() || '*';
            const scope = context?.querySelectorAll ? context : window.document;
            try {
                const found = [...scope.querySelectorAll(base)].filter((node) => node.selected === true);
                if (results) {
                    results.push(...found);
                    return results;
                }
                return found;
            } catch {
                // Unusual compound selector: let jQuery decide.
            }
        }
        return nativeFind.call(this, selector, context, results, seed);
    }

    // `jQuery.find` carries helper methods (attr, matchesSelector…) used by
    // `.val()`, so they have to survive the replacement.
    for (const key of Object.keys(nativeFind)) findWithSelected[key] = nativeFind[key];
    findWithSelected.__ntSelected = true;
    $.find = findWithSelected;
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
