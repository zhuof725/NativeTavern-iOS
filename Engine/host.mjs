// Loopback-only, token-gated gateway in front of the upstream SillyTavern server.
//
// Two jobs:
//  1. The SwiftUI app only ever talks to 127.0.0.1 on a per-launch token.
//  2. It brokers the upstream session (cookie + CSRF) so the app doesn't have to
//     reimplement SillyTavern's CSRF handshake, while still letting upstream own
//     every endpoint, header, and payload format.
//
// A browser cannot send that Bearer header, so the system-browser host gets in
// through `/shell`: a tiny entry document whose one-time token is traded for an
// HttpOnly cookie scoped to this gateway. Everything else is unchanged.
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
 * @param {() => Promise<string>} [options.shellPage] entry document source
 */
export async function startLocalHost({ launchID, upstream, shellPage = null, waitForUpstream = async () => {} }) {
    let engine = null;
    // Answers that must work before the core has finished loading.
    let early = null;
    if (typeof launchID !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(launchID)) {
        throw new HostError('INVALID_LAUNCH', 'A per-launch UUID is required.');
    }
    if (typeof upstream !== 'string' || !/^http:\/\/127\.0\.0\.1:\d+$/.test(upstream)) {
        throw new HostError('INVALID_UPSTREAM', 'Upstream must be a loopback HTTP origin.');
    }

    const token = randomBytes(32).toString('hex');
    const expected = Buffer.from(`Bearer ${token}`);
    // Cookie value the browser gets: derived, not the raw token, so a leaked
    // cookie cannot be replayed as an Authorization header.
    const cookieValue = `nt_${token.slice(0, 32)}`;
    const session = new UpstreamSession(upstream);

    const server = http.createServer((request, response) => {
        handle(request, response, { expected, cookieValue, session, getEngine: () => engine, getEarly: () => early, shellPage, waitForUpstream })
            .catch((error) => {
                if (!(error instanceof HostError)) {
                    console.log('[host] request failed:', error?.stack ?? error,
                        '| cause:', error?.cause?.code ?? error?.cause?.message ?? 'none');
                }
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
        session,
        token,
        attachEngine(api) {
            engine = api;
            // The early surface serves the browser session; once the core is up
            // it is merged with the full API.
            if (api) api.consumeBrowseToken = early?.consumeBrowseToken?.bind(early);
            if (api && early) api.early = early;
        },
        attachEarly(api) { early = api; },
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

function surface(engine, early) {
    if (!early) return engine;
    if (!engine) return early;
    // Browser tokens live on the early surface; everything else on the core's.
    if (engine.consumeBrowseToken) return engine;
    return {
        methods: [...new Set([...early.methods, ...engine.methods])],
        consumeBrowseToken: (value) => early.consumeBrowseToken(value),
        call(name, args) {
            if (early.methods.includes(name)) return early.call(name, args);
            return engine.call(name, args);
        },
    };
}

function isAuthorized(request, expected, cookieValue) {
    const cookie = parseCookies(request.headers.cookie);
    if (cookie.nt_session && cookie.nt_session === cookieValue) return true;
    const authorization = Buffer.from(request.headers.authorization || '');
    return authorization.length === expected.length && timingSafeEqual(authorization, expected);
}

function parseCookies(header) {
    const jar = {};
    if (!header) return jar;
    for (const part of String(header).split(';')) {
        const index = part.indexOf('=');
        if (index > 0) jar[part.slice(0, index).trim()] = part.slice(index + 1).trim();
    }
    return jar;
}

function sendShellPage(response, html) {
    response.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
        'content-security-policy': "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'",
    });
    response.end(html);
}

async function handle(request, response, { expected, cookieValue, session, getEngine, getEarly, shellPage, waitForUpstream }) {
    const engine = surface(getEngine(), getEarly?.());
    if (request.headers.origin) {
        throw new HostError('ORIGIN_DENIED', 'Browser origins are not accepted.', 403);
    }

    const url = new URL(request.url, 'http://127.0.0.1');

    // Browser entry document. It is public (no secret in it): the one-time token
    // travels in the fragment, which a server never receives.
    if (url.pathname === '/shell') {
        if (!shellPage) throw new HostError('NOT_FOUND', 'Unknown endpoint.', 404);
        return sendShellPage(response, await shellPage());
    }

    // The hop from the entry document: trade the token for the cookie. The query
    // value has already been consumed once, so a replay is rejected.
    if (url.pathname === '/' && url.searchParams.has('nt_session')) {
        const browse = String(url.searchParams.get('nt_session'));
        if (!engine?.consumeBrowseToken?.(browse)) {
            throw new HostError('UNAUTHORIZED', 'A valid browse token is required.', 401);
        }
        response.writeHead(302, {
            location: '/',
            'set-cookie': `nt_session=${cookieValue}; Path=/; HttpOnly; SameSite=Lax`,
            'cache-control': 'no-store',
        });
        response.end();
        return;
    }

    if (!isAuthorized(request, expected, cookieValue)) {
        throw new HostError('UNAUTHORIZED', 'A valid per-launch token is required.', 401);
    }

    if (url.pathname === '/engine/status') {
        return json(response, 200, {
            protocolVersion: PROTOCOL_VERSION,
            runtime: process.version,
            transportReady: true,
            sillyTavernCoreReady: await session.ready(),
            upstream: session.origin,
            capabilities: engine ? engine.methods : ['engine.status'],
        });
    }
    if (url.pathname === '/engine/rpc') {
        return rpc(request, response, engine);
    }
    if (url.pathname === '/') {
        // The interface itself: pass through to the vendored server, which
        // serves index.html from the bundle.
        await waitForUpstream();
        const upstreamResponse = await session.request('GET', '/', {});
        response.writeHead(upstreamResponse.status, upstreamResponse.headers);
        if (upstreamResponse.body) response.end(upstreamResponse.body);
        else response.end();
        return;
    }
    if (!url.pathname.startsWith('/st/') && !isAssetPath(url.pathname)) {
        throw new HostError('NOT_FOUND', 'Unknown endpoint.', 404);
    }

    // /st/<upstream path> — pass through to the real SillyTavern server.
    // The gateway answers before the vendored server has finished its first
    // copy of content, so a pass-through call waits for it instead of racing.
    await waitForUpstream();
    const upstreamPath = (url.pathname.startsWith('/st/') ? url.pathname.slice('/st'.length) : url.pathname) + url.search;
    const body = await readBody(request);
    const upstreamResponse = await session.request(request.method, upstreamPath, {
        headers: pickHeaders(request.headers),
        body,
    });

    response.writeHead(upstreamResponse.status, upstreamResponse.headers);
    if (upstreamResponse.body) response.end(upstreamResponse.body);
    else response.end();
}

/**
 * Paths the interface requests directly at the origin: modules, styles, fonts,
 * images, data files. They are forwarded verbatim, so the page sees exactly the
 * paths the vendored server documents.
 */
function isAssetPath(pathname) {
    return /^\/(scripts|css|img|fonts|webfonts|lib|vendor|locales|characters|backgrounds|User%20Avatars|User Avatars|assets|user|thumbnails|api)\b/.test(pathname);
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
            if (!['content-encoding', 'content-length', 'transfer-encoding', 'connection',
                'set-cookie', 'x-frame-options', 'content-security-policy'].includes(key)) {
                responseHeaders[key] = value;
            }
        });
        const buffer = Buffer.from(await response.arrayBuffer());
        return { status: response.status, headers: responseHeaders, body: buffer };
    }
}
