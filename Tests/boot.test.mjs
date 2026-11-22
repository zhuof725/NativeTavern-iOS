import test from 'node:test';
import assert from 'node:assert/strict';
import { watchFile, unwatchFile } from 'node:fs';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const entry = fileURLToPath(new URL('../Engine/boot.mjs', import.meta.url));

// Boots the real engine: upstream SillyTavern server plus the original frontend
// core. It is slow by nature (upstream copies content and starts Express), so
// this test gets a generous timeout and is the only one that spawns a process.
test('boot serves the upstream core through the launch-token transport', { timeout: 300000 }, async t => {
    const directory = await mkdtemp(path.join(os.tmpdir(), 'native-tavern-'));
    const launchID = randomUUID();
    const endpointFile = path.join(directory, 'endpoint.json');

    const ready = new Promise((resolve, reject) => {
        // The Swift host also observes readiness by file state, not filesystem
        // notifications, because delivery is not reliable in its runtime.
        watchFile(endpointFile, { interval: 250 }, (current) => {
            if (current.size > 0) readFile(endpointFile, 'utf8').then(resolve, reject);
        });
    });

    const child = spawn(process.execPath, [entry, directory, launchID], {
        stdio: ['ignore', 'pipe', 'pipe'],
        env: {},
    });
    let output = '';
    child.stdout.on('data', (chunk) => { output += chunk; });
    child.stderr.on('data', (chunk) => { output += chunk; });
    const exited = once(child, 'exit');

    t.after(async () => {
        unwatchFile(endpointFile);
        if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
        await exited;
        await rm(directory, { recursive: true, force: true });
    });

    const endpoint = JSON.parse(await ready);
    assert.equal(endpoint.launchID, launchID);
    assert.match(endpoint.token, /^[a-f0-9]{64}$/);

    const rpc = async (method, args = {}) => {
        const response = await fetch(`${endpoint.url}/engine/rpc`, {
            method: 'POST',
            headers: { authorization: `Bearer ${endpoint.token}`, 'content-type': 'application/json' },
            body: JSON.stringify({ id: randomUUID(), method, args }),
        });
        return response.json();
    };

    // The upstream server answers through the gateway before the frontend core
    // has finished loading (it is started lazily).
    const status = await (await fetch(`${endpoint.url}/engine/status`, {
        headers: { authorization: `Bearer ${endpoint.token}` },
    })).json();
    assert.equal(status.protocolVersion, 2);
    assert.equal(status.transportReady, true);

    // Real world-info write, activation, scan and prompt assembly, all executed
    // by upstream's own modules.
    assert.deepEqual(await rpc('character.setName', { name: 'Seraphina' }).then(r => r.result), { name: 'Seraphina' });

    const macro = await rpc('macro.substitute', { content: '{{user}} meets {{char}}' });
    assert.equal(macro.result.result, 'User meets Seraphina');

    const created = await rpc('worldinfo.create', {
        name: 'BootSmoke',
        entries: {
            0: {
                uid: 0, key: ['dragon'], keysecondary: [], comment: 'boot smoke',
                content: 'BOOT_WI: dragons guard the pass.', constant: false, selective: false,
                selectiveLogic: 0, order: 100, position: 0, disable: false, excludeRecursion: false,
                probability: 100, useProbability: true, depth: 4, group: '', role: null,
                vectorized: false, useRegex: false,
            },
        },
    });
    assert.equal(created.result.name, 'BootSmoke');

    const activated = await rpc('worldinfo.activate', { names: ['BootSmoke'] });
    assert.deepEqual(activated.result.active, ['BootSmoke']);

    // The prompt is built from the chat the core has open, so the chat is loaded
    // first — the same order the app uses.
    const loaded = await rpc('chat.load', {
        messages: [{ name: 'User', is_user: true, mes: 'We saw a dragon on the pass.' }],
    });
    assert.equal(loaded.result.length, 1);
    assert.equal(loaded.result.firstMessage, 'We saw a dragon on the pass.');

    const statusAfterLoad = await rpc('engine.status', {});
    // The engine's own log is the only place a silent prompt-assembly failure shows up.
    const built = await rpc('prompt.build', {
        character: {
            name: 'Seraphina',
            description: 'A calm ranger with a scarred bow.',
            personality: 'Watchful.',
            scenario: 'A cold road at dusk.',
        },
        maxContext: 8192,
    });

    assert.ok(Array.isArray(built.result.prompt));
    const promptText = JSON.stringify(built.result.prompt);
    assert.match(promptText, /BOOT_WI/, 'the activated world info entry must reach the prompt');
    assert.match(promptText, /calm ranger/, 'the character description must reach the prompt');
    assert.ok(built.result.prompt.some(m => m.role === 'user'),
        `a user role must be present; saw ${JSON.stringify(built.result)}`);
    assert.match(promptText, /dragon on the pass/, 'the user turn must reach the prompt');

    // The transport must still refuse unauthenticated callers.
    const denied = await fetch(`${endpoint.url}/engine/rpc`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ id: 'x', method: 'engine.status' }),
    });
    assert.equal(denied.status, 401);
});
