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
export function createEngineApi({ getCore, generation, saveChat, upstreamPost, restorePromptOrder }) {
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
            messageCount: globalThis.SillyTavern.getContext().chat.length,
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

    /** The core's live view of the active service settings. */
    define('settings.runtime', async () => {
        const { modules } = await core();
        const settings = modules.openai.oai_settings ?? {};
        return {
            chatCompletionSource: settings.chat_completion_source,
            customUrl: settings.custom_url,
            customModel: settings.custom_model,
            maxContext: settings.openai_max_context,
            maxTokens: settings.openai_max_tokens,
            mainApi: globalThis.SillyTavern.getContext().mainApi,
        };
    });

    /**
     * Re-runs the core's own settings load, as reloading the page would.
     *
     * Upstream exposes this as api.getSettings(); it fetches the saved settings
     * from the vendored server and applies them to every module that caches a
     * copy (model choice, prompt manager, samplers).
     */
    define('settings.reload', async () => {
        const { core: api } = await core();
        await api.getSettings();
        return { reloaded: true };
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

    /**
     * Loads a chat into the core the way selecting a chat does.
     *
     * The core derives prompt history, world-info scan depth and message ids
     * from the chat it has open, not from a bare array. So the messages are
     * written through the server's own chat endpoint and then opened by the
     * core's loader; nothing is poked into `context.chat` directly.
     */
    define('chat.load', async (args) => {
        const api = await core();
        const messages = args.messages;
        if (!Array.isArray(messages)) throw new BadRequest('messages must be an array');

        // Default to the character the core actually has selected; its display
        // name (name2) can be a placeholder before a card is chosen.
        const context = globalThis.SillyTavern.getContext();
        const selected = context.characters?.[context.characterId ?? 0];
        const character = args.characterName ?? selected?.name ?? context.name2;
        return loadChat(api.core, character, messages, args.fileName, saveChat, upstreamPost);
    });

    // ---- Prompt assembly --------------------------------------------------

    /**
     * The real generation prompt: world info + prompts + macros + history,
     * assembled by openai.js exactly as a chat completion would be.
     */
    /**
     * Builds the generation prompt from the chat the core currently has open.
     *
     * The chat is the source of truth: it was loaded through the core's own
     * loader, so its messages, ids and metadata are exactly what upstream's
     * prompt builder expects. No message list is passed in here — a second copy
     * would drift from the one the core actually uses.
     */
    define('prompt.build', async (args) => {
        const { core: api, modules } = await core();
        const context = globalThis.SillyTavern.getContext();
        const chat = context.chat;

        if (!Array.isArray(chat)) throw new BadRequest('The core has no chat loaded');

        const type = typeof args.type === 'string' ? args.type : 'normal';
        const character = args.character ?? {};

        // The prompt order must key the sentinel the manager itself uses; upstream
        // only fixes this on first init, not after a settings reload.
        restorePromptOrder?.(modules);

        if (typeof character.name === 'string' && character.name) {
            api.setCharacterName(character.name);
        }

        // World info scans the same message strings the generation path uses.
        const chatForWI = [...chat]
            .reverse()
            .map((message) => String(message.mes ?? ''));
        const scan = await modules.worldInfo.getWorldInfoPrompt(
            chatForWI,
            Number(args.maxContext ?? 8192),
            false,
            { trigger: 'normal' },
        );

        const assembled = await modules.openai.prepareOpenAIMessages({
            name2: context.name2,
            charDescription: String(character.description ?? ''),
            charPersonality: String(character.personality ?? ''),
            scenario: String(character.scenario ?? ''),
            worldInfoBefore: scan.worldInfoBefore ?? '',
            worldInfoAfter: scan.worldInfoAfter ?? '',
            extensionPrompts: {},
            bias: '',
            type,
            messages: chat.map((message) => ({
                role: message.is_user ? 'user' : 'assistant',
                content: String(message.mes ?? ''),
            })),
            messageExamples: [],
        }, false);

        {
            const manager = modules.openai.promptManager;
            process.stdout.write(`[build] chat=${chat.length} order=${(manager?.serviceSettings?.prompt_order ?? []).map(e => e.character_id).join(',')} dummy=${manager?.configuration?.promptOrder?.dummyId} out=${(assembled?.[0] ?? []).length}\n`);
        }
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

    // Generation methods live in their own module (they need the transport's
    // session), and are merged into the same callable surface.
    if (generation) {
        for (const name of generation.methods) {
            methods.set(name, (args) => generation.call(name, args));
        }
    }

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

/**
 * Writes the messages to a chat file and opens it through the core's loader.
 *
 * This is the same pair of operations the UI performs when a chat is selected,
 * and it is what makes the core treat the messages as real conversation: the
 * prompt builder, world-info depth scan and message ids all read from it.
 */
async function loadChat(core, characterName, messages, fileName, saveChat, upstreamPost) {
    const name = typeof characterName === 'string' && characterName ? characterName : 'Character';
    const chat = messages.map((message) => {
        const isUser = Boolean(message.is_user);
        return {
            name: String(message.name ?? (isUser ? 'User' : name)),
            is_user: isUser,
            is_system: Boolean(message.is_system),
            send_date: String(message.send_date ?? Date.now()),
            mes: String(message.mes ?? message.content ?? ''),
            extra: message.extra && typeof message.extra === 'object' ? message.extra : {},
        };
    });

    const chatFileName = typeof fileName === 'string' && fileName
        ? fileName
        : `native-${Date.now()}`;

    // Upstream chat files start with a metadata header line, which its loader
    // shifts off before treating the rest as messages. Writing the messages
    // without that header makes the loader discard the first real message.
    const header = { user_name: 'User', character_name: name, chat_metadata: {}, create_date: new Date().toISOString() };

    // The server stores chats under the character's avatar name, which is what
    // its reader uses to find them again.
    const contextCharacters = globalThis.SillyTavern.getContext().characters;
    const target = contextCharacters.find((character) => character?.name === name);
    if (!target) {
        throw new BadRequest(`No character named ${name}; the core has ${contextCharacters.length} loaded`);
    }
    await saveChat({ characterName: name, avatar: target.avatar, fileName: chatFileName, chat: [header, ...chat] });

    // Upstream's own selection path loads the selected character's chat as part
    // of switching to it. The file name is set first, so that load is the one
    // that opens the chat that was just written.
    const context = globalThis.SillyTavern.getContext();
    const index = context.characters.findIndex((character) => character?.name === name);
    if (index < 0) {
        throw new BadRequest(`No character named ${name}; the core has ${context.characters.length} loaded`);
    }
    // Selecting the character establishes the state the core's prompt builder
    // and world-info scan read from. It loads whatever chat that character had
    // recorded, so the recording is replaced before the reload below.
    await core.selectCharacterById(index, { switchMenu: false });

    // Opening a chat is a two-step state change upstream: the selected
    // character records the file name, then the loader reads it back. The
    // record omits '.jsonl' because the loader appends it.
    const chid = globalThis.SillyTavern.getContext().characterId;
    const active = globalThis.SillyTavern.getContext().characters[chid];
    if (!active) throw new BadRequest(`No selected character after selecting ${name}`);
    active.chat = chatFileName;
    // getChat() swallows its own errors and falls back to the first message, so
    // the request it makes is verified directly instead of trusting the result.
    const readBack = await upstreamPost('/api/chats/get', {
        ch_name: active.name,
        file_name: chatFileName,
        avatar_url: active.avatar,
    });
    if (!Array.isArray(readBack) || readBack.length < 2) {
        throw new BadRequest(`Saved chat is not readable: ${JSON.stringify(readBack).slice(0, 200)}`);
    }
    await core.getChat();

    const loadedChat = globalThis.SillyTavern.getContext().chat;
    return {
        length: loadedChat.length,
        fileName: chatFileName,
        firstMessage: String(loadedChat[0]?.mes ?? '').slice(0, 60),
    };
}

function requireString(args, key) {
    const value = args[key];
    if (typeof value !== 'string' || !value) throw new BadRequest(`${key} must be a non-empty string`);
    return value;
}
