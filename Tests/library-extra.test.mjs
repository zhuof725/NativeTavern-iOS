// Extra coverage for operations the native UI exposes that the main library
// test does not touch: card import, avatar replacement, chat rename and world
// book activation.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { installResolversAndBoot } from './support/engine-harness.mjs';

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

    await call('worldinfo.deactivateAll');
    console.log('all extra checks passed');
} catch (error) {
    process.exitCode = 1;
    console.log('FAIL', error.message);
    console.log(harness.log().split('\n').filter((line) => /\[library\]|Error|error/.test(line)).slice(-12).join('\n'));
} finally {
    await harness.shutdown();
}
