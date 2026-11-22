// Exercises every management RPC the native UI uses, against the real core.
import assert from 'node:assert/strict';
import { startMockModel } from './support/mock-model.mjs';
import { installResolversAndBoot } from './support/engine-harness.mjs';

const model = await startMockModel();
const h = await installResolversAndBoot();
const step = async (name, fn) => {
    try {
        const value = await fn();
        console.log('ok  ', name, value === undefined ? '' : JSON.stringify(value).slice(0, 160));
        return value;
    } catch (error) {
        console.log('FAIL', name, '-', error.message);
        throw error;
    }
};

try {
    await step('startup selects chat-completion API', async () => {
        const settings = await h.call('settings.snapshot');
        assert.equal(settings.mainApi, 'openai');
        return { mainApi: settings.mainApi, source: settings.source };
    });

    await step('character.list', async () => {
        const r = await h.call('character.list');
        assert.ok(r.characters.length >= 1);
        assert.ok(r.characters[0].avatar);
        return { count: r.characters.length, first: r.characters[0].avatar };
    });

    await step('character.get', async () => {
        const r = await h.call('character.get', { avatar: 'default_Seraphina.png' });
        assert.equal(r.character.name, 'Seraphina');
        return { name: r.character.name, first: r.character.firstMes.slice(0, 20) };
    });

    await step('character.create', async () => {
        const r = await h.call('character.create', { card: { name: 'TestCard', description: 'd', firstMes: 'hello', tags: ['a', 'b'] } });
        assert.ok(r.avatar);
        return { avatar: r.avatar };
    });

    await step('character.edit', async () => {
        const r = await h.call('character.edit', { avatar: 'TestCard.png', card: { name: 'TestCard', description: 'edited', firstMes: 'hello' } });
        assert.equal(r.character.description, 'edited');
        return { avatar: r.character.avatar };
    });

    await step('character.select', async () => {
        const r = await h.call('character.select', { avatar: 'default_Seraphina.png' });
        return { messages: r.messages.length, char: r.characterName };
    });

    await step('chat.new', async () => {
        const r = await h.call('chat.new', { avatar: 'default_Seraphina.png' });
        return { messages: r.messages.length, file: r.fileName };
    });

    await step('chat.list', async () => {
        const r = await h.call('chat.list', { avatar: 'default_Seraphina.png' });
        assert.ok(r.chats.length >= 1);
        return { count: r.chats.length, first: r.chats[0].fileName };
    });

    const chatList = await h.call('chat.list', { avatar: 'default_Seraphina.png' });
    await step('chat.read', async () => {
        const r = await h.call('chat.read', { avatar: 'default_Seraphina.png', fileName: chatList.chats[0].fileName });
        return { messages: r.messages.length };
    });

    await step('chat.open', async () => {
        const r = await h.call('chat.open', { avatar: 'default_Seraphina.png', fileName: chatList.chats[0].fileName });
        return { messages: r.messages.length, file: r.fileName };
    });

    await step('settings.update', async () => {
        return await h.call('settings.update', {
            patch: {
                chat_completion_source: 'custom',
                custom_url: model.url,
                custom_model: 'mock-model',
                openai_max_context: 8192,
                openai_max_tokens: 300,
                stream_openai: false,
            },
        });
    });

    await step('chat.send', async () => {
        const r = await h.call('chat.send', { text: 'Hello from native UI' });
        assert.equal(r.error, null);
        assert.ok(r.messages.at(-1).text.includes('MOCK_REPLY'));
        return { messages: r.messages.length, last: r.messages.at(-1).text.slice(0, 30) };
    });

    await step('message.edit', async () => {
        const current = await h.call('chat.messages');
        const target = current.messages.length - 1;
        const r = await h.call('message.edit', { id: target, text: 'EDITED TEXT' });
        assert.equal(r.messages[target].text, 'EDITED TEXT');
        return { id: target };
    });

    await step('message.swipe', async () => {
        const current = await h.call('chat.messages');
        const target = current.messages.length - 1;
        const r = await h.call('message.swipe', { id: target, direction: 'right' });
        return { id: target, messages: r.messages.length, swipes: r.messages[target].swipes.length };
    });

    await step('message.delete', async () => {
        const current = await h.call('chat.messages');
        const before = current.messages.length;
        const r = await h.call('message.delete', { id: before - 1 });
        assert.equal(r.messages.length, before - 1);
        return { before, after: r.messages.length };
    });

    await step('worldinfo.summary', async () => {
        const r = await h.call('worldinfo.summary');
        assert.ok(r.books.length >= 1);
        return { books: r.books.map((b) => b.name) };
    });

    await step('worldinfo.get', async () => {
        const r = await h.call('worldinfo.get', { name: 'Eldoria' });
        return { entries: Object.keys(r.data.entries ?? {}).length };
    });

    await step('worldinfo.saveEntry', async () => {
        const r = await h.call('worldinfo.saveEntry', {
            book: 'Eldoria',
            entry: { comment: 'native entry', key: ['nativekey'], content: 'NATIVE_WI', order: 100 },
        });
        const check = await h.call('worldinfo.get', { name: 'Eldoria' });
        assert.ok(check.data.entries[r.uid]);
        return { uid: r.uid };
    });

    await step('worldinfo.deleteEntry', async () => {
        const r = await h.call('worldinfo.deleteEntry', { book: 'Eldoria', uid: 0 });
        return { deleted: r.deleted };
    });

    await step('preset.list', async () => {
        const r = await h.call('preset.list');
        return { presets: r.presets.map((p) => p.name), current: r.current };
    });

    await step('preset.apply', async () => {
        return await h.call('preset.apply', { name: 'Default' });
    });

    await step('prompt.list', async () => {
        const r = await h.call('prompt.list');
        assert.ok(r.prompts.length > 0);
        return { count: r.prompts.length, first: r.prompts[0] };
    });

    await step('prompt.toggle', async () => {
        const r = await h.call('prompt.list');
        const target = r.prompts.find((p) => !p.marker) ?? r.prompts[0];
        const out = await h.call('prompt.toggle', { identifier: target.identifier, enabled: false });
        const after = await h.call('prompt.list');
        const changed = after.prompts.find((p) => p.identifier === target.identifier);
        assert.equal(out.enabled, false);
        return { id: target.identifier, enabledAfter: changed?.enabled };
    });

    await step('settings.snapshot', async () => {
        const r = await h.call('settings.snapshot');
        return { source: r.source, model: r.customModel, presets: r.presetNames.length, world: r.worldNames.length };
    });

    await step('persona.list', async () => {
        const r = await h.call('persona.list');
        return { count: r.personas.length };
    });

    await step('character.delete', async () => {
        const r = await h.call('character.delete', { avatar: 'TestCard.png', deleteChats: true });
        return r;
    });
} catch (error) {
    process.exitCode = 1;
    console.log('--- engine log ---');
    console.log(h.log().split('\n').filter((line) => /\[library\]|Error|error/.test(line)).slice(-15).join('\n'));
} finally {
    await model.close();
    await h.shutdown();
}
