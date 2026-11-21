import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { startLocalHost } from '../Engine/host.mjs';

async function running(t) {
    const host = await startLocalHost({ launchID: randomUUID() });
    t.after(() => host.close());
    return host;
}
function rpc(host, options = {}) {
    const { headers = {}, body = JSON.stringify({ id: 'test-call', method: 'engine.status', args: {} }), ...rest } = options;
    return fetch(`${host.endpoint.url}/rpc`, {
        method: 'POST',
        headers: { authorization: `Bearer ${host.endpoint.token}`, 'content-type': 'application/json', ...headers },
        body,
        ...rest,
    });
}

test('the embedded transport binds only IPv4 loopback on an assigned port', async t => {
    const host = await running(t);
    assert.equal(host.address.address, '127.0.0.1');
    assert.ok(host.address.port > 0);
    assert.equal(new URL(host.endpoint.url).hostname, '127.0.0.1');
    assert.match(host.endpoint.token, /^[a-f0-9]{64}$/);
});

test('status reports transport readiness without claiming a working SillyTavern core', async t => {
    const host = await running(t);
    const response = await rpc(host);
    assert.equal(response.status, 200);
    const message = await response.json();
    assert.equal(message.id, 'test-call');
    assert.equal(message.result.protocolVersion, 1);
    assert.equal(message.result.transportReady, true);
    assert.equal(message.result.sillyTavernCoreReady, false);
    assert.deepEqual(message.result.capabilities, ['engine.status']);
});

test('missing and incorrect bearer tokens cannot call the embedded host', async t => {
    const host = await running(t);
    for (const authorization of ['', `Bearer ${'0'.repeat(64)}`]) {
        const response = await rpc(host, { headers: { authorization } });
        assert.equal(response.status, 401);
        assert.equal((await response.json()).error.code, 'UNAUTHORIZED');
    }
});

test('browser-origin requests are rejected even if they carry a token', async t => {
    const host = await running(t);
    const response = await rpc(host, { headers: { origin: 'https://example.com' } });
    assert.equal(response.status, 403);
    assert.equal(response.headers.get('access-control-allow-origin'), null);
});

test('unintegrated chat methods return an explicit error rather than a simulated reply', async t => {
    const host = await running(t);
    const response = await rpc(host, { body: JSON.stringify({ id: 'chat-call', method: 'chat.generate', args: { text: 'Hello' } }) });
    assert.equal(response.status, 501);
    const message = await response.json();
    assert.equal(message.id, 'chat-call');
    assert.equal(message.error.code, 'METHOD_NOT_IMPLEMENTED');
    assert.equal(message.result, undefined);
});

test('malformed JSON and invalid request shapes fail at the protocol boundary', async t => {
    const host = await running(t);
    for (const body of ['{', '[]', 'null', '{}', '{"id":"a","method":"engine.status","args":[]}']) {
        assert.equal((await rpc(host, { body })).status, 400);
    }
});

test('oversized bodies and non-JSON content are rejected', async t => {
    const host = await running(t);
    assert.equal((await rpc(host, { body: JSON.stringify({ text: 'x'.repeat(70 * 1024) }) })).status, 413);
    assert.equal((await rpc(host, { headers: { 'content-type': 'text/plain' } })).status, 415);
});

test('RPC does not accept GET requests', async t => {
    const host = await running(t);
    const response = await fetch(`${host.endpoint.url}/rpc`, { headers: { authorization: `Bearer ${host.endpoint.token}` } });
    assert.equal(response.status, 405);
});

test('a later host does not accept a previous launch token', async t => {
    const first = await startLocalHost({ launchID: randomUUID() });
    const oldToken = first.endpoint.token;
    await first.close();
    const next = await running(t);
    assert.notEqual(next.endpoint.token, oldToken);
    assert.equal((await rpc(next, { headers: { authorization: `Bearer ${oldToken}` } })).status, 401);
});

test('invalid launch identity is rejected before a socket is opened', async () => {
    for (const launchID of [undefined, '', 'not-a-uuid']) {
        await assert.rejects(startLocalHost({ launchID }), /per-launch UUID/);
    }
});
