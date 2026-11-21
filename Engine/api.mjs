// The app-facing engine API: SillyTavern semantics over a small JSON surface.
//
// Everything here delegates to the ORIGINAL modules (world-info.js, macros.js,
// openai.js). No world-info logic, macro rule, or prompt layout is reimplemented
// — if upstream changes its behaviour, the app inherits that change.
import path from 'node:path';

export class CoreUnavailable extends Error {
    constructor(message) {
        super(message);
        this.code = 'CORE_UNAVAILABLE';
        this.status = 503;
    }
}

export class BadRequest extends Error {
    constructor(message) {
        super(message);
        this.code = 'BAD_REQUEST';
        this.status = 400;
    }
}

/**
 * @param {object} deps
 * @param {() => Promise<object>} deps.getCore lazily returns the started core
 */
export function createEngineApi({ getCore }) {
    const methods = new Map();

    const core = async () => {
        try {
            return await getCore();
        } catch (error) {
            throw new CoreUnavailable(`The chat core is not ready: ${error.message}`);
        }
    };

    const define = (name, handler) => methods.set(name, handler);

    define('engine.status', async () => {
        const { core: api, modules } = await core();
        const context = globalThis.SillyTavern.getContext();
        return {
            protocolVersion: 3,
            runtime: process.version,
            transportReady: true,
            sillyTavernCoreReady: true,
            // These are upstream's own objects; presence here means real code is loaded.
            capabilities: [...methods.keys()],
            characterSelected: !!context.name2,
            userName: context.name1,
            characterName: context.name2,
            worldInfoBooks: modules.worldInfo.world_names?.length ?? 0,
        };
    });

    // ---- World info -------------------------------------------------------

    define('worldinfo.list', async () => {
        const { modules } = await core();
        await modules.worldInfo.updateWorldInfoList();
        return { books: modules.worldInfo.world_names ?? [], active: modules.worldInfo.selected_world_info ?? [] };
    });

    define('worldinfo.get', async (args) => {
        const { modules } = await core();
        const name = requireString(args, 'name');
        const data = await modules.worldInfo.loadWorldInfo(name);
        if (!data) throw new BadRequest(`No world info named ${name}`);
        return { name, data };
    });

    define('worldinfo.create', async (args) => {
        const { modules } = await core();
        const name = requireString(args, 'name');
        const entries = args.entries;
        if (!entries || typeof entries !== 'object') throw new BadRequest('entries is required');
        await modules.worldInfo.saveWorldInfo(name, { entries }, true);
        await modules.worldInfo.updateWorldInfoList();
        return { name };
    });

    /** Activates books exactly like the /world command does. */
    define('worldinfo.activate', async (args) => {
        const { modules } = await core();
        const names = Array.isArray(args.names) ? args.names : [];
        const silent = 'true';
        for (const name of names) {
            await modules.worldInfo.onWorldInfoChange({ state: 'on', silent }, String(name));
        }
        return { active: modules.worldInfo.selected_world_info ?? [] };
    });

    define('worldinfo.deactivateAll', async () => {
        const { modules } = await core();
        await modules.worldInfo.onWorldInfoChange({ silent: 'true' }, '');
        return { active: modules.worldInfo.selected_world_info ?? [] };
    });

    /** Runs upstream's real keyword scan over the given messages. */
    define('worldinfo.scan', async (args) => {
        const { modules } = await core();
        const messages = Array.isArray(args.messages) ? args.messages.map(String) : [];
        const maxContext = Number.isFinite(args.maxContext) ? Number(args.maxContext) : 8192;
        const result = await modules.worldInfo.getWorldInfoPrompt(
            messages,
            maxContext,
            Boolean(args.dryRun),
            { trigger: typeof args.trigger === 'string' ? args.trigger : 'normal' },
        );
        return {
            worldInfoBefore: result.worldInfoBefore ?? '',
            worldInfoAfter: result.worldInfoAfter ?? '',
            worldInfoString: result.worldInfoString ?? '',
            depthEntries: result.worldInfoDepth ?? [],
            exampleEntries: result.worldInfoExamples ?? [],
        };
    });

    // ---- Macros -----------------------------------------------------------

    /** Upstream's macro engine: {{user}}, {{char}}, {{time}}, {{roll}}, variables… */
    define('macro.substitute', async (args) => {
        const { core: api } = await core();
        const content = requireString(args, 'content');
        return { result: api.substituteParams(content) };
    });

    // ---- Characters and chat ---------------------------------------------

    define('character.setName', async (args) => {
        const { core: api } = await core();
        const name = requireString(args, 'name');
        api.setCharacterName(name);
        return { name };
    });

    /** Loads a chat array into the core, as selecting a chat does. */
    define('chat.load', async (args) => {
        const { core: api } = await core();
        const messages = args.messages;
        if (!Array.isArray(messages)) throw new BadRequest('messages must be an array');
        const chat = messages.map((message) => ({
            name: String(message.name ?? ''),
            is_user: Boolean(message.is_user),
            is_system: Boolean(message.is_system),
            mes: String(message.mes ?? message.content ?? ''),
            send_date: String(message.send_date ?? Date.now()),
            extra: message.extra && typeof message.extra === 'object' ? message.extra : {},
        }));
        // Upstream keeps the chat array by reference in a lot of places.
        const context = globalThis.SillyTavern.getContext();
        context.chat.length = 0;
        context.chat.push(...chat);
        return { length: context.chat.length };
    });

    // ---- Prompt assembly --------------------------------------------------

    /**
     * The real generation prompt: world info + prompts + macros + history,
     * assembled by openai.js exactly as a chat completion would be.
     */
    define('prompt.build', async (args) => {
        const { core: api, modules } = await core();
        const character = args.character ?? {};
        const messages = Array.isArray(args.messages) ? args.messages : [];
        const type = typeof args.type === 'string' ? args.type : 'normal';

        api.setCharacterName(String(character.name ?? 'Character'));

        const scan = await modules.worldInfo.getWorldInfoPrompt(
            messages.map((m) => String(m.mes ?? m.content ?? '')).reverse(),
            Number(args.maxContext ?? 8192),
            false,
            { trigger: 'normal' },
        );

        const assembled = await modules.openai.prepareOpenAIMessages({
            name2: String(character.name ?? 'Character'),
            charDescription: String(character.description ?? ''),
            charPersonality: String(character.personality ?? ''),
            scenario: String(character.scenario ?? ''),
            worldInfoBefore: scan.worldInfoBefore ?? '',
            worldInfoAfter: scan.worldInfoAfter ?? '',
            extensionPrompts: {},
            bias: '',
            type,
            messages: messages.map((m) => ({
                role: m.is_user ? 'user' : 'assistant',
                content: String(m.mes ?? m.content ?? ''),
            })),
            messageExamples: [],
        }, false);

        const prompt = (assembled?.[0] ?? []).map((message) => ({
            role: message.role,
            content: message.content,
            name: message.name,
        }));

        return {
            prompt,
            worldInfo: {
                before: scan.worldInfoBefore ?? '',
                after: scan.worldInfoAfter ?? '',
            },
        };
    });

    return {
        async call(method, args) {
            const handler = methods.get(method);
            if (!handler) {
                const error = new BadRequest(`Unknown method: ${method}`);
                error.code = 'METHOD_NOT_IMPLEMENTED';
                error.status = 501;
                throw error;
            }
            return handler(args ?? {});
        },
        methods: [...methods.keys()],
    };
}

function requireString(args, key) {
    const value = args[key];
    if (typeof value !== 'string' || !value) throw new BadRequest(`${key} must be a non-empty string`);
    return value;
}
