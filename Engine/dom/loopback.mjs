// Routes the frontend core's requests to the upstream core.
//
// In a browser, pages resolve '/api/...' against the page origin and the session
// cookie rides along automatically. Here there is no browser: the core runs
// inside the app, so this shim supplies both the origin and a session jar. That
// keeps every upstream endpoint, payload and CSRF rule exactly as shipped.
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function installLoopbackFetch({ upstream, window, coreRoot }) {
    const native = globalThis.fetch;
    if (native.__loopbackInstalled) return native;

    const origin = new URL(upstream).origin;
    const cookies = new Map();
    let csrf = null;

    const absorb = (response) => {
        for (const raw of response.headers.getSetCookie?.() ?? []) {
            const [pair] = raw.split(';');
            const index = pair.indexOf('=');
            if (index > 0) cookies.set(pair.slice(0, index).trim(), pair.slice(index + 1).trim());
        }
    };

    const ensureSession = async () => {
        if (csrf) return;
        const response = await native(`${origin}/csrf-token`, { signal: AbortSignal.timeout(15000) });
        absorb(response);
        if (!response.ok) throw new Error(`Upstream session unavailable: ${response.status}`);
        csrf = (await response.json()).token;
    };

    // Resolves any input shape (string, URL, Request) to an absolute URL string.
    const resolveURL = (input) => {
        const raw = typeof input === 'string'
            ? input
            : (input?.url ?? String(input));
        if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
        return new URL(raw, `${origin}/`).href;
    };

    const send = async (url, init, retry) => {
        await ensureSession();
        const headers = new Headers(init?.headers ?? (url instanceof Request ? url.headers : undefined));
        if (new URL(url).origin === origin) {
            headers.set('x-csrf-token', csrf);
            if (cookies.size) headers.set('cookie', [...cookies].map(([k, v]) => `${k}=${v}`).join('; '));
        }
        const response = await native(url, { ...init, headers });
        absorb(response);
        if (response.status === 403 && !retry) {
            // Stale token or expired session: refresh once and retry.
            csrf = null;
            cookies.clear();
            return send(url, init, true);
        }
        if (response.status === 307 || response.status === 308) {
            const location = response.headers.get('location');
            if (location) return send(new URL(location, url).href, init, true);
        }
        if (response.status >= 400 && globalThis.process?.env?.NT_DEBUG_FETCH) {
            // The upstream body says WHY a call failed; the status alone doesn't.
            response.clone().text().then((text) => {
                console.log(`[fetch] ${init?.method ?? 'GET'} ${url} -> ${response.status}: ${text.slice(0, 500)}`);
            }).catch(() => {});
        }
        return response;
    };

    const shim = async (input, init = {}) => {
        const url = resolveURL(input);
        const target = new URL(url);
        // Image codecs (Jimp's WebAssembly decoders) load their kernels from
        // `new URL('./codec/x.wasm', import.meta.url)`. A browser would fetch
        // that file; here it is already on disk. Serving it from the file
        // system is what lets avatar and card image processing work.
        if (target.protocol === 'file:') {
            const filePath = fileURLToPath(target);
            if (coreRoot && !filePath.startsWith(coreRoot + path.sep)) {
                return new Response('{"error":"file is outside the engine"}', { status: 403 });
            }
            try {
                const data = await readFile(filePath);
                const type = filePath.endsWith('.wasm') ? 'application/wasm'
                    : filePath.endsWith('.png') ? 'image/png'
                        : filePath.endsWith('.jpg') || filePath.endsWith('.jpeg') ? 'image/jpeg'
                            : 'application/octet-stream';
                return new Response(data, { status: 200, headers: { 'content-type': type } });
            } catch {
                return new Response('not found', { status: 404 });
            }
        }
        // The core probes several external services on startup (Horde status and
        // model lists, OpenRouter auth…). Those are the web UI's conveniences and
        // their failures surface as unhandled socket errors. The engine answers
        // them as "unavailable" instead of reaching out to third parties.
        if (target.origin !== origin) {
            return new Response('{"error":"external requests are disabled in the app"}', {
                status: 503,
                headers: { 'content-type': 'application/json' },
            });
        }
        return send(url, init, false);
    };

    shim.__loopbackInstalled = true;
    globalThis.fetch = shim;
    // The page modules resolve bare `fetch` against the DOM global, which is a
    // different binding from Node's; both must point at the same transport.
    if (window) {
        window.fetch = shim;
        try { window.happyDOM?.settings?.setJavaScriptEvaluation?.('fetch', shim); } catch { /* older happy-dom */ }
    }
    return shim;
}
