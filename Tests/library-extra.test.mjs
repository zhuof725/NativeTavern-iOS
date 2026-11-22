// Extra coverage for operations the native UI exposes that the main library
// test does not touch: card import, avatar replacement, chat rename and world
// book activation.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { request } from 'node:http';
import { installResolversAndBoot } from './support/engine-harness.mjs';

const harness = await installResolversAndBoot();
const origin = new URL(harness.endpoint.url);
const requestToGateway = (path, onResponse) => {
    // `rejectUnauthorized` off is not needed for loopback, but fetch handlers
    // must consume the body or the socket stays half-open.
    return request({ host: origin.hostname, port: origin.port, path, method: 'GET', agent: false },
        (response) => {
            if (onResponse === undefined) { response.resume(); return; }
            onResponse(response);
        });
};
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

    // The browser session: entry document → one-time token → cookie → interface.
    const session = await call('webui.session');
    const fragment = new URLSearchParams(new URL(session.browserURL).hash.slice(1));

    const status = await new Promise((resolve, reject) => {
        const request = requestToGateway(`/?nt_session=${fragment.get('token')}`, (response) => {
            response.resume();
            resolve({ status: response.statusCode, headers: response.headers });
        });
        request.on('error', reject);
        request.end();
    });
    assert.equal(status.status, 302);
    const cookie = (status.headers['set-cookie'] || [''])[0].split(';')[0];
    assert.match(cookie, /^nt_session=/);

    const shell = await new Promise((resolve, reject) => {
        const request = requestToGateway('/shell', (response) => {
            let text = '';
            response.setEncoding('utf8');
            response.on('data', (chunk) => { text += chunk; });
            response.on('end', () => resolve({ status: response.statusCode, text }));
        });
        request.on('error', reject);
        request.end();
    });
    assert.equal(shell.status, 200);
    assert.match(shell.text, /nt_session/);

    const settings = await harness.postCookie('/api/settings/get', {}, cookie);
    assert.ok(settings && typeof settings === 'object', 'the interface can read its settings');
    console.log('ok browser session');

    await call('worldinfo.deactivateAll');
    console.log('all extra checks passed');
} catch (error) {
    process.exitCode = 1;
    console.log('FAIL', error.message);
    console.log(harness.log().split('\n').filter((line) => /\[library\]|Error|error/.test(line)).slice(-12).join('\n'));
} finally {
    await harness.shutdown();
}
