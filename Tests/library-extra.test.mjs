// Extra coverage for operations the native UI exposes that the main library
// test does not touch: card import, avatar replacement, chat rename and world
// book activation.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { startMockModel } from './support/mock-model.mjs';
import { installResolversAndBoot } from './support/engine-harness.mjs';

const model = await startMockModel();
const harness = await installResolversAndBoot();
const call = (method, args = {}) => harness.call(method, args);

try {
    const card = await readFile(new URL('../Engine/core/default/content/default_Seraphina.png', import.meta.url));
    const imported = await call('character.import', {
        fileName: 'ImportedSeraphina.png',
        data: card.toString('base64'),
    });
    assert.ok(imported.fileName.endsWith('.png'));
    console.log('ok import', imported.fileName);

    const list = await call('character.list');
    const avatar = list.characters.find((item) => item.avatar === imported.fileName)?.avatar;
    assert.ok(avatar, 'imported card is listed');
    console.log('ok listed', avatar);

    const avatarPng = await readFile(new URL('../Engine/default-avatar.png', import.meta.url));
    const replaced = await call('character.setAvatar', {
        avatar,
        fileName: 'replaced.png',
        data: avatarPng.toString('base64'),
    });
    assert.equal(replaced.avatar, avatar);
    console.log('ok avatar');

    const activated = await call('worldinfo.activate', { names: ['Eldoria'] });
    assert.deepEqual(activated.active, ['Eldoria']);
    const summary = await call('worldinfo.summary');
    assert.equal(summary.books.find((book) => book.name === 'Eldoria').active, true);
    console.log('ok worldinfo actives');

    await call('chat.new', { avatar });
    const chats = await call('chat.list', { avatar });
    assert.ok(chats.chats.length >= 1);
    const first = chats.chats[0];
    const renamed = await call('chat.rename', {
        avatar,
        fileName: first.fileName,
        newName: 'Renamed Chat',
    });
    assert.equal(renamed.fileName, 'Renamed Chat');
    const after = await call('chat.list', { avatar });
    assert.ok(after.chats.some((chat) => chat.fileName === 'Renamed Chat.jsonl'));
    console.log('ok chat rename');

    const snapshot = await call('settings.snapshot');
    assert.ok(typeof snapshot.currentModel === 'string');
    assert.ok(Array.isArray(snapshot.presetNames));
    console.log('ok snapshot', snapshot.source, snapshot.currentModel);

    // Group chats go through upstream's own generator, so it needs a provider.
    await call('settings.update', {
        patch: {
            chat_completion_source: 'custom',
            custom_url: model.url,
            custom_model: 'mock-model',
            openai_max_context: 8192,
            openai_max_tokens: 300,
            stream_openai: false,
        },
    });
    const group = await call('group.create', { name: 'Test Group', members: [avatar] });
    assert.ok(group.group.id);
    const groupList = await call('group.list');
    assert.ok(groupList.groups.some((item) => item.id === group.group.id));
    console.log('ok group create');

    const opened = await call('group.open', { id: group.group.id });
    assert.equal(opened.groupId, group.group.id);

    const sent = await call('group.send', { text: 'hello group' });
    assert.equal(sent.error, null);
    assert.ok(sent.messages.length >= 2);
    console.log('ok group send', sent.messages.length, 'messages');

    const edited = await call('group.message.edit', { id: sent.messages.length - 1, text: 'EDITED' });
    assert.equal(edited.messages.at(-1).text, 'EDITED');
    const removed = await call('group.message.delete', { id: edited.messages.length - 1 });
    assert.equal(removed.messages.length, edited.messages.length - 1);
    console.log('ok group message edit/delete');

    const groupChats = await call('group.chats', { id: group.group.id });
    assert.ok(groupChats.chats.length >= 1);
    console.log('ok group chats');
    const newChat = await call('group.chat.new', { id: group.group.id });
    console.log('  new chat id:', JSON.stringify(newChat.chatId), 'file:', JSON.stringify(newChat.fileName));

    const deleted = await call('group.delete', { id: group.group.id });
    console.log('  delete result:', JSON.stringify(deleted));
    const afterDelete = await call('group.list');
    console.log('  groups now:', JSON.stringify(afterDelete.groups.map((item) => item.id)));
    assert.ok(!afterDelete.groups.some((item) => item.id === group.group.id));
    console.log('ok group delete');

    const persona = await call('persona.upload', {
        fileName: 'Tester.png',
        name: 'Tester',
        data: avatarPng.toString('base64'),
    });
    const personas = await call('persona.list');
    assert.ok(personas.personas.some((item) => item.name === 'Tester'));
    console.log('ok persona upload');

    const selected = await call('persona.select', { avatar: persona.avatar });
    assert.equal(selected.name, 'Tester');
    console.log('ok persona select');

    // Presets of every kind the tavern keeps, plus the extension list.
    const kinds = await call('preset.kinds');
    assert.ok(kinds.kinds.find((entry) => entry.kind === 'context').names.length > 5);
    const detail = await call('preset.detail', { kind: 'context', name: 'ChatML' });
    assert.ok(detail.preset.story_string);
    assert.ok(detail.preset.story_string.includes('{{#if system}}'), 'the template is the real one');
    console.log('ok presets', kinds.kinds.length, 'kinds');

    const extensions = await call('extension.list');
    assert.ok(extensions.extensions.some((item) => item.name === 'regex'), 'the bundled Regex extension is listed');
    console.log('ok extensions', extensions.extensions.length);

    // Settings screens: appearance, general, backgrounds, test message.
    const look = await call('appearance.get');
    assert.equal(typeof look.fontScale, 'number');
    const general = await call('general.get');
    assert.equal(typeof general.swipes, 'boolean');
    const backgrounds = await call('background.list');
    assert.ok(Array.isArray(backgrounds.backgrounds));
    const probe = await call('settings.testMessage', { text: 'connection probe' });
    assert.equal(probe.error, null, 'the test message reaches the model');
    const afterProbe = await call('chat.messages');
    console.log('ok settings screens', 'messages after probe:', afterProbe.messages.length);

    // Importing a preset file: plain, and the full export with prompts.
    const presetFile = JSON.stringify({
        name: 'Imported Preset',
        temperature: 0.75,
        openai_max_tokens: 512,
        prompts: [
            { identifier: 'main', name: 'Main Prompt', system_prompt: true, role: 'system', content: 'IMPORTED', marker: false },
        ],
        prompt_order: [{ character_id: 100001, order: [{ identifier: 'main', enabled: true }] }],
    });
    const importedPreset = await call('preset.import', { kind: 'openai', data: presetFile });
    assert.equal(importedPreset.name, 'Imported Preset');
    assert.equal(importedPreset.prompts, 1);
    const afterImport = await call('preset.kinds');
    assert.ok(afterImport.kinds.find((k) => k.kind === 'openai').names.includes('Imported Preset'));
    const importedDetail = await call('preset.detail', { kind: 'openai', name: 'Imported Preset' });
    assert.equal(importedDetail.preset.temperature, 0.75);
    console.log('ok preset import');

    const tokenInfo = await call('chat.tokens');
    assert.ok(tokenInfo.tokens > 0, 'token count is reported for the open chat');
    console.log('ok chat tokens', tokenInfo.tokens);

    // Appearance round trip: reading preferences persist with the tavern settings.
    await call('appearance.save', { style: 'hush', accent: 'teal', bodySize: 18, lineWidth: 640, messageInfo: 'always' });
    const styled = await call('appearance.get');
    assert.equal(styled.style, 'hush');
    assert.equal(styled.accent, 'teal');
    assert.equal(styled.bodySize, 18);
    console.log('ok appearance');

    await call('worldinfo.deactivateAll');
    console.log('all extra checks passed');
} catch (error) {
    process.exitCode = 1;
    console.log('FAIL', error.message);
    console.log(harness.log().split('\n').filter((line) => /\[library\]|Error|error/.test(line)).slice(-12).join('\n'));
} finally {
    await model.close();
    await harness.shutdown();
}
