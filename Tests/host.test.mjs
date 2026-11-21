import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { startLocalHost } from '../Engine/host.mjs';

// A stub engine stands in for the upstream core so the transport can be tested
// in isolation. The real core is covered by engine-core.test.mjs.
const stubEngine = {
    methods: ['engine.status', 'macro.substitute'],
    async call(method, args) {
        if (method === 'macro.substitute') return { result: `sub(${args.content})` };
        const error = new Error(`Unknown method: ${method}`);
        error.code = 'METHOD_NOT_IMPLEMENTED';
        error.status = 501;
        throw error;
    },
};

const UPSTREAM = 'http://127.0.0.1:9';

async function running(t) {
    const host = await startLocalHost({ launchID: randomUUID(), upstream: UPSTREAM, engine: stubEngine });
    t.after(() => host.close());
    return host;
}

const call = (host, body, headers = {}) => fetch(`${host.endpoint.url}/engine/rpc`, {
    method: 'POST',
    headers: { authorization: `Bearer ${host.endpoint.token}`, 'content-type': 'application/json', ...headers },
    body: JSON.stringify(body),
});

test('handshake publishes a loopback URL with a per-launch token', async t => {
    const host = await running(t);
    assert.equal(host.endpoint.protocolVersion, 2);
    assert.match(host.endpoint.url, /^http:\/\/127\.0\.0\.1:\d+$/);
    assert.match(host.endpoint.token, /^[a-f0-9]{64}$/);
});

test('status reports the core as not ready while upstream is unreachable', async t => {
    const host = await running(t);
    const response = await fetch(`${host.endpoint.url}/engine/status`, {
        headers: { authorization: `Bearer ${host.endpoint.token}` },
    });
    const body = await response.json();
    assert.equal(response.status, 200);
    assert.equal(body.sillyTavernCoreReady, false);
    assert.deepEqual(body.capabilities, stubEngine.methods);
});

test('requests without the launch token are rejected', async t => {
    const host = await running(t);
    const response = await fetch(`${host.endpoint.url}/engine/status`);
    assert.equal(response.status, 401);
    const wrong = await fetch(`${host.endpoint.url}/engine/status`, { headers: { authorization: 'Bearer nope' } });
    assert.equal(wrong.status, 401);
});

test('browser origins are refused', async t => {
    const host = await running(t);
    const response = await fetch(`${host.endpoint.url}/engine/status`, {
        headers: { authorization: `Bearer ${host.endpoint.token}`, origin: 'http://evil.example' },
    });
    assert.equal(response.status, 403);
});

test('RPC calls reach the engine and echo the request id', async t => {
    const host = await running(t);
    const response = await call(host, { id: 'abc', method: 'macro.substitute', args: { content: 'hi' } });
    const body = await response.json();
    assert.equal(response.status, 200);
    assert.equal(body.id, 'abc');
    assert.deepEqual(body.result, { result: 'sub(hi)' });
});

test('unknown methods are reported as not implemented', async t => {
    const host = await running(t);
    const response = await call(host, { id: 'x', method: 'does.not.exist' });
    const body = await response.json();
    assert.equal(response.status, 501);
    assert.equal(body.error.code, 'METHOD_NOT_IMPLEMENTED');
});

test('paths outside the engine surface are not proxied', async t => {
    const host = await running(t);
    const response = await fetch(`${host.endpoint.url}/api/settings/get`, {
        headers: { authorization: `Bearer ${host.endpoint.token}` },
    });
    assert.equal(response.status, 404);
});

test('upstream rest calls require the launch token too', async t => {
    const host = await running(t);
    const response = await fetch(`${host.endpoint.url}/st/api/settings/get`, { method: 'POST' });
    assert.equal(response.status, 401);
});
