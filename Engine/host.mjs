// Loopback-only, token-gated gateway in front of the upstream SillyTavern server.
//
// Two jobs:
//  1. The SwiftUI app only ever talks to 127.0.0.1 on a per-launch token.
//  2. It brokers the upstream session (cookie + CSRF) so the app doesn't have to
//     reimplement SillyTavern's CSRF handshake, while still letting upstream own
//     every endpoint, header, and payload format.
import http from 'node:http';
import { randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';

export const PROTOCOL_VERSION = 2;
const BODY_LIMIT = 32 * 1024 * 1024;

class HostError extends Error {
    constructor(code, message, status = 400) {
        super(message);
        this.code = code;
        this.status = status;
    }
}

/**
 * @param {object} options
 * @param {string} options.launchID per-launch UUID supplied by the app
 * @param {string} options.upstream base URL of the upstream SillyTavern server
 */
export async function startLocalHost({ launchID, upstream }) {
    // The engine API is attached after listen: it depends on this host's session.
    let engine = null;
    if (typeof launchID !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(launchID)) {
        throw new HostError('INVALID_LAUNCH', 'A per-launch UUID is required.');
    }
    if (typeof upstream !== 'string' || !/^http:\/\/127\.0\.0\.1:\d+$/.test(upstream)) {
        throw new HostError('INVALID_UPSTREAM', 'Upstream must be a loopback HTTP origin.');
    }

    const token = randomBytes(32).toString('hex');
    const expected = Buffer.from(`Bearer ${token}`);
    const session = new UpstreamSession(upstream);

    const server = http.createServer((request, response) => {
        handle(request, response, { expected, session, getEngine: () => engine }).catch((error) => {
            const known = error instanceof HostError;
            if (!response.headersSent) {
                response.writeHead(known ? error.status : 500, { 'content-type': 'application/json; charset=utf-8' });
            }
            response.end(JSON.stringify({
                error: {
                    code: known ? error.code : 'INTERNAL_ERROR',
                    message: known ? error.message : 'Local engine request failed.',
                },
            }));
        });
    });
    server.requestTimeout = 0;
    server.headersTimeout = 30000;
    await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen({ host: '127.0.0.1', port: 0, exclusive: true }, () => {
            server.off('error', reject);
            resolve();
        });
    });
    const address = server.address();
    return {
        // Exposed so the engine API can call the vendored server with the same
        // session and CSRF handling the transport uses.
        session,
        attachEngine(api) { engine = api; },
        endpoint: {
            protocolVersion: PROTOCOL_VERSION,
            launchID,
            url: `http://127.0.0.1:${address.port}`,
            token,
        },
        address,
        async close() {
            server.closeIdleConnections();
            await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
        },
    };
}

async function handle(request, response, { expected, session, getEngine }) {
    const engine = getEngine();
    if (request.headers.origin) {
        throw new HostError('ORIGIN_DENIED', 'Browser origins are not accepted.', 403);
    }
    const authorization = Buffer.from(request.headers.authorization || '');
    if (authorization.length !== expected.length || !timingSafeEqual(authorization, expected)) {
        throw new HostError('UNAUTHORIZED', 'A valid per-launch token is required.', 401);
    }

    const url = new URL(request.url, 'http://127.0.0.1');
    if (url.pathname === '/engine/status') {
        return json(response, 200, {
            protocolVersion: PROTOCOL_VERSION,
            runtime: process.version,
            transportReady: true,
            // The upstream core is what the transport talks to; it is running.
            sillyTavernCoreReady: await session.ready(),
            upstream: session.origin,
            capabilities: engine ? engine.methods : ['engine.status'],
        });
    }
    if (url.pathname === '/engine/rpc') {
        return rpc(request, response, engine);
    }
    if (!url.pathname.startsWith('/st/')) {
        throw new HostError('NOT_FOUND', 'Unknown endpoint.', 404);
    }

    // /st/<upstream path> — pass through to the real SillyTavern server.
    const upstreamPath = url.pathname.slice('/st'.length) + url.search;
    const body = await readBody(request);
    const upstreamResponse = await session.request(request.method, upstreamPath, {
        headers: pickHeaders(request.headers),
        body,
    });

    response.writeHead(upstreamResponse.status, upstreamResponse.headers);
    if (upstreamResponse.body) response.end(upstreamResponse.body);
    else response.end();
}

