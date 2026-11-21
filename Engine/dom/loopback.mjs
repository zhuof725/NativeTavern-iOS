// Routes the frontend core's root-relative requests to the upstream core.
//
// In a browser, pages resolve '/api/...' against the page origin and the session
// cookie rides along automatically. Here there is no browser: the core runs
// inside the app, so this shim supplies both the origin and a session jar. That
// keeps every upstream endpoint, payload and CSRF rule exactly as shipped.
export function installLoopbackFetch({ upstream }) {
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

    const send = async (url, init, retry) => {
        await ensureSession();
        const headers = new Headers(init.headers || {});
        const target = new URL(url);
        if (target.origin === origin) {
            headers.set('x-csrf-token', csrf);
            if (cookies.size) headers.set('cookie', [...cookies].map(([k, v]) => `${k}=${v}`).join('; '));
        }
        const response = await native(url, { ...init, headers, redirect: init.redirect ?? 'manual' });
        absorb(response);
        if (response.status === 403 && !retry) {
            csrf = null;
            cookies.clear();
            return send(url, init, true);
        }
        return response;
    };

    const shim = (input, init = {}) => {
        const raw = typeof input === 'string' ? input : input.url;
        const url = raw.startsWith('/') ? `${origin}${raw}` : raw;
        return send(url, init, false);
    };

    shim.__loopbackInstalled = true;
    globalThis.fetch = shim;
    return shim;
}
