// Hosts the SillyTavern web UI inside the app.
//
// The app's interface *is* the vendored frontend: every feature (extensions,
// slash commands, group chats, personas, themes, backups, the template and
// character editors) is already there. This module gives the native shell what
// it needs to frame the page safely:
//
//   webui.session → where the page is, and the address the system browser should
//                   open: a tiny entry document that trades a one-time token for
//                   a session cookie, then loads the interface.
//
// No Bearer header is ever needed by the browser. The entry document is served
// by the gateway (`/shell`, see host.mjs) and the token travels in its fragment,
// which is never sent to a server, logged, or leaked through Referer.
import { randomBytes } from 'node:crypto';

export function createWebUiApi({ getCore, upstream }) {
    const methods = new Map();
    /** Tokens minted for browser sessions; a token is valid for one hop. */
    const browseTokens = new Set();
    const define = (name, handler) => methods.set(name, handler);

    define('webui.session', async () => {
        let coreReady = false;
        try {
            const { core } = await getCore();
            coreReady = typeof core?.Generate === 'function';
        } catch {
            coreReady = false;
        }
        const origin = new URL(upstream).origin;
        const token = randomBytes(24).toString('hex');
        browseTokens.add(token);
        // The fragment is the only place a one-time secret can travel in a URL
        // the server never sees.
        const address = `${origin}/shell#token=${token}&target=${encodeURIComponent(origin)}`;
        return { path: '/', upstream, coreReady, browserURL: address, browsers: ['safari'] };
    });

    return {
        methods: [...methods.keys()],
        call(name, args) {
            const handler = methods.get(name);
            if (!handler) {
                const error = new Error(`Unknown method: ${name}`);
                error.status = 501;
                error.code = 'METHOD_NOT_IMPLEMENTED';
                throw error;
            }
            return handler(args ?? {});
        },
        /** Used by the gateway's `/shell` hop; one use per token. */
        consumeBrowseToken(value) {
            if (!browseTokens.has(value)) return false;
            browseTokens.delete(value);
            return true;
        },
    };
}
