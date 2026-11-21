import http from 'node:http';
import { randomBytes, timingSafeEqual } from 'node:crypto';

const BODY_LIMIT = 64 * 1024;
export const PROTOCOL_VERSION = 1;

class HostError extends Error {
    constructor(code, message, status = 400) {
        super(message);
        this.code = code;
        this.status = status;
    }
}

async function readMessage(request) {
    const chunks = [];
    let length = 0;
    for await (const chunk of request) {
        length += chunk.length;
        if (length <= BODY_LIMIT) chunks.push(chunk);
    }
    if (length > BODY_LIMIT) throw new HostError('BODY_TOO_LARGE', 'Request exceeds 64 KiB.', 413);
    let value;
    try {
        value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    } catch {
        throw new HostError('INVALID_JSON', 'Request must contain valid JSON.');
    }
    if (!value || Array.isArray(value) || typeof value !== 'object'
        || typeof value.id !== 'string' || !value.id || value.id.length > 128
        || typeof value.method !== 'string' || value.method.length > 128
        || (value.args !== undefined && (!value.args || Array.isArray(value.args) || typeof value.args !== 'object'))) {
        throw new HostError('INVALID_REQUEST', 'Expected { id, method, args?: object }.');
    }
    return value;
}

function reply(response, status, body) {
    response.writeHead(status, {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
        'x-content-type-options': 'nosniff',
    });
    response.end(JSON.stringify(body));
}

/** In-process transport host only. It does not pretend the SillyTavern core is integrated. */
export async function startLocalHost({ launchID }) {
    if (typeof launchID !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(launchID)) {
        throw new HostError('INVALID_LAUNCH', 'A per-launch UUID is required.');
    }
    const token = randomBytes(32).toString('hex');
    const expectedAuthorization = Buffer.from(`Bearer ${token}`);
    const server = http.createServer(async (request, response) => {
        let id = null;
        try {
            // The SwiftUI app speaks this API directly, not through browser pages.
            if (request.headers.origin) throw new HostError('ORIGIN_DENIED', 'Browser origins are not accepted.', 403);
            const authorization = Buffer.from(request.headers.authorization || '');
            if (authorization.length !== expectedAuthorization.length
                || !timingSafeEqual(authorization, expectedAuthorization)) {
                throw new HostError('UNAUTHORIZED', 'A valid per-launch token is required.', 401);
            }
            if (request.url !== '/rpc') throw new HostError('NOT_FOUND', 'Unknown endpoint.', 404);
            if (request.method !== 'POST') throw new HostError('METHOD_NOT_ALLOWED', 'Use POST.', 405);
            if (!/^application\/json(?:\s*;|$)/i.test(request.headers['content-type'] || '')) {
                throw new HostError('CONTENT_TYPE', 'Use application/json.', 415);
            }
            const declaredLength = Number(request.headers['content-length']);
            if (Number.isFinite(declaredLength) && declaredLength > BODY_LIMIT) {
                throw new HostError('BODY_TOO_LARGE', 'Request exceeds 64 KiB.', 413);
            }
            const message = await readMessage(request);
            id = message.id;
            if (message.method !== 'engine.status') {
                throw new HostError('METHOD_NOT_IMPLEMENTED', 'The SillyTavern adapter is not integrated yet.', 501);
            }
            reply(response, 200, {
                id,
                result: {
                    protocolVersion: PROTOCOL_VERSION,
                    runtime: process.version,
                    transportReady: true,
                    sillyTavernCoreReady: false,
                    capabilities: ['engine.status'],
                },
            });
        } catch (error) {
            request.resume();
            const known = error instanceof HostError;
            reply(response, known ? error.status : 500, {
                id,
                error: {
                    code: known ? error.code : 'INTERNAL_ERROR',
                    message: known ? error.message : 'Local engine request failed.',
                },
            });
        }
    });
    server.requestTimeout = 5000;
    server.headersTimeout = 5000;
    await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen({ host: '127.0.0.1', port: 0, exclusive: true }, () => {
            server.off('error', reject);
            resolve();
        });
    });
    const address = server.address();
    return {
        endpoint: { protocolVersion: PROTOCOL_VERSION, launchID, url: `http://127.0.0.1:${address.port}`, token },
        address,
        async close() {
            server.closeIdleConnections();
            await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
        },
    };
}
