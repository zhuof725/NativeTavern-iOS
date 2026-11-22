// Generation and settings, delegated to upstream code.
//
// No SillyTavern rule lives here. Prompts are assembled by openai.js, the HTTP
// request to the model is made by upstream's own sendOpenAIRequest, and the
// reply is written back by upstream's Generate/saveReply path. This module only
// moves data between SwiftUI and those functions.
import { BadRequest, CoreUnavailable } from './api.mjs';

/**
 * @param {object} deps
 * @param {() => Promise<{core: object, modules: object}>} deps.getCore
 * @param {{ request: (method: string, path: string, options?: object) => Promise<any> }} deps.session
 *        the transport's upstream session (cookies + CSRF)
 */
export function createGenerationApi({ getCore, session, restorePromptOrder }) {
    const methods = new Map();
    const define = (name, handler) => methods.set(name, handler);

    const postJson = async (path, body) => {
        const response = await session.request('POST', path, {
            headers: { 'content-type': 'application/json' },
            body: Buffer.from(JSON.stringify(body ?? {})),
        });
        const text = response.body?.toString('utf8') ?? '';
        try { return JSON.parse(text); } catch { return text; }
    };

    define('settings.get', async () => {
        const result = await postJson('/api/settings/get', {});
        const raw = typeof result === 'string' ? result : result?.settings;
        return { settings: raw ? JSON.parse(raw) : null };
    });

    /**
     * Applies the user's model choice and parameters.
     *
     * Two stores have to agree: the vendored server's saved settings (what its
     * generate endpoint reads) and the core's live objects (what its prompt
     * builder reads). The original UI keeps them in sync by reloading the page;
     * here the same settings object is applied to both.
     */
    define('settings.update', async (args) => {
        const patch = args.patch;
        if (!patch || typeof patch !== 'object' || Array.isArray(patch)) {
            throw new BadRequest('patch must be an object');
        }
        // The saved file is what the vendored server reads when it calls a
        // provider; the core's in-memory copy is what its prompt builder reads.
        // Both are updated, in that order, using upstream's own reload path.
        const current = await postJson('/api/settings/get', {});
        const settings = JSON.parse(typeof current === 'string' ? current : current.settings);
        // Upstream keeps two copies in its settings file: the flat keys the
        // loader reads back (top level) and the grouped `oai_settings` block the
        // saved file also carries. Both are updated here, as its own save path
        // does, so a reload sees exactly what was set.
        Object.assign(settings, patch);
        if (settings.oai_settings && typeof settings.oai_settings === 'object') {
            Object.assign(settings.oai_settings, patch);
        }

        // Selecting a chat-completion provider is the same thing as choosing the
        // OpenAI-style API in the UI; keeping them in step is what makes the
        // core take the chat-completion path instead of text completion.
        if (typeof patch.chat_completion_source === 'string') {
            settings.main_api = 'openai';
        }
        await postJson('/api/settings/save', settings);

        // The core's own loader reads the saved file back. That file's prompt
        // order is keyed by a different sentinel id than the prompt manager uses,
        // so the manager's entry is carried over, exactly as its own sanitizer
        // would create it on a fresh page.
        const { core, modules } = await getCore();
        await core.getSettings();
        restorePromptOrder?.(modules);

        return { updated: Object.keys(patch) };
    });

    /** Stores an API key through upstream's secret manager, as its own UI does. */
    define('settings.setSecret', async (args) => {
        const key = requireString(args, 'key');
        const value = requireString(args, 'value');
        const label = typeof args.label === 'string' ? args.label : undefined;
        await postJson('/api/secrets/write', { key, value, label });
        return { key };
    });

    /**
     * Generates a reply through upstream's own generation path.
     *
     * The core assembles its prompt (world info, macros, presets, history) and
     * posts it to the vendored backend, which calls the model provider.
     */
    define('generate.reply', async (args) => {
        let core;
        try {
            ({ core } = await getCore());
        } catch (error) {
            throw new CoreUnavailable(`The chat core is not ready: ${error.message}`);
        }

        const type = typeof args.type === 'string' ? args.type : 'normal';
        if (typeof args.characterName === 'string' && args.characterName) {
            core.setCharacterName(args.characterName);
        }
        if (Array.isArray(args.messages)) {
            const context = globalThis.SillyTavern.getContext();
            context.chat.length = 0;
            context.chat.push(...args.messages.map((message) => ({
                name: String(message.name ?? ''),
                is_user: Boolean(message.is_user),
                is_system: Boolean(message.is_system),
                mes: String(message.mes ?? message.content ?? ''),
                send_date: String(Date.now()),
                extra: {},
            })));
        }

        // Upstream refuses to generate while it believes there is no connection;
        // the vendored backend is the connection.
        core.setOnlineStatus('connected');

        const context = globalThis.SillyTavern.getContext();
        const before = context.chat.length;
        await core.Generate(type, {}, false);

        return {
            messages: context.chat.slice(before).map((message) => ({
                role: message.is_user ? 'user' : 'assistant',
                content: String(message.mes ?? ''),
                name: String(message.name ?? ''),
            })),
        };
    });

    return {
        methods: [...methods.keys()],
        call(name, args) {
            const handler = methods.get(name);
            if (!handler) throw new BadRequest(`Unknown method: ${name}`);
            return handler(args ?? {});
        },
    };
}

function requireString(args, key) {
    const value = args[key];
    if (typeof value !== 'string' || !value) throw new BadRequest(`${key} must be a non-empty string`);
    return value;
}
