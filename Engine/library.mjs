// Management surface for the native UI: characters, chats, world info,
// presets and prompt order.
//
// Every operation is expressed as the same request or function the original web
// UI uses. Nothing here reimplements a SillyTavern rule: files are written by
// upstream's endpoints, characters are parsed by upstream's card reader, and the
// chat that generation sees is the one upstream's own loader opened.
import { randomBytes } from 'node:crypto';

export class LibraryError extends Error {
    constructor(message, status = 400, code = 'BAD_REQUEST') {
        super(message);
        this.status = status;
        this.code = code;
    }
}

/**
 * @param {object} deps
 * @param {() => Promise<{core: object, modules: object}>} deps.getCore
 * @param {{ request: (method: string, path: string, options?: object) => Promise<any> }} deps.session
 * @param {(args: object) => Promise<any>} deps.saveChat upstream's chat writer
 * @param {(modules: object) => void} [deps.restorePromptOrder]
 * @param {(message: string) => void} [deps.log]
 */
export function createLibraryApi({ getCore, session, saveChat, restorePromptOrder, log = () => {} }) {
    const methods = new Map();
    const define = (name, handler) => methods.set(name, handler);

    const coreBundle = async () => {
        try {
            return await getCore();
        } catch (error) {
            throw new LibraryError(`The chat core is not ready: ${error.message}`, 503, 'CORE_UNAVAILABLE');
        }
    };

    const readJson = async (method, path, body) => {
        const response = await session.request(method, path, body === undefined ? {} : {
            headers: { 'content-type': 'application/json' },
            body: Buffer.from(JSON.stringify(body)),
        });
        const text = response.body?.toString('utf8') ?? '';
        let parsed = text;
        try { parsed = JSON.parse(text); } catch { /* non-JSON responses are returned as text */ }
        if (response.status >= 400) {
            const detail = typeof parsed === 'string' ? parsed.slice(0, 200) : JSON.stringify(parsed).slice(0, 200);
            throw new LibraryError(`${path} failed (${response.status}): ${detail}`, response.status, 'UPSTREAM_ERROR');
        }
        return parsed;
    };
    const postJson = (path, body) => readJson('POST', path, body ?? {});
    const postText = async (path, body) => {
        const response = await session.request('POST', path, {
            headers: { 'content-type': 'application/json' },
            body: Buffer.from(JSON.stringify(body ?? {})),
        });
        const text = response.body?.toString('utf8') ?? '';
        if (response.status >= 400) throw new LibraryError(`${path} failed (${response.status}): ${text.slice(0, 200)}`, response.status);
        return text;
    };
    const postJsonArray = async (path, body, method = 'POST') => {
        const response = await session.request(method, path, method === 'GET' ? {} : {
            headers: { 'content-type': 'application/json' },
            body: Buffer.from(JSON.stringify(body ?? {})),
        });
        const text = response.body?.toString('utf8') ?? '';
        let parsed = [];
        try { parsed = JSON.parse(text); } catch { parsed = []; }
        return Array.isArray(parsed) ? parsed : [];
    };
    const postForm = async (path, fields, file) => {
        const boundary = `----NativeTavern${randomBytes(8).toString('hex')}`;
        const chunks = [];
        for (const [name, value] of Object.entries(fields ?? {})) {
            chunks.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`));
        }
        chunks.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="avatar"; filename="${file.name}"\r\nContent-Type: ${file.type || 'application/octet-stream'}\r\n\r\n`));
        chunks.push(file.data);
        chunks.push(Buffer.from(`\r\n--${boundary}--\r\n`));
        const response = await session.request('POST', path, {
            headers: { 'content-type': `multipart/form-data; boundary=${boundary}` },
            body: Buffer.concat(chunks),
        });
        const text = response.body?.toString('utf8') ?? '';
        let parsed = text;
        try { parsed = JSON.parse(text); } catch { /* text response */ }
        if (response.status >= 400) throw new LibraryError(`${path} failed (${response.status}): ${text.slice(0, 200)}`, response.status);
        return parsed;
    };

    // ---- shared shapes -----------------------------------------------------

    const serializeMessages = () => {
        const context = globalThis.SillyTavern.getContext();
        const chat = Array.isArray(context.chat) ? context.chat : [];
        return chat.map((message, index) => ({
            id: index,
            name: String(message.name ?? ''),
            isUser: Boolean(message.is_user),
            isSystem: Boolean(message.is_system),
            text: String(message.mes ?? message.content ?? ''),
            swipes: Array.isArray(message.swipes) ? message.swipes.map(String) : [],
            swipeId: Number.isFinite(message.swipe_id) ? Number(message.swipe_id) : 0,
            sendDate: message.send_date ? String(message.send_date) : '',
        }));
    };

    const snapshot = () => {
        const context = globalThis.SillyTavern.getContext();
        return {
            messages: serializeMessages(),
            fileName: safeCurrentChat(),
            characterName: context.name2,
            userName: context.name1,
        };
    };
    const safeCurrentChat = () => {
        try {
            const context = globalThis.SillyTavern.getContext();
            const character = context.characters?.[context.characterId];
            return character?.chat ? String(character.chat) : '';
        } catch {
            return '';
        }
    };

    /**
     * Runs one generation and always resolves within a bounded time.
     *
     * A provider that never answers would otherwise leave the Swift client's
     * request open indefinitely. On timeout the core's own stop path is invoked
     * and the caller gets an explanation it can show.
     */
    const GENERATION_TIMEOUT_MS = 180000;

    const generationPreflight = (api, modules) => {
        const settings = modules.openai.oai_settings ?? {};
        // st-context captures main_api at module initialization instead of
        // exposing the live binding. The core module's export is authoritative.
        if (api.main_api !== 'openai') {
            return '还没有启用对话补全。请到“设置 → 模型连接”选择服务并保存，再发送消息。';
        }
        if (settings.chat_completion_source === 'custom' && !String(settings.custom_url ?? '').trim()) {
            return '还没有填写模型接口地址。请到“设置 → 模型连接”填写地址（通常以 /v1 结尾）并保存。';
        }
        return null;
    };

    const runGeneration = async (api, modules, type) => {
        const blocked = generationPreflight(api, modules);
        if (blocked) return { ...snapshot(), error: blocked };

        const context = globalThis.SillyTavern.getContext();
        const settings = modules.openai.oai_settings ?? {};
        const started = Date.now();
        log(`generate ${type}: source=${settings.chat_completion_source} model=${settings.custom_model || settings.openai_model || ''} messages=${context.chat.length} stream=${!!settings.stream_openai}`);
        api.setOnlineStatus('connected');

        let failure = null;
        const generation = api.Generate(type, {}, false)
            .then(() => 'done')
            .catch((error) => {
                failure = error;
                return 'error';
            });
        let timer = null;
        const timeout = new Promise((resolve) => {
            timer = setTimeout(() => resolve('timeout'), GENERATION_TIMEOUT_MS);
        });
        const outcome = await Promise.race([generation, timeout]);
        clearTimeout(timer);

        if (outcome === 'timeout') {
            log(`generate ${type}: timed out after ${GENERATION_TIMEOUT_MS}ms; stopping`);
            try { api.stopGeneration(); } catch { /* already stopped */ }
            await api.saveChatConditional().catch(() => {});
            return { ...snapshot(), error: '生成超过 3 分钟，已自动停止。请检查模型地址、密钥或网络后重试。' };
        }
        if (outcome === 'error') {
            log(`generate ${type}: failed after ${Date.now() - started}ms: ${failure?.stack ?? failure}`);
            await api.saveChatConditional().catch(() => {});
            return { ...snapshot(), error: String(failure?.message ?? failure) };
        }
        await api.saveChatConditional();
        log(`generate ${type}: done in ${Date.now() - started}ms`);
        return { ...snapshot(), error: null };
    };

    /** The group counterpart of runGeneration: same timeout and logging. */
    const runGroupGeneration = async (api, modules, type, { forceChid } = {}) => {
        const groupId = String(globalThis.SillyTavern.getContext().groupId ?? '');
        if (!groupId) throw new LibraryError('No group is open.', 400);
        const blocked = generationPreflight(api, modules);
        if (blocked) return { ...(await groupSnapshot(modules, groupId)), error: blocked };

        api.setOnlineStatus('connected');
        const started = Date.now();
        log(`group generate ${type}: group=${groupId} members=${(modules.groupChats.groups ?? []).find((g) => String(g.id) === groupId)?.members?.length ?? 0}`);

        let failure = null;
        const generation = api.Generate(type, forceChid === undefined ? {} : { force_chid: forceChid }, false)
            .then(() => 'done')
            .catch((error) => {
                failure = error;
                return 'error';
            });
        let timer = null;
        const timeout = new Promise((resolve) => {
            timer = setTimeout(() => resolve('timeout'), GENERATION_TIMEOUT_MS);
        });
        const outcome = await Promise.race([generation, timeout]);
        clearTimeout(timer);

        if (outcome === 'timeout') {
            log(`group generate ${type}: timed out; stopping`);
            try { api.stopGeneration(); } catch { /* already stopped */ }
            await api.saveChatConditional().catch(() => {});
            return { ...(await groupSnapshot(modules, groupId)), error: '生成超过 3 分钟，已自动停止。' };
        }
        if (outcome === 'error') {
            log(`group generate ${type}: failed: ${failure?.stack ?? failure}`);
            await api.saveChatConditional().catch(() => {});
            return { ...(await groupSnapshot(modules, groupId)), error: String(failure?.message ?? failure) };
        }
        await api.saveChatConditional();
        log(`group generate ${type}: done in ${Date.now() - started}ms`);
        return { ...(await groupSnapshot(modules, groupId)), error: null };
    };

    // ---- characters --------------------------------------------------------

    const CHARACTER_FIELDS = [
        'name', 'description', 'personality', 'scenario', 'first_mes', 'mes_example',
        'creator_notes', 'system_prompt', 'post_history_instructions', 'creator',
        'character_version', 'tags', 'alternate_greetings', 'extensions', 'character_book',
    ];

    /** A card has v1 fields at the top and v2/v3 fields under `data`. */
    const cardFields = (card) => {
        const source = card?.data && typeof card.data === 'object' ? card.data : card;
        const pick = (key) => source?.[key] ?? card?.[key];
        return {
            name: String(pick('name') ?? ''),
            description: String(pick('description') ?? ''),
            personality: String(pick('personality') ?? ''),
            scenario: String(pick('scenario') ?? ''),
            firstMes: String(pick('first_mes') ?? ''),
            mesExample: String(pick('mes_example') ?? ''),
            creatorNotes: String(pick('creator_notes') ?? card?.creatorcomment ?? ''),
            systemPrompt: String(pick('system_prompt') ?? ''),
            postHistoryInstructions: String(pick('post_history_instructions') ?? ''),
            creator: String(pick('creator') ?? ''),
            characterVersion: String(pick('character_version') ?? ''),
            tags: Array.isArray(pick('tags')) ? pick('tags').map(String) : [],
            alternateGreetings: Array.isArray(pick('alternate_greetings')) ? pick('alternate_greetings').map(String) : [],
            hasCharacterBook: Boolean(pick('character_book')),
        };
    };

    const toCharacter = (card) => ({
        ...cardFields(card),
        avatar: String(card?.avatar ?? ''),
        chat: String(card?.chat ?? ''),
        fav: Boolean(card?.fav),
        talkativeness: String(card?.talkativeness ?? '0.5'),
        dateAdded: Number(card?.date_added ?? 0),
    });

    define('character.list', async () => {
        const cards = await postJson('/api/characters/all');
        const list = Array.isArray(cards) ? cards : [];
        return { characters: list.map(toCharacter).sort((a, b) => b.dateAdded - a.dateAdded) };
    });

    define('character.get', async (args) => {
        const avatar = requireString(args, 'avatar');
        const card = await postJson('/api/characters/get', { avatar_url: avatar });
        if (!card || typeof card !== 'object') throw new LibraryError(`No character with avatar ${avatar}`, 404);
        return { character: toCharacter(card) };
    });

    /** Translates the app's card shape back into the endpoint's field names. */
    const cardBody = (card, existing = null) => {
        const body = {
            ch_name: String(card?.name ?? ''),
            description: String(card?.description ?? ''),
            personality: String(card?.personality ?? ''),
            scenario: String(card?.scenario ?? ''),
            first_mes: String(card?.firstMes ?? ''),
            mes_example: String(card?.mesExample ?? ''),
            creator_notes: String(card?.creatorNotes ?? ''),
            system_prompt: String(card?.systemPrompt ?? ''),
            post_history_instructions: String(card?.postHistoryInstructions ?? ''),
            creator: String(card?.creator ?? ''),
            character_version: String(card?.characterVersion ?? ''),
            tags: Array.isArray(card?.tags) ? card.tags.join(',') : String(card?.tags ?? ''),
            talkativeness: String(card?.talkativeness ?? '0.5'),
        };
        if (existing && typeof existing === 'object') {
            body.json_data = JSON.stringify(existing);
            if (existing.chat) body.chat = existing.chat;
            if (existing.create_date) body.create_date = existing.create_date;
        }
        return body;
    };

    define('character.create', async (args) => {
        const { core: api } = await coreBundle();
        const body = cardBody(args.card ?? {});
        if (!body.ch_name.trim()) throw new LibraryError('A character needs a name.');
        const avatar = String(await postText('/api/characters/create', body)).trim();
        await api.getCharacters();
        const card = await postJson('/api/characters/get', { avatar_url: avatar });
        return { character: toCharacter(card), avatar };
    });

    define('character.edit', async (args) => {
        const { core: api } = await coreBundle();
        const avatar = requireString(args, 'avatar');
        const existing = await postJson('/api/characters/get', { avatar_url: avatar });
        const body = cardBody(args.card ?? {}, existing);
        body.avatar_url = avatar;
        await postText('/api/characters/edit', body);
        await api.getCharacters();
        const card = await postJson('/api/characters/get', { avatar_url: avatar });
        return { character: toCharacter(card) };
    });

    define('character.delete', async (args) => {
        const { core: api } = await coreBundle();
        const avatar = requireString(args, 'avatar');
        await postJson('/api/characters/delete', {
            avatar_url: avatar,
            delete_chats: args.deleteChats === true,
        });
        await api.getCharacters();
        return { deleted: avatar };
    });

    define('character.select', async (args) => {
        const { core: api } = await coreBundle();
        const avatar = requireString(args, 'avatar');
        const context = globalThis.SillyTavern.getContext();
        const index = context.characters.findIndex((character) => character?.avatar === avatar);
        if (index < 0) throw new LibraryError(`No character with avatar ${avatar}`, 404);
        await api.selectCharacterById(index, { switchMenu: false });
        return snapshot();
    });

    /** Imports a card exported by the web UI (PNG, JSON, CHARX or YAML). */
    define('character.import', async (args) => {
        const { core: api } = await coreBundle();
        const fileName = requireString(args, 'fileName');
        const data = requireString(args, 'data');
        const extension = (fileName.split('.').pop() || 'json').toLowerCase();
        const result = await postForm('/api/characters/import', {
            file_type: extension,
            preserved_name: fileName,
        }, {
            name: fileName,
            type: extension === 'png' ? 'image/png' : 'application/octet-stream',
            data: Buffer.from(data, 'base64'),
        });
        await api.getCharacters();
        // Upstream returns the internal base name; the avatar the app can load
        // is always the PNG that was written next to the character.
        const base = String(result?.file_name ?? fileName).replace(/\.png$/i, '');
        return { fileName: `${base}.png`, raw: result };
    });

    define('character.setAvatar', async (args) => {
        const { core: api } = await coreBundle();
        const avatar = requireString(args, 'avatar');
        const data = requireString(args, 'data');
        await postForm('/api/characters/edit-avatar', { avatar_url: avatar }, {
            name: args.fileName ?? 'avatar.png',
            type: 'image/png',
            data: Buffer.from(data, 'base64'),
        });
        await api.getCharacters();
        return { avatar };
    });

    define('character.duplicate', async (args) => {
        const { core: api } = await coreBundle();
        const avatar = requireString(args, 'avatar');
        const raw = await postText('/api/characters/duplicate', { avatar_url: avatar });
        await api.getCharacters();
        return { avatar: raw.trim() };
    });

    define('character.export', async (args) => {
        const avatar = requireString(args, 'avatar');
        const result = await postJson('/api/characters/export', {
            avatar_url: avatar,
            format: args.format ?? 'json',
        });
        return { data: result };
    });

    // ---- chats -------------------------------------------------------------

    define('chat.list', async (args) => {
        const avatar = requireString(args, 'avatar');
        const list = await postJson('/api/characters/chats', { avatar_url: avatar, metadata: true });
        if (!Array.isArray(list)) return { chats: [] };
        return {
            chats: list.map((item) => ({
                fileName: String(item.file_name ?? ''),
                fileId: String(item.file_id ?? String(item.file_name ?? '').replace(/\.jsonl$/, '')),
                preview: String(item.mes ?? ''),
                lastMessage: String(item.last_mes ?? ''),
                messageCount: Number(item.chat_items ?? 0),
                lastUpdated: String(item.last_date ?? ''),
            })).sort((a, b) => {
                const left = a.lastUpdated || '';
                const right = b.lastUpdated || '';
                if (left !== right) return right.localeCompare(left);
                return b.fileName.localeCompare(a.fileName);
            }),
        };
    });

    const readChatFile = async (avatar, fileName) => {
        const data = await postJson('/api/chats/get', {
            avatar_url: avatar,
            file_name: fileName.replace(/\.jsonl$/, ''),
        });
        if (!Array.isArray(data)) throw new LibraryError(`Chat ${fileName} could not be read`, 404);
        return data;
    };

    define('chat.read', async (args) => {
        const avatar = requireString(args, 'avatar');
        const fileName = requireString(args, 'fileName');
        const data = await readChatFile(avatar, fileName);
        // The first line is the file header, which the core's loader shifts off.
        const messages = data.slice(1).map((message, index) => ({
            id: index,
            name: String(message.name ?? ''),
            isUser: Boolean(message.is_user),
            isSystem: Boolean(message.is_system),
            text: String(message.mes ?? message.content ?? ''),
            swipes: Array.isArray(message.swipes) ? message.swipes.map(String) : [],
            swipeId: Number.isFinite(message.swipe_id) ? Number(message.swipe_id) : 0,
            sendDate: message.send_date ? String(message.send_date) : '',
        }));
        const header = data[0] && typeof data[0] === 'object' ? data[0] : {};
        return {
            messages,
            metadata: header.chat_metadata ?? {},
            userName: String(header.user_name ?? ''),
            characterName: String(header.character_name ?? ''),
        };
    });

    /** Opens a chat in the core, so generation sees exactly these messages. */
    define('chat.open', async (args) => {
        const { core: api } = await coreBundle();
        const avatar = requireString(args, 'avatar');
        const context = globalThis.SillyTavern.getContext();
        const index = context.characters.findIndex((character) => character?.avatar === avatar);
        if (index < 0) throw new LibraryError(`No character with avatar ${avatar}`, 404);
        if (context.characterId !== index) {
            await api.selectCharacterById(index, { switchMenu: false });
        }
        if (typeof args.fileName === 'string' && args.fileName) {
            await api.openCharacterChat(args.fileName.replace(/\.jsonl$/, ''));
        }
        return snapshot();
    });

    /** Starts a new chat through the core's own creation path. */
    define('chat.new', async (args) => {
        const { core: api } = await coreBundle();
        const avatar = requireString(args, 'avatar');
        const context = globalThis.SillyTavern.getContext();
        const index = context.characters.findIndex((character) => character?.avatar === avatar);
        if (index < 0) throw new LibraryError(`No character with avatar ${avatar}`, 404);
        if (context.characterId !== index) {
            await api.selectCharacterById(index, { switchMenu: false });
        }
        await api.doNewChat({ deleteCurrentChat: false });
        if (typeof args.greeting === 'string' && args.greeting) {
            const chatContext = globalThis.SillyTavern.getContext();
            chatContext.chat.length = 0;
            chatContext.chat.push({
                name: chatContext.name2,
                is_user: false,
                is_system: false,
                send_date: String(Date.now()),
                mes: args.greeting,
                extra: {},
            });
            await api.saveChatConditional();
        }
        return snapshot();
    });

    define('chat.delete', async (args) => {
        const avatar = requireString(args, 'avatar');
        const fileName = requireString(args, 'fileName');
        await postJson('/api/chats/delete', {
            avatar_url: avatar,
            chatfile: fileName.endsWith('.jsonl') ? fileName : `${fileName}.jsonl`,
        });
        return { deleted: fileName };
    });

    define('chat.rename', async (args) => {
        const avatar = requireString(args, 'avatar');
        const fileName = requireString(args, 'fileName');
        const newName = requireString(args, 'newName');
        const result = await postJson('/api/chats/rename', {
            avatar_url: avatar,
            original_file: fileName.endsWith('.jsonl') ? fileName : `${fileName}.jsonl`,
            renamed_file: newName.endsWith('.jsonl') ? newName : `${newName}.jsonl`,
        });
        if (result?.error) throw new LibraryError('Rename failed: the name is already taken or invalid.');
        return { fileName: newName };
    });

    /** Saves the messages the core currently has open. */
    define('chat.save', async () => {
        const { core } = await coreBundle();
        await core.saveChatConditional();
        return snapshot();
    });

    define('chat.messages', async () => snapshot());

    define('chat.append', async (args) => {
        const { core } = await coreBundle();
        const text = requireString(args, 'text');
        const context = globalThis.SillyTavern.getContext();
        context.chat.push({
            name: String(args.name ?? context.name1),
            is_user: args.isUser !== false,
            is_system: false,
            send_date: String(Date.now()),
            mes: text,
            extra: {},
        });
        await core.saveChatConditional();
        return snapshot();
    });

    define('message.edit', async (args) => {
        const { core } = await coreBundle();
        const id = requireIndex(args, 'id');
        const context = globalThis.SillyTavern.getContext();
        const message = context.chat[id];
        if (!message) throw new LibraryError(`No message at ${id}`, 404);
        message.mes = String(args.text ?? '');
        if (Array.isArray(message.swipes) && message.swipes.length) {
            message.swipes[Number(message.swipe_id ?? 0)] = message.mes;
        }
        await core.saveChatConditional();
        return snapshot();
    });

    define('message.delete', async (args) => {
        const { core } = await coreBundle();
        const id = requireIndex(args, 'id');
        const context = globalThis.SillyTavern.getContext();
        if (!context.chat[id]) throw new LibraryError(`No message at ${id}`, 404);
        context.chat.splice(id, 1);
        await core.saveChatConditional();
        return snapshot();
    });

    define('message.swipe', async (args) => {
        const { core: api } = await coreBundle();
        const id = requireIndex(args, 'id');
        const direction = args.direction === 'left' ? 'left' : 'right';
        const context = globalThis.SillyTavern.getContext();
        const message = context.chat[id];
        if (!message) throw new LibraryError(`No message at ${id}`, 404);

        // Swipes are upstream's own message structure. The first swipe is the
        // text that was already there; generating a new one appends a slot.
        if (!Array.isArray(message.swipes) || message.swipes.length === 0) {
            message.swipe_id = 0;
            message.swipes = [String(message.mes ?? '')];
            message.swipe_info = [{
                send_date: message.send_date,
                gen_started: message.gen_started,
                gen_finished: message.gen_finished,
                extra: {},
            }];
        }
        const original = Number(message.swipe_id ?? 0);
        const show = (index) => {
            message.swipe_id = index;
            message.mes = String(message.swipes[index] ?? '');
        };

        if (direction === 'left') {
            show(original > 0 ? original - 1 : Math.max(0, message.swipes.length - 1));
            await api.saveChatConditional();
            return snapshot();
        }

        if (original + 1 < message.swipes.length) {
            show(original + 1);
            await api.saveChatConditional();
            return snapshot();
        }

        // Only the last message can be regenerated through the swipe path;
        // older messages wrap around to their first stored variant.
        if (id !== context.chat.length - 1) {
            show(0);
            await api.saveChatConditional();
            return snapshot();
        }

        message.swipe_id = message.swipes.length;
        api.setOnlineStatus('connected');
        try {
            await api.Generate('swipe', {}, false);
            await api.saveChatConditional();
            return { ...snapshot(), error: null };
        } catch (error) {
            // A failed generation must not leave swipe_id pointing past the end.
            show(Math.min(original, Math.max(0, message.swipes.length - 1)));
            await api.saveChatConditional().catch(() => {});
            return { ...snapshot(), error: String(error?.message ?? error) };
        }
    });

    // ---- generation --------------------------------------------------------

    /** The open group's messages, named the same way in both directions. */
    const groupSnapshot = async (modules, id) => {
        const context = globalThis.SillyTavern.getContext();
        const group = (modules.groupChats.groups ?? []).find((item) => String(item.id) === id);
        return {
            ...snapshot(),
            groupId: String(context.groupId ?? ''),
            groupName: String(group?.name ?? ''),
            chatId: String(group?.chat_id ?? ''),
        };
    };

    define('chat.send', async (args) => {
        const { core: api, modules } = await coreBundle();
        const text = requireString(args, 'text');
        const blocked = generationPreflight(api, modules);
        if (blocked) return { ...snapshot(), error: blocked };

        const context = globalThis.SillyTavern.getContext();
        // The UI's optimistic message is not a second copy of the truth: the
        // core's chat is where the message goes, and it is what the prompt
        // builder reads. The response carries the core's chat back.
        context.chat.push({
            name: String(context.name1),
            is_user: true,
            is_system: false,
            send_date: String(Date.now()),
            mes: text,
            extra: {},
        });
        log(`chat.send: saving user turn (${context.chat.length} messages)`);
        await api.saveChatConditional();
        log('chat.send: user turn saved');
        return runGeneration(api, modules, 'normal');
    });

    /** Continue, impersonate and regenerate, all through Generate(). */
    define('chat.generate', async (args) => {
        const { core: api, modules } = await coreBundle();
        const type = ['continue', 'impersonate', 'regenerate'].includes(args.type) ? String(args.type) : 'normal';
        return runGeneration(api, modules, type);
    });

    define('generate.stop', async () => {
        const { core } = await coreBundle();
        core.stopGeneration();
        return { stopped: true };
    });

    // ---- group chats -------------------------------------------------------

    /** A group is a member list plus generation settings, stored by upstream. */
    const toGroup = (group) => ({
        id: String(group?.id ?? ''),
        name: String(group?.name ?? ''),
        members: Array.isArray(group?.members) ? group.members.map(String) : [],
        disabledMembers: Array.isArray(group?.disabled_members) ? group.disabled_members.map(String) : [],
        avatar: String(group?.avatar_url ?? ''),
        chatId: String(group?.chat_id ?? ''),
        chats: Array.isArray(group?.chats) ? group.chats.map(String) : [],
        activationStrategy: Number(group?.activation_strategy ?? 0),
        generationMode: Number(group?.generation_mode ?? 0),
        autoModeDelay: Number(group?.auto_mode_delay ?? 5),
        allowSelfResponses: Boolean(group?.allow_self_responses),
        fav: Boolean(group?.fav),
        lastChat: Number(group?.date_last_chat ?? 0),
    });

    define('group.list', async () => {
        const { modules } = await coreBundle();
        await modules.groupChats.getGroups();
        const groups = modules.groupChats.groups ?? [];
        return { groups: groups.map(toGroup) };
    });

    define('group.create', async (args) => {
        const { core: api, modules } = await coreBundle();
        const name = requireString(args, 'name');
        const members = Array.isArray(args.members) ? args.members.map(String) : [];
        if (!members.length) throw new LibraryError('A group needs at least one member.');
        const created = await postJson('/api/groups/create', {
            name,
            members,
            activation_strategy: Number(args.activationStrategy ?? 0),
            generation_mode: Number(args.generationMode ?? 0),
            allow_self_responses: Boolean(args.allowSelfResponses),
        });
        await api.getCharacters();
        await modules.groupChats.getGroups();
        return { group: toGroup(created) };
    });

    define('group.edit', async (args) => {
        const { core: api, modules } = await coreBundle();
        const id = requireString(args, 'id');
        await modules.groupChats.getGroups();
        const group = (modules.groupChats.groups ?? []).find((item) => String(item.id) === id);
        if (!group) throw new LibraryError(`No group with id ${id}`, 404);
        const patch = args.patch && typeof args.patch === 'object' ? args.patch : {};
        const allowed = ['name', 'members', 'disabled_members', 'activation_strategy',
            'generation_mode', 'auto_mode_delay', 'allow_self_responses', 'fav'];
        for (const key of allowed) {
            if (patch[key] !== undefined) group[key] = patch[key];
        }
        // Upstream's own save path: the same endpoint its UI uses.
        await modules.groupChats.editGroup(id, true, false);
        await api.getCharacters();
        return { group: toGroup(group) };
    });

    define('group.delete', async (args) => {
        const { core: api, modules } = await coreBundle();
        const id = requireString(args, 'id');
        await modules.groupChats.getGroups();
        const group = (modules.groupChats.groups ?? []).find((item) => String(item.id) === id);
        if (!group) throw new LibraryError(`No group with id ${id}`, 404);

        // Opening a group and switching chats schedule a debounced save (1s).
        // Deleting immediately lets that timer write the file back afterwards,
        // which silently resurrects the group. The pending save is given time to
        // land, the delete is issued, and the result is re-checked once.
        const settle = () => new Promise((resolve) => setTimeout(resolve, 1100));
        const present = async () => {
            await modules.groupChats.getGroups();
            return (modules.groupChats.groups ?? []).some((item) => String(item.id) === id);
        };

        await settle();
        await modules.groupChats.deleteGroup(id);
        await new Promise((resolve) => setTimeout(resolve, 250));
        if (await present()) {
            log(`group.delete: ${id} reappeared after a delayed save; deleting again`);
            await settle();
            await modules.groupChats.deleteGroup(id);
            await new Promise((resolve) => setTimeout(resolve, 250));
        }
        await api.getCharacters();
        return { deleted: id, verified: !(await present()) };
    });

    /** Opens a group so generation, chat loading and saving all target it. */
    define('group.open', async (args) => {
        const { core: api, modules } = await coreBundle();
        const id = requireString(args, 'id');
        await modules.groupChats.getGroups();
        const opened = await modules.groupChats.openGroupById(id);
        if (!opened) {
            // Already open is not an error: the caller is asking for the state.
            const context = globalThis.SillyTavern.getContext();
            if (String(context.groupId ?? '') !== id) throw new LibraryError(`Could not open group ${id}`, 400);
        }
        const context = globalThis.SillyTavern.getContext();
        return {
            ...snapshot(),
            groupId: String(context.groupId ?? ''),
            groupName: String((modules.groupChats.groups ?? []).find((g) => String(g.id) === id)?.name ?? ''),
        };
    });

    define('group.chats', async (args) => {
        const { modules } = await coreBundle();
        const id = requireString(args, 'id');
        await modules.groupChats.getGroups();
        const group = (modules.groupChats.groups ?? []).find((item) => String(item.id) === id);
        if (!group) throw new LibraryError(`No group with id ${id}`, 404);
        const chats = await postJson('/api/chats/group/info', { id: group.chat_id });
        const list = [];
        for (const chatId of group.chats ?? []) {
            try {
                const info = String(chatId) === String(group.chat_id)
                    ? chats
                    : await postJson('/api/chats/group/info', { id: chatId });
                list.push({
                    id: String(chatId),
                    messageCount: Number(info?.chat_items ?? 0),
                    preview: String(info?.mes ?? ''),
                    lastMessage: String(info?.last_mes ?? ''),
                    lastUpdated: String(info?.last_date ?? ''),
                });
            } catch {
                // A chat listed in the group but missing on disk is skipped.
            }
        }
        return { chats: list, current: String(group.chat_id ?? '') };
    });

    define('group.chat.new', async (args) => {
        const { modules } = await coreBundle();
        const id = requireString(args, 'id');
        await modules.groupChats.getGroups();
        await modules.groupChats.createNewGroupChat(id);
        return { ...(await groupSnapshot(modules, id)) };
    });

    define('group.chat.open', async (args) => {
        const { modules } = await coreBundle();
        const id = requireString(args, 'id');
        const chatId = requireString(args, 'chatId');
        await modules.groupChats.getGroups();
        await modules.groupChats.openGroupChat(id, chatId);
        return { ...(await groupSnapshot(modules, id)) };
    });

    define('group.chat.delete', async (args) => {
        const { modules } = await coreBundle();
        const id = requireString(args, 'id');
        const chatId = requireString(args, 'chatId');
        await modules.groupChats.getGroups();
        await modules.groupChats.deleteGroupChatByName(id, chatId);
        return { deleted: chatId };
    });

    define('group.chat.rename', async (args) => {
        const { modules } = await coreBundle();
        const id = requireString(args, 'id');
        const chatId = requireString(args, 'chatId');
        const newName = requireString(args, 'newName');
        await modules.groupChats.getGroups();
        await modules.groupChats.renameGroupChat(id, chatId, newName);
        return { chatId: newName };
    });

    /**
     * Sends a turn into the open group.
     *
     * `Generate()` already hands off to upstream's group generator when a group
     * is selected, so this is the same call the single-character chat makes; the
     * only addition is the optional member that should answer first.
     */
    define('group.send', async (args) => {
        const { core: api, modules } = await coreBundle();
        const context = globalThis.SillyTavern.getContext();
        if (!context.groupId) throw new LibraryError('No group is open.', 400);

        const text = typeof args.text === 'string' ? args.text.trim() : '';
        let forceChid;
        if (typeof args.forceMember === 'string' && args.forceMember) {
            await modules.groupChats.unshallowGroupMembers(String(context.groupId));
            const index = context.characters.findIndex((character) => character?.avatar === args.forceMember);
            if (index < 0) throw new LibraryError(`No character with avatar ${args.forceMember}`, 404);
            forceChid = index;
        }

        if (text) {
            context.chat.push({
                name: String(context.name1),
                is_user: true,
                is_system: false,
                send_date: String(Date.now()),
                mes: text,
                extra: {},
            });
            await api.saveChatConditional();
        }

        return runGroupGeneration(api, modules, 'normal', { forceChid });
    });

    define('group.swipe', async (args) => {
        const { core: api, modules } = await coreBundle();
        const id = requireIndex(args, 'id');
        const context = globalThis.SillyTavern.getContext();
        const message = context.chat[id];
        if (!message) throw new LibraryError(`No message at ${id}`, 404);
        if (!Array.isArray(message.swipes) || !message.swipes.length) {
            message.swipe_id = 0;
            message.swipes = [String(message.mes ?? '')];
        }
        const original = Number(message.swipe_id ?? 0);
        const show = (index) => {
            message.swipe_id = index;
            message.mes = String(message.swipes[index] ?? '');
        };
        const direction = args.direction === 'left' ? 'left' : 'right';
        if (direction === 'left') {
            show(original > 0 ? original - 1 : Math.max(0, message.swipes.length - 1));
            await api.saveChatConditional();
            return groupSnapshot(modules, String(context.groupId ?? ''));
        }
        if (original + 1 < message.swipes.length) {
            show(original + 1);
            await api.saveChatConditional();
            return groupSnapshot(modules, String(context.groupId ?? ''));
        }
        // A new variant is a group regeneration of the last turn.
        if (id !== context.chat.length - 1) {
            show(0);
            await api.saveChatConditional();
            return groupSnapshot(modules, String(context.groupId ?? ''));
        }
        message.swipe_id = message.swipes.length;
        try {
            await modules.groupChats.regenerateGroup();
            await api.saveChatConditional();
            return { ...(await groupSnapshot(modules, String(context.groupId ?? ''))), error: null };
        } catch (error) {
            show(Math.min(original, Math.max(0, message.swipes.length - 1)));
            await api.saveChatConditional().catch(() => {});
            return { ...(await groupSnapshot(modules, String(context.groupId ?? ''))), error: String(error?.message ?? error) };
        }
    });

    define('group.message.edit', async (args) => {
        const { core: api, modules } = await coreBundle();
        const id = requireIndex(args, 'id');
        const context = globalThis.SillyTavern.getContext();
        const message = context.chat[id];
        if (!message) throw new LibraryError(`No message at ${id}`, 404);
        message.mes = String(args.text ?? '');
        if (Array.isArray(message.swipes) && message.swipes.length) {
            message.swipes[Number(message.swipe_id ?? 0)] = message.mes;
        }
        await api.saveChatConditional();
        return groupSnapshot(modules, String(context.groupId ?? ''));
    });

    define('group.message.delete', async (args) => {
        const { core: api, modules } = await coreBundle();
        const id = requireIndex(args, 'id');
        const context = globalThis.SillyTavern.getContext();
        if (!context.chat[id]) throw new LibraryError(`No message at ${id}`, 404);
        context.chat.splice(id, 1);
        await api.saveChatConditional();
        return groupSnapshot(modules, String(context.groupId ?? ''));
    });

    // ---- presets (all kinds) -----------------------------------------------

    /**
     * Preset kinds the API exposes. Each maps to its own folder on disk and its
     * own block in the settings payload — that is how the web UI's preset
     * manager sees them, and the same data is used here.
     */
    const PRESET_KINDS = {
        openai: { apiId: 'openai', field: 'oai', namesField: 'openai_setting_names', valuesField: 'openai_settings' },
        instruct: { apiId: 'instruct', field: 'instruct' },
        context: { apiId: 'context', field: 'context' },
        sysprompt: { apiId: 'sysprompt', field: 'sysprompt' },
        reasoning: { apiId: 'reasoning', field: 'reasoning' },
        textgen: { apiId: 'textgenerationwebui', field: 'textgen', namesField: 'textgenerationwebui_preset_names', valuesField: 'textgenerationwebui_presets' },
    };

    const parsePreset = (value) => {
        if (typeof value !== 'string') return value && typeof value === 'object' ? value : {};
        try { return JSON.parse(value); } catch { return {}; }
    };

    define('preset.kinds', async () => {
        const result = await postJson('/api/settings/get');
        const settings = parsePreset(result?.settings);
        const kinds = [];
        for (const [kind, spec] of Object.entries(PRESET_KINDS)) {
            let names = [];
            if (spec.namesField) {
                names = Array.isArray(result?.[spec.namesField]) ? result[spec.namesField].map(String) : [];
            } else {
                const list = Array.isArray(result?.[spec.field]) ? result[spec.field] : [];
                names = list.map((item) => String(item?.name ?? '')).filter(Boolean);
            }
            kinds.push({ kind, names });
        }
        return { kinds, current: String(settings?.oai_settings?.preset_settings_openai ?? '') };
    });

    /** One preset's full contents, by kind and name. */
    define('preset.detail', async (args) => {
        const kind = requireString(args, 'kind');
        const name = requireString(args, 'name');
        const spec = PRESET_KINDS[kind];
        if (!spec) throw new LibraryError(`Unknown preset kind ${kind}`);
        const result = await postJson('/api/settings/get');

        if (kind === 'openai' || kind === 'textgen') {
            const names = Array.isArray(result?.[spec.namesField]) ? result[spec.namesField].map(String) : [];
            const values = Array.isArray(result?.[spec.valuesField]) ? result[spec.valuesField] : [];
            const index = names.indexOf(name);
            if (index < 0) throw new LibraryError(`No preset named ${name}`, 404);
            return { kind, name, preset: parsePreset(values[index]), editable: kind === 'textgen' };
        }

        const list = Array.isArray(result?.[spec.field]) ? result[spec.field] : [];
        const preset = list.find((item) => String(item?.name ?? '') === name);
        if (!preset) throw new LibraryError(`No preset named ${name}`, 404);
        return { kind, name, preset, editable: true };
    });

    /** Creates or overwrites a preset file through upstream's own endpoint. */
    define('preset.save', async (args) => {
        const { core: api, modules } = await coreBundle();
        const kind = requireString(args, 'kind');
        const name = requireString(args, 'name');
        const preset = args.preset && typeof args.preset === 'object' ? args.preset : null;
        if (!preset) throw new LibraryError('preset is required');
        const spec = PRESET_KINDS[kind];
        if (!spec) throw new LibraryError(`Unknown preset kind ${kind}`);
        await postJson('/api/presets/save', { name, apiId: spec.apiId, preset });
        // The core caches the settings it read at startup; a new file only shows
        // up after its own loader runs again.
        await api.getSettings();
        restorePromptOrder?.(modules);
        return { kind, name };
    });

    /**
     * Imports a preset file exported from a tavern install.
     *
     * Two shapes exist: a plain preset (the settings form's own export) and the
     * "full" export, which also carries `prompts` and `prompt_order`. Both are
     * accepted; the full one additionally replaces the prompt manager's content,
     * which is what upstream's import does.
     */
    define('preset.import', async (args) => {
        const { core: api, modules } = await coreBundle();
        const kind = requireString(args, 'kind');
        const raw = requireString(args, 'data');
        const spec = PRESET_KINDS[kind];
        if (!spec) throw new LibraryError(`Unknown preset kind ${kind}`);

        let incoming;
        try {
            incoming = typeof raw === 'string' ? JSON.parse(raw) : raw;
        } catch (error) {
            throw new LibraryError(`预设文件不是合法 JSON：${error.message}`);
        }
        if (!incoming || typeof incoming !== 'object' || Array.isArray(incoming)) {
            throw new LibraryError('预设文件内容不是一个对象。');
        }

        const name = String(args.name ?? incoming.name ?? incoming.preset_settings_name ?? '').trim();
        if (!name) throw new LibraryError('导入的预设没有名称。');

        // Full exports nest the preset under `preset` and carry the prompt list.
        const preset = incoming.preset && typeof incoming.preset === 'object' ? incoming.preset : incoming;
        const clean = { ...preset };
        delete clean.prompts;
        delete clean.prompt_order;
        delete clean.preset;

        await postJson('/api/presets/save', { name, apiId: spec.apiId, preset: clean });

        if (Array.isArray(incoming.prompts) && incoming.prompts.length) {
            const settings = await readSettingsFile();
            const manager = modules.openai.promptManager;
            const dummyId = manager?.configuration?.promptOrder?.dummyId;
            const order = Array.isArray(incoming.prompt_order) && incoming.prompt_order.length
                ? incoming.prompt_order
                : null;
            if (settings.oai_settings) {
                settings.oai_settings.prompts = incoming.prompts;
                if (order) {
                    settings.oai_settings.prompt_order = [{ character_id: dummyId, order: order[0]?.order ?? order }];
                }
            }
            await postJson('/api/settings/save', settings);
            await api.getSettings();
            restorePromptOrder?.(modules);
        } else {
            await api.getSettings();
            restorePromptOrder?.(modules);
        }

        return { kind, name, prompts: Array.isArray(incoming.prompts) ? incoming.prompts.length : 0 };
    });

    define('preset.delete', async (args) => {
        const { core: api, modules } = await coreBundle();
        const kind = requireString(args, 'kind');
        const name = requireString(args, 'name');
        const spec = PRESET_KINDS[kind];
        if (!spec) throw new LibraryError(`Unknown preset kind ${kind}`);
        if (kind === 'openai') throw new LibraryError('对话补全预设的删除请使用预设页的删除按钮。');
        await postJson('/api/presets/delete', { name, apiId: spec.apiId });
        await api.getSettings();
        restorePromptOrder?.(modules);
        return { deleted: name };
    });

    /** The shipped default for a preset name, so an edit can be reverted. */
    define('preset.restore', async (args) => {
        const { core: api, modules } = await coreBundle();
        const kind = requireString(args, 'kind');
        const name = requireString(args, 'name');
        const spec = PRESET_KINDS[kind];
        if (!spec) throw new LibraryError(`Unknown preset kind ${kind}`);
        const restored = await postJson('/api/presets/restore', { name, apiId: spec.apiId });
        if (!restored?.isDefault) return { restored: false, preset: restored?.preset ?? {} };
        await postJson('/api/presets/save', { name, apiId: spec.apiId, preset: restored.preset });
        await api.getSettings();
        restorePromptOrder?.(modules);
        return { restored: true, preset: restored.preset };
    });

    /** Creates a copy of a chat-completion preset (the editable kind). */
    define('preset.duplicate', async (args) => {
        const { core: api, modules } = await coreBundle();
        const kind = requireString(args, 'kind');
        const name = requireString(args, 'name');
        const newName = requireString(args, 'newName');
        const spec = PRESET_KINDS[kind];
        if (!spec) throw new LibraryError(`Unknown preset kind ${kind}`);
        const result = await postJson('/api/settings/get');
        let preset = {};
        if (spec.namesField) {
            const names = Array.isArray(result?.[spec.namesField]) ? result[spec.namesField].map(String) : [];
            const values = Array.isArray(result?.[spec.valuesField]) ? result[spec.valuesField] : [];
            const index = names.indexOf(name);
            if (index < 0) throw new LibraryError(`No preset named ${name}`, 404);
            preset = parsePreset(values[index]);
        } else {
            const list = Array.isArray(result?.[spec.field]) ? result[spec.field] : [];
            preset = list.find((item) => String(item?.name ?? '') === name);
            if (!preset) throw new LibraryError(`No preset named ${name}`, 404);
            preset = { ...preset, name: newName };
        }
        await postJson('/api/presets/save', { name: newName, apiId: spec.apiId, preset });
        await api.getSettings();
        restorePromptOrder?.(modules);
        return { kind, name: newName };
    });

    // ---- extensions --------------------------------------------------------

    /** Installed extensions, their manifests and whether they are enabled. */
    define('extension.list', async () => {
        const { modules } = await coreBundle();
        const discovered = await postJsonArray('/api/extensions/discover', null, 'GET');
        const disabled = modules.extensions.extension_settings?.disabledExtensions ?? [];
        const extensions = discovered.map((entry) => {
            const name = String(entry?.name ?? '');
            const manifest = modules.extensions.getExtensionManifest(name) ?? {};
            const short = name.includes('/') ? name.split('/').pop() : name;
            return {
                name,
                shortName: short,
                type: String(entry?.type ?? ''),
                displayName: String(manifest.display_name ?? short),
                version: String(manifest.version ?? ''),
                author: String(manifest.author ?? ''),
                description: String(manifest.description ?? ''),
                enabled: !disabled.includes(name) && !disabled.includes(short),
                hasManifest: Boolean(manifest && Object.keys(manifest).length),
            };
        });
        return { extensions };
    });

    define('extension.toggle', async (args) => {
        const { modules } = await coreBundle();
        const name = requireString(args, 'name');
        const enabled = args.enabled !== false;
        if (enabled) {
            await modules.extensions.enableExtension(name, false);
        } else {
            await modules.extensions.disableExtension(name, false);
        }
        return { name, enabled, reloadRequired: true };
    });

    define('extension.install', async (args) => {
        const { modules } = await coreBundle();
        const url = requireString(args, 'url');
        const branch = typeof args.branch === 'string' ? args.branch : '';
        // Upstream's own installer: validates the URL, clones, and reports the
        // manifest it found. It shows a third-party warning in the web UI; the
        // native caller is the one making the decision, so the raw endpoint is
        // used instead of the UI wrapper.
        const installed = await postJson('/api/extensions/install', { url, global: false, branch });
        await modules.extensions.loadExtensionSettings({}, false, false);
        return { installed };
    });

    define('extension.delete', async (args) => {
        const { modules } = await coreBundle();
        const name = requireString(args, 'name');
        await postJson('/api/extensions/delete', { extensionName: name, global: false });
        await modules.extensions.loadExtensionSettings({}, false, false);
        return { deleted: name };
    });

    define('extension.update', async (args) => {
        const { modules } = await coreBundle();
        const name = requireString(args, 'name');
        const updated = await postJson('/api/extensions/update', { extensionName: name, global: false });
        await modules.extensions.loadExtensionSettings({}, false, false);
        return { updated };
    });

    /** The branch list of an installed git extension, for the update picker. */
    define('extension.branches', async (args) => {
        const name = requireString(args, 'name');
        const result = await postJson('/api/extensions/branches', { extensionName: name, global: false });
        return { branches: Array.isArray(result) ? result : [] };
    });

    // ---- world info --------------------------------------------------------




    define('worldinfo.summary', async () => {
        const { modules } = await coreBundle();
        await modules.worldInfo.updateWorldInfoList();
        const names = modules.worldInfo.world_names ?? [];
        const active = modules.worldInfo.selected_world_info ?? [];
        return {
            books: names.map((name) => ({ name: String(name), active: active.includes(name) })),
            active: active.map(String),
        };
    });

    define('worldinfo.deleteBook', async (args) => {
        const { modules } = await coreBundle();
        const name = requireString(args, 'name');
        await postJson('/api/worldinfo/delete', { name });
        await modules.worldInfo.updateWorldInfoList();
        return { deleted: name };
    });

    /** Merges one entry into a book without disturbing untouched fields. */
    define('worldinfo.saveEntry', async (args) => {
        const { modules } = await coreBundle();
        const book = requireString(args, 'book');
        const entry = args.entry && typeof args.entry === 'object' ? args.entry : null;
        if (!entry) throw new LibraryError('entry is required');
        const data = await modules.worldInfo.loadWorldInfo(book);
        if (!data) throw new LibraryError(`No world info named ${book}`, 404);
        data.entries = data.entries ?? {};
        const entries = Object.values(data.entries);
        const uid = Number.isFinite(entry.uid) ? Number(entry.uid) : Math.max(-1, ...entries.map((item) => Number(item.uid ?? -1))) + 1;
        const existing = data.entries[uid] ?? { uid };
        data.entries[uid] = { ...existing, ...entry, uid };
        await modules.worldInfo.saveWorldInfo(book, data);
        return { uid, book };
    });

    define('worldinfo.deleteEntry', async (args) => {
        const { modules } = await coreBundle();
        const book = requireString(args, 'book');
        const uid = requireIndex(args, 'uid');
        const data = await modules.worldInfo.loadWorldInfo(book);
        if (!data?.entries?.[uid]) throw new LibraryError(`No entry ${uid} in ${book}`, 404);
        delete data.entries[uid];
        await modules.worldInfo.saveWorldInfo(book, data);
        return { deleted: uid };
    });

    // ---- presets and prompt order -----------------------------------------

    const readSettingsFile = async () => {
        const result = await postJson('/api/settings/get');
        const raw = typeof result === 'string' ? result : result?.settings;
        return raw ? JSON.parse(raw) : {};
    };

    define('preset.list', async () => {
        const result = await postJson('/api/settings/get');
        const names = Array.isArray(result.openai_setting_names) ? result.openai_setting_names : [];
        const presets = Array.isArray(result.openai_settings) ? result.openai_settings : [];
        const list = names.map((name, index) => {
            let params = {};
            try { params = JSON.parse(presets[index] ?? '{}'); } catch { /* skip malformed preset */ }
            return {
                name: String(name),
                temperature: Number(params.temp_openai ?? 1),
                maxTokens: Number(params.openai_max_tokens ?? 0),
                topP: Number(params.top_p_openai ?? 1),
                frequencyPenalty: Number(params.freq_pen_openai ?? 0),
                presencePenalty: Number(params.pres_pen_openai ?? 0),
                chatCompletionSource: String(params.chat_completion_source ?? ''),
                model: String(params.custom_model ?? params.openai_model ?? ''),
            };
        });
        const settings = await readSettingsFile();
        return {
            presets: list,
            current: String(settings?.oai_settings?.preset_settings_openai ?? ''),
        };
    });

    define('preset.apply', async (args) => {
        const { core: api, modules } = await coreBundle();
        const name = requireString(args, 'name');
        const result = await postJson('/api/settings/get');
        const names = Array.isArray(result.openai_setting_names) ? result.openai_setting_names : [];
        const presets = Array.isArray(result.openai_settings) ? result.openai_settings : [];
        const index = names.indexOf(name);
        if (index < 0) throw new LibraryError(`No preset named ${name}`, 404);
        let preset = {};
        try { preset = JSON.parse(presets[index] ?? '{}'); } catch { /* ignore */ }

        const settings = await readSettingsFile();
        const patch = { preset_settings_openai: name };
        // Upstream applies only the keys its settings form owns; anything else
        // in the preset is foreign data and must not leak into settings.
        for (const [key, [, setting]] of Object.entries(modules.openai.settingsToUpdate ?? {})) {
            if (preset[key] !== undefined) patch[setting] = preset[key];
        }
        if (preset.extensions && typeof preset.extensions === 'object') patch.extensions = preset.extensions;
        Object.assign(settings, patch);
        if (settings.oai_settings && typeof settings.oai_settings === 'object') Object.assign(settings.oai_settings, patch);
        if (patch.chat_completion_source) settings.main_api = 'openai';
        await postJson('/api/settings/save', settings);
        await api.getSettings();
        restorePromptOrder?.(modules);
        return { applied: name, patched: Object.keys(patch) };
    });

    define('prompt.list', async () => {
        const { modules } = await coreBundle();
        const manager = modules.openai.promptManager;
        if (!manager) throw new LibraryError('The prompt manager is not ready', 503);
        restorePromptOrder?.(modules);
        // The order list is the editable surface: every prompt the manager
        // knows about, in the order generation will use, enabled or not. The
        // collection builder omits disabled prompts, so it cannot back an
        // editor that has to turn them back on.
        const active = manager.activeCharacter ?? { id: manager.configuration?.promptOrder?.dummyId };
        const order = manager.getPromptOrderForCharacter(active);
        const prompts = manager.serviceSettings.prompts ?? [];
        return {
            prompts: order.map((item) => {
                const prompt = prompts.find((candidate) => candidate.identifier === item.identifier);
                return {
                    identifier: String(item.identifier ?? ''),
                    name: String(prompt?.name ?? item.identifier ?? ''),
                    role: String(prompt?.role ?? 'system'),
                    content: String(prompt?.content ?? ''),
                    systemPrompt: Boolean(prompt?.system_prompt),
                    marker: Boolean(prompt?.marker),
                    enabled: item.enabled !== false,
                };
            }).filter((prompt) => prompt.name),
        };
    });

    define('prompt.toggle', async (args) => {
        const { core: api, modules } = await coreBundle();
        const identifier = requireString(args, 'identifier');
        const enabled = args.enabled !== false;
        const manager = modules.openai.promptManager;
        if (!manager) throw new LibraryError('The prompt manager is not ready', 503);
        // The manager builds its collection for `activeCharacter`, which in the
        // global strategy is the sentinel id it selected at init — not
        // necessarily the id its configuration object names.
        const activeId = manager.activeCharacter?.id ?? manager.configuration?.promptOrder?.dummyId;
        const orders = manager.serviceSettings.prompt_order ?? [];
        const entry = orders.find((item) => String(item.character_id) === String(activeId)) ?? orders[0];
        if (!entry) throw new LibraryError('The prompt order is empty', 503);
        const item = (entry.order ?? []).find((prompt) => prompt.identifier === identifier);
        if (!item) throw new LibraryError(`No prompt ${identifier}`, 404);
        item.enabled = enabled;
        if (typeof manager.saveServiceSettings === 'function') await manager.saveServiceSettings();
        await api.saveSettings();
        return { identifier, enabled };
    });

    // ---- settings snapshot -------------------------------------------------

    define('settings.snapshot', async () => {
        const { core: api, modules } = await coreBundle();
        const settings = await readSettingsFile();
        const oai = settings.oai_settings ?? {};
        const openaiSettings = modules.openai.oai_settings ?? {};
        const result = await postJson('/api/settings/get');
        const modelKeys = {
            openai: 'openai_model',
            claude: 'claude_model',
            openrouter: 'openrouter_model',
            deepseek: 'deepseek_model',
            groq: 'groq_model',
            mistralai: 'mistralai_model',
            makersuite: 'google_model',
            xai: 'xai_model',
            zai: 'zai_model',
            perplexity: 'perplexity_model',
            cohere: 'cohere_model',
            custom: 'custom_model',
        };
        const source = String(openaiSettings.chat_completion_source ?? oai.chat_completion_source ?? 'openai');
        return {
            userName: String(settings.username ?? 'User'),
            userAvatar: String(settings.user_avatar ?? ''),
            // The live value is what generation uses; the saved file can still
            // name the Horde until the next settings write.
            mainApi: String(api.main_api ?? settings.main_api ?? ''),
            source,
            currentModel: String(openaiSettings[modelKeys[source] ?? 'custom_model'] ?? ''),
            customUrl: String(openaiSettings.custom_url ?? ''),
            customModel: String(openaiSettings.custom_model ?? ''),
            openaiModel: String(openaiSettings.openai_model ?? ''),
            reverseProxy: String(openaiSettings.reverse_proxy ?? ''),
            maxContext: Number(openaiSettings.openai_max_context ?? 8192),
            maxTokens: Number(openaiSettings.openai_max_tokens ?? 300),
            temperature: Number(openaiSettings.temp_openai ?? 1),
            topP: Number(openaiSettings.top_p_openai ?? 1),
            topK: Number(openaiSettings.top_k_openai ?? 0),
            frequencyPenalty: Number(openaiSettings.freq_pen_openai ?? 0),
            presencePenalty: Number(openaiSettings.pres_pen_openai ?? 0),
            stream: Boolean(openaiSettings.stream_openai),
            presetName: String(openaiSettings.preset_settings_openai ?? ''),
            presetNames: Array.isArray(result.openai_setting_names) ? result.openai_setting_names.map(String) : [],
            worldNames: Array.isArray(result.world_names) ? result.world_names.map(String) : [],
            // Generation parameters the settings screens edit (images 2–5).
            maxContextUnlocked: Boolean(openaiSettings.max_context_unlocked),
            n: Number(openaiSettings.n ?? 1),
            seed: Number(openaiSettings.seed ?? -1),
            namesBehavior: Number(openaiSettings.names_behavior ?? 0),
            continuePostfix: String(openaiSettings.continue_postfix ?? ' '),
            mediaInlining: Boolean(openaiSettings.media_inlining ?? true),
            inlineImageQuality: String(openaiSettings.inline_image_quality ?? 'auto'),
            reasoningEffort: String(openaiSettings.reasoning_effort ?? 'auto'),
            postProcessing: String(openaiSettings.custom_prompt_post_processing ?? ''),
            bypassStatusCheck: Boolean(openaiSettings.bypass_status_check),
            showExternalModels: Boolean(openaiSettings.show_external_models),
            autoConnect: Boolean(openaiSettings.auto_connect ?? settings.auto_connect),
            // Connection screen extras (images 6–7).
            logitBiasPresets: Object.keys(openaiSettings.bias_presets ?? {}),
            logitBiasSelected: String(openaiSettings.bias_preset_selected ?? ''),
            openrouterProviders: Array.isArray(openaiSettings.openrouter_providers) ? openaiSettings.openrouter_providers.map(String) : [],
            azureBaseUrl: String(openaiSettings.azure_base_url ?? ''),
            azureDeployment: String(openaiSettings.azure_deployment_name ?? ''),
            apiKeySet: Boolean(openaiSettings.api_key_set ?? false),
            profiles: Array.isArray(settings.connection_profiles) ? settings.connection_profiles.map((p) => String(p?.name ?? '')) : [],
            profileSelected: String(settings.selected_connection_profile ?? ''),
        };
    });

    /** Checks that the configured provider answers a model-list request. */
    define('settings.test', async () => {
        const { modules } = await coreBundle();
        const settings = modules.openai.oai_settings ?? {};
        try {
            const result = await postJson('/api/backends/chat-completions/status', {
                chat_completion_source: settings.chat_completion_source,
                custom_url: settings.custom_url,
                custom_include_headers: settings.custom_include_headers,
                reverse_proxy: settings.reverse_proxy,
                proxy_password: settings.proxy_password,
            });
            if (result?.error) {
                return { ok: false, message: '服务没有返回模型列表；地址或密钥可能不正确。' };
            }
            const models = Array.isArray(result?.data) ? result.data : [];
            return {
                ok: true,
                message: models.length ? `连接成功，可用模型 ${models.length} 个。` : '服务已响应。',
                models: models.map((model) => String(model?.id ?? model?.name ?? '')).filter(Boolean).slice(0, 20),
            };
        } catch (error) {
            return { ok: false, message: `连接失败：${error?.message ?? error}` };
        }
    });

    /** Model choices the current provider reports (connection screen). */
    define('settings.models', async () => {
        const { modules } = await coreBundle();
        const settings = modules.openai.oai_settings ?? {};
        try {
            const result = await postJson('/api/backends/chat-completions/status', {
                chat_completion_source: settings.chat_completion_source,
                custom_url: settings.custom_url,
                custom_include_headers: settings.custom_include_headers,
                reverse_proxy: settings.reverse_proxy,
                proxy_password: settings.proxy_password,
            });
            if (result?.error) return { models: [], ok: false };
            const list = Array.isArray(result?.data) ? result.data : [];
            return {
                ok: true,
                models: list
                    .map((model) => String(model?.id ?? model?.name ?? ''))
                    .filter(Boolean)
                    .sort(),
            };
        } catch (error) {
            return { models: [], ok: false, message: String(error?.message ?? error) };
        }
    });

    // ---- appearance, general, test message ---------------------------------

    define('appearance.themes', async () => {
        const result = await postJson('/api/settings/get');
        const themes = Array.isArray(result?.themes) ? result.themes : [];
        const live = { ...(result?.settings ? JSON.parse(result.settings) : {}), ...(globalThis.SillyTavern?.getContext?.().powerUserSettings ?? {}) };
        const current = String(live.theme ?? '');
        return {
            themes: themes.map((theme) => String(theme?.name ?? '')).filter(Boolean),
            current,
        };
    });

    define('appearance.get', async () => {
        const live = globalThis.SillyTavern?.getContext?.().powerUserSettings ?? {};
        return {
            fontScale: Number(live.font_scale ?? 1),
            blur: !live.fast_ui_mode && !live.no_blur,
            reducedMotion: Boolean(live.reduced_motion),
        };
    });

    define('appearance.save', async (args) => {
        const { core: api } = await coreBundle();
        const settings = await readSettingsFile();
        const live = globalThis.SillyTavern?.getContext?.().powerUserSettings;
        const patch = {};
        if (typeof args.theme === 'string' && args.theme) patch.theme = args.theme;
        if (Number.isFinite(args.fontScale)) patch.font_scale = Number(args.fontScale);
        if (typeof args.blur === 'boolean') patch.no_blur = !args.blur;
        if (typeof args.reducedMotion === 'boolean') patch.reduced_motion = Boolean(args.reducedMotion);
        Object.assign(settings, patch);
        if (live) Object.assign(live, patch);
        await postJson('/api/settings/save', settings);
        try { await api.saveSettings(); } catch { /* already written */ }
        return { saved: true, patched: Object.keys(patch) };
    });

    define('general.get', async () => {
        const live = globalThis.SillyTavern?.getContext?.().powerUserSettings ?? {};
        return {
            swipes: live.swipes !== false,
            timestamps: Boolean(live.timestamps_enabled),
            tokenCounts: Boolean(live.message_token_count_enabled),
            messageIds: Boolean(live.mesIDDisplay_enabled),
            autoContinue: Boolean(live.auto_continue?.enabled),
            autoScroll: live.auto_scroll !== false,
        };
    });

    define('general.save', async (args) => {
        const { core: api } = await coreBundle();
        const settings = await readSettingsFile();
        const live = globalThis.SillyTavern?.getContext?.().powerUserSettings;
        const patch = {};
        const bools = {
            swipes: 'swipes',
            timestamps: 'timestamps_enabled',
            tokenCounts: 'message_token_count_enabled',
            messageIds: 'mesIDDisplay_enabled',
            autoScroll: 'auto_scroll',
        };
        for (const [key, setting] of Object.entries(bools)) {
            if (typeof args[key] === 'boolean') patch[setting] = args[key];
        }
        if (typeof args.autoContinue === 'boolean') {
            patch.auto_continue = { ...(live?.auto_continue ?? settings.auto_continue ?? {}), enabled: args.autoContinue };
        }
        Object.assign(settings, patch);
        if (live) Object.assign(live, patch);
        await postJson('/api/settings/save', settings);
        try { await api.saveSettings(); } catch { /* already written */ }
        return { saved: true };
    });

    /**
     * Sends one short message end to end.
     *
     * Distinct from `settings.test` (a model-list probe): a provider can list
     * models and still refuse a completion, so the connection screen offers a
     * real request. The chat it writes to is upstream's own scratch chat.
     */
    define('settings.testMessage', async (args) => {
        const { core: api, modules } = await coreBundle();
        const text = typeof args.text === 'string' && args.text ? args.text : 'Hello';
        const blocked = generationPreflight(api, modules);
        if (blocked) return { error: blocked };
        const context = globalThis.SillyTavern.getContext();
        const before = context.chat.length;
        context.chat.push({
            name: String(context.name1),
            is_user: true,
            is_system: false,
            send_date: String(Date.now()),
            mes: text,
            extra: {},
        });
        const result = await runGeneration(api, modules, 'normal');
        // The probe is not part of the conversation: both turns are removed
        // again so the connection screen leaves no trace in the chat.
        context.chat.length = before;
        await api.saveChatConditional().catch(() => {});
        return { error: result.error };
    });

    // ---- backgrounds -------------------------------------------------------

    define('background.list', async () => {
        const settings = await readSettingsFile();
        const powerUser = globalThis.SillyTavern?.getContext?.().powerUserSettings ?? {};
        const result = await postJson('/api/backgrounds/all');
        const images = Array.isArray(result?.images) ? result.images : [];
        const current = String(powerUser.background ?? settings.background?.name ?? '');
        return {
            backgrounds: images.map((image) => ({
                filename: String(image?.filename ?? ''),
                animated: Boolean(image?.isAnimated),
                current: String(image?.filename ?? '') === current,
            })),
            current,
        };
    });

    define('background.select', async (args) => {
        const { core: api } = await coreBundle();
        const name = String(args?.name ?? '');
        // Upstream keeps the chosen background in the power-user settings and
        // applies it on load; the same field is written here.
        const live = globalThis.SillyTavern?.getContext?.().powerUserSettings;
        if (live) live.background = name;
        const settings = await readSettingsFile();
        if (!settings.background || typeof settings.background !== 'object') settings.background = {};
        settings.background.name = name;
        await postJson('/api/settings/save', settings);
        try { await api.saveSettings(); } catch { /* the file is already written */ }
        return { selected: name };
    });

    // ---- personas ----------------------------------------------------------

    define('persona.list', async () => {
        const settings = await readSettingsFile();
        // Personas live in the live power-user object; the saved copy is only a
        // snapshot, and a persona created a moment ago may not be in it yet.
        const powerUser = globalThis.SillyTavern.getContext().powerUserSettings ?? {};
        const source = powerUser.personas && Object.keys(powerUser.personas).length
            ? powerUser.personas
            : (settings.personas ?? {});
        const details = powerUser.persona_descriptions ?? {};
        const personas = {};
        for (const [avatar, name] of Object.entries(source)) {
            const detail = details[avatar] ?? {};
            personas[avatar] = {
                name: String(name ?? avatar),
                description: String(detail.description ?? ''),
                title: String(detail.title ?? ''),
            };
        }
        const current = String(settings.user_avatar ?? powerUser.user_avatar ?? '');
        return {
            personas: Object.entries(personas).map(([avatar, persona]) => ({
                avatar,
                name: persona.name,
                description: persona.description,
                title: persona.title,
                current: avatar === current,
            })),
        };
    });

    /** Stores a persona avatar through the endpoint the web UI uploads to. */
    define('persona.upload', async (args) => {
        const fileName = requireString(args, 'fileName');
        const data = requireString(args, 'data');
        // Upstream's upload route wants the overwrite name as a query flag and
        // reads the file from the `avatar` field.
        const base = fileName.replace(/\.[^.]+$/, '');
        const target = `${base}.png`;
        const stored = await postForm(`/api/avatars/upload?overwrite_name=${encodeURIComponent(target)}`, {}, {
            name: fileName,
            type: 'image/png',
            data: Buffer.from(data, 'base64'),
        });
        const avatar = String(stored?.path ?? target);
        const { modules } = await coreBundle();
        const name = typeof args.name === 'string' && args.name ? args.name : base;
        const description = typeof args.description === 'string' ? args.description : '';
        // The upload stores the image; a persona is the image plus the settings
        // entry, which upstream creates through initPersona().
        await modules.personas.initPersona(avatar, name, description, '');
        log(`persona created ${avatar} (${name})`);
        return { avatar, name };
    });

    define('persona.select', async (args) => {
        const { core: api } = await coreBundle();
        const avatar = requireString(args, 'avatar');
        const settings = await readSettingsFile();
        const live = globalThis.SillyTavern.getContext().powerUserSettings ?? {};
        const name = live.personas?.[avatar] ?? settings.personas?.[avatar]?.name;
        if (!name) throw new LibraryError(`No persona with avatar ${avatar}`, 404);
        settings.user_avatar = avatar;
        // Upstream reads the speaker name back from the saved `username`, so the
        // choice is written there as well as applied to the live object.
        settings.username = String(name);
        await postJson('/api/settings/save', settings);
        live.user_avatar = avatar;
        api.setUserName(String(name), { toastPersonaNameChange: false });
        return { name: String(name), avatar };
    });

    return {
        methods: [...methods.keys()],
        call(name, args) {
            const handler = methods.get(name);
            if (!handler) throw new LibraryError(`Unknown method: ${name}`, 501, 'METHOD_NOT_IMPLEMENTED');
            return handler(args ?? {});
        },
    };
}

function requireString(args, key) {
    const value = args?.[key];
    if (typeof value !== 'string' || !value) throw new LibraryError(`${key} must be a non-empty string`);
    return value;
}

function requireIndex(args, key) {
    const value = Number(args?.[key]);
    if (!Number.isInteger(value) || value < 0) throw new LibraryError(`${key} must be a non-negative integer`);
    return value;
}
