import test from 'node:test';
import assert from 'node:assert/strict';
import { watchFile, unwatchFile } from 'node:fs';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const entry = fileURLToPath(new URL('../Engine/boot.mjs', import.meta.url));

test('boot publishes a private endpoint for this launch and serves real local RPC', async t => {
    const directory = await mkdtemp(path.join(os.tmpdir(), 'native-tavern-'));
    const launchID = randomUUID();
    const endpointFile = path.join(directory, 'endpoint.json');
    const ready = new Promise((resolve, reject) => {
        // Like the Swift host, inspect readiness by file state, not filesystem notification delivery.
        watchFile(endpointFile, { interval: 25 }, current => {
            if (current.size > 0) readFile(endpointFile, 'utf8').then(resolve, reject);
        });
    });
    const child = spawn(process.execPath, [entry, directory, launchID], { stdio: ['ignore', 'pipe', 'pipe'], env: {} });
    const exited = once(child, 'exit');
    t.after(async () => {
        unwatchFile(endpointFile);
        if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
        await exited;
        await rm(directory, { recursive: true, force: true });
    });
    let timer;
    const timedOut = new Promise((resolve, reject) => {
        timer = setTimeout(() => reject(new Error('Embedded host did not publish readiness.')), 10_000);
    });
    let text;
    try {
        text = await Promise.race([ready, timedOut, exited.then(() => { throw new Error('Embedded host exited before readiness.'); })]);
    } finally { clearTimeout(timer); }
    const endpoint = JSON.parse(text);
    assert.equal(endpoint.launchID, launchID);
    assert.equal(endpoint.protocolVersion, 1);
    assert.equal((await stat(path.join(directory, 'endpoint.json'))).mode & 0o777, 0o600);
    const response = await fetch(`${endpoint.url}/rpc`, {
        method: 'POST',
        headers: { authorization: `Bearer ${endpoint.token}`, 'content-type': 'application/json' },
        body: JSON.stringify({ id: 'boot-test', method: 'engine.status' }),
    });
    assert.equal(response.status, 200);
    const reply = await response.json();
    assert.equal(reply.id, 'boot-test');
    assert.equal(reply.result.transportReady, true);
    assert.equal(reply.result.sillyTavernCoreReady, false);
});