function pickHeaders(headers) {
    const allow = ['content-type', 'accept', 'x-csrf-token', 'range', 'if-none-match'];
    const picked = {};
    for (const name of allow) {
        if (headers[name]) picked[name] = headers[name];
    }
    return picked;
}

async function readBody(request) {
    const chunks = [];
    let length = 0;
    for await (const chunk of request) {
        length += chunk.length;
        if (length > BODY_LIMIT) throw new HostError('BODY_TOO_LARGE', 'Request is too large.', 413);
        chunks.push(chunk);
    }
    return chunks.length ? Buffer.concat(chunks) : null;
}

function json(response, status, body) {
    response.writeHead(status, {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
        'x-content-type-options': 'nosniff',
    });
    response.end(JSON.stringify(body));
}

/** JSON-RPC-shaped call into the upstream-backed engine API. */
async function rpc(request, response, engine) {
    if (request.method !== 'POST') throw new HostError('METHOD_NOT_ALLOWED', 'Use POST.', 405);
    if (!engine) throw new HostError('CORE_UNAVAILABLE', 'The engine API is not ready.', 503);

    const body = await readBody(request);
    let message;
    try {
        message = JSON.parse(body ? body.toString('utf8') : '{}');
    } catch {
        throw new HostError('INVALID_JSON', 'Request must be valid JSON.');
    }
    if (!message || typeof message.method !== 'string') {
        throw new HostError('INVALID_REQUEST', 'Expected { id, method, args }.');
    }

    try {
        const result = await engine.call(message.method, message.args ?? {});
        return json(response, 200, { id: message.id ?? null, result });
    } catch (error) {
        const known = typeof error?.status === 'number';
        if (!known) {
            // Unexpected failures are logged with their stack so they can be
            // diagnosed; the client only gets a generic message.
            console.log(`[engine] ${message.method} failed:`, error?.stack ?? error);
        }
        return json(response, known ? error.status : 500, {
            id: message.id ?? null,
            error: {
                code: known ? error.code : 'INTERNAL_ERROR',
                message: known ? error.message : 'Engine call failed.',
            },
        });
    }
}

/** Keeps the upstream CSRF token and session cookie, refreshing them when needed. */
class UpstreamSession {
    origin;
    cookies = new Map();
    csrf = null;

    constructor(origin) {
        this.origin = origin;
    }

    async ready() {
        try {
            await this.ensureCsrf();
            return true;
        } catch {
            return false;
        }
    }

    async ensureCsrf() {
        if (this.csrf) return this.csrf;
        const response = await fetch(`${this.origin}/csrf-token`, { signal: AbortSignal.timeout(15000) });
        if (!response.ok) throw new HostError('UPSTREAM_NOT_READY', 'The local core is not answering yet.', 503);
        this.absorbCookies(response);
        const data = await response.json();
        this.csrf = data.token;
        return this.csrf;
    }

    absorbCookies(response) {
        for (const raw of response.headers.getSetCookie?.() ?? []) {
            const [pair] = raw.split(';');
            const index = pair.indexOf('=');
            if (index > 0) this.cookies.set(pair.slice(0, index).trim(), pair.slice(index + 1).trim());
        }
    }

    async request(method, path, { headers, body } = {}) {
        const send = async () => {
            const csrf = await this.ensureCsrf();
            const outgoing = { ...headers };
            outgoing['x-csrf-token'] = csrf;
            if (this.cookies.size) {
                outgoing.cookie = [...this.cookies].map(([k, v]) => `${k}=${v}`).join('; ');
            }
            return fetch(`${this.origin}${path}`, {
                method,
                headers: outgoing,
                body: method === 'GET' || method === 'HEAD' ? undefined : body,
                redirect: 'manual',
                signal: AbortSignal.timeout(180000),
            });
        };

        let response = await send();
        if (response.status === 403) {
            // Stale CSRF token or expired session: refresh once, then retry.
            this.csrf = null;
            this.cookies.clear();
            response = await send();
        }
        this.absorbCookies(response);

        const responseHeaders = {};
        response.headers.forEach((value, key) => {
            if (!['content-encoding', 'content-length', 'transfer-encoding', 'connection'].includes(key)) {
                responseHeaders[key] = value;
            }
        });
        const buffer = Buffer.from(await response.arrayBuffer());
        return { status: response.status, headers: responseHeaders, body: buffer };
    }
}
