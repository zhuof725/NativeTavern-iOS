// Boots the ORIGINAL SillyTavern server and frontend core inside the app's
// Node runtime, then exposes them over a loopback-only, token-gated transport.
//
// Nothing here reimplements SillyTavern: it starts upstream's own server.js,
// then runs upstream's own public/script.js module graph on a minimal DOM so the
// real world-info, macro and prompt-assembly code is what answers the app.
import { mkdir, writeFile, rename, readFile, appendFile, copyFile } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:net';
import { fileURLToPath } from 'node:url';
import { startLocalHost } from './host.mjs';
import { createEngineApi } from './api.mjs';
import { createGenerationApi } from './generation.mjs';
import { createLibraryApi } from './library.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));

const [dataRoot, launchID] = process.argv.slice(2);
if (!dataRoot || !path.isAbsolute(dataRoot)) {
    throw new Error('An absolute app-owned data directory is required.');
}

const coreRoot = path.join(here, 'core');
// The module resolution hooks need to know which tree they are serving.
process.env.NT_CORE_ROOT = coreRoot;

// Everything the engine does is also written next to the app's data, because a
// crash on a device leaves nothing else behind: stdout is not visible there.
const logFile = path.join(dataRoot, 'engine.log');
const log = (...parts) => {
    const line = `${new Date().toISOString()} [engine] ${parts.join(' ')}\n`;
    appendFile(logFile, line).catch(() => {});
};
process.on('uncaughtException', (error) => {
    log('uncaught:', error?.stack ?? String(error));
});
process.on('unhandledRejection', (reason) => {
    log('unhandled rejection:', reason?.stack ?? String(reason));
});
log('boot', process.version, path.basename(dataRoot));
const enginePort = await pickFreePort();

// Both the backend and the frontend core talk to the upstream origin.
const upstream = `http://127.0.0.1:${enginePort}`;

// The core is started lazily: the transport must come up first so the app can
// show progress instead of waiting on a multi-second module boot.
let corePromise = null;
let restorePromptOrderHook = null;
const loadCore = () => {
    corePromise ??= (async () => {
        const runtime = await import('./core-runtime.mjs');
        restorePromptOrderHook = runtime.restorePromptOrder;
        try {
            // The core's first load reads settings and characters from the
            // vendored server, so it cannot start before that server answers.
            await upstreamReady;
            const started = await runtime.startCore({
                upstream,
                coreRoot,
                log: (message) => {
                    log('[core]', message);
                    console.log('[core]', message);
                },
            });
            // Snapshot the healthy prompt order for this run.
            runtime.restorePromptOrder?.(started.modules);
            console.log('[core] ready');
            return started;
        } catch (error) {
            // A failed core load must be visible: without it every call returns
            // an opaque 500 and nothing says why.
            console.log('[core] failed to start:', error?.stack ?? error);
            throw error;
        }
    })();
    return corePromise;
};

// Start the backend in the background and let the transport answer immediately.
const upstreamReady = startUpstream(coreRoot, dataRoot, enginePort).catch((error) => {
    console.log('[upstream] failed:', error?.message ?? error);
    throw error;
});

// The gateway owns the upstream session (cookies + CSRF); generation needs it
// to reach the vendored server, so the API is wired after the host exists.
const host = await startLocalHost({ launchID, upstream, waitForUpstream: () => upstreamReady });

// Upstream may still be starting when the app fires its first call, so every
// upstream-backed call waits for it rather than racing it.
const session = {
    async request(method, requestPath, options) {
        await upstreamReady;
        return host.session.request(method, requestPath, options);
    },
};
const generation = createGenerationApi({
    getCore: loadCore,
    session,
    restorePromptOrder: (modules) => restorePromptOrderHook?.(modules),
});

/**
 * Writes a chat file through the vendored server's own endpoint.
 *
 * The server derives the chats subdirectory from `avatar_url` (a character's
 * avatar file name), so callers pass the real avatar rather than the display
 * name — otherwise the chat is written to a directory the reader never looks in.
 */
const saveChat = async ({ characterName, avatar, fileName, chat }) => {
    await upstreamReady;
    const response = await session.request('POST', '/api/chats/save', {
        headers: { 'content-type': 'application/json' },
        body: Buffer.from(JSON.stringify({
            avatar_url: avatar,
            file_name: fileName,
            chat,
            force: true,
        })),
    });
    const text = response.body?.toString('utf8') ?? '';
    if (response.status !== 200 || !text.includes('ok')) {
        throw new Error(`Chat save failed: ${response.status} ${text.slice(0, 200)}`);
    }

};

// One shared helper for calls the engine makes into the vendored server.
const upstreamPost = async (requestPath, body) => {
    await upstreamReady;
    const response = await session.request('POST', requestPath, {
        headers: { 'content-type': 'application/json' },
        body: Buffer.from(JSON.stringify(body ?? {})),
    });
    const text = response.body?.toString('utf8') ?? '';
    try { return JSON.parse(text); } catch { return text; }
};

const library = createLibraryApi({
    getCore: loadCore,
    session,
    saveChat,
    restorePromptOrder: (modules) => restorePromptOrderHook?.(modules),
    log: (message) => log('[library]', message),
});

const engine = createEngineApi({
    getCore: loadCore,
    generation,
    library,
    saveChat,
    upstreamPost,
    restorePromptOrder: (modules) => restorePromptOrderHook?.(modules),
});
host.attachEngine(engine);

await mkdir(dataRoot, { recursive: true, mode: 0o700 });
const temporary = path.join(dataRoot, `.endpoint-${randomUUID()}.json`);
try {
    await writeFile(temporary, JSON.stringify(host.endpoint), { encoding: 'utf8', mode: 0o600, flag: 'wx' });
    await rename(temporary, path.join(dataRoot, 'endpoint.json'));
} catch (error) {
    await host.close();
    throw error;
}

await upstreamReady;
console.log('NativeTavern: upstream SillyTavern core is running on loopback.');

/**
 * Starts upstream SillyTavern unchanged (its own server.js) on a private port.
 */
async function startUpstream(root, dataDir, port) {
    const nodeDataRoot = path.join(dataDir, 'sillytavern');
    await mkdir(nodeDataRoot, { recursive: true, mode: 0o700 });

    // Upstream resolves several paths against its working directory: backups,
    // the default avatar and the global extension folders. On a desktop those
    // sit in the repository; in an iOS app the bundle is read-only, so the
    // working directory has to be a writable copy under the app's data root.
    // Static files are still served from the bundle (serverDirectory is
    // absolute), so only the writable paths are mirrored here.
    const workRoot = path.join(nodeDataRoot, 'work');
    for (const relative of ['backups', 'cache', 'public/img', 'public/sounds', 'public/scripts/extensions/third-party']) {
        await mkdir(path.join(workRoot, relative), { recursive: true });
    }
    for (const [source, target] of [
        [path.join(root, 'public/img/ai4.png'), path.join(workRoot, 'public/img/ai4.png')],
        [path.join(root, 'config.yaml'), path.join(workRoot, 'config.yaml')],
    ]) {
        try {
            await copyFile(source, target);
        } catch {
            // The server creates a default config if it is missing; a missing
            // default avatar only affects newly created character cards.
        }
    }

    // Upstream reads these before its own argument parser runs.
    globalThis.DATA_ROOT = nodeDataRoot;
    globalThis.NT_CORE_ROOT = root;
    process.env.SILLYTAVERN_DATAROOT = nodeDataRoot;
    process.chdir(workRoot);
    log('upstream working directory', workRoot);

    // server.js calls process.chdir(serverDirectory) unconditionally. That
    // directory is inside the app bundle on iOS and is read-only, which is what
    // made the first `mkdir('backups/')` fail. The call is redirected to the
    // writable copy above; every path upstream builds from it is a runtime
    // output, while its own files are reached through absolute paths.
    const bundleRoot = path.resolve(root);
    const realChdir = process.chdir.bind(process);
    process.chdir = (target) => {
        const resolved = path.resolve(String(target));
        return realChdir(resolved === bundleRoot ? workRoot : target);
    };

    process.argv = [
        process.execPath, path.join(root, 'server.js'),
        '--port', String(port),
        '--listen', 'false',
        '--dataRoot', nodeDataRoot,
        '--browserLaunchEnabled', 'false',
        '--autorun', 'false',
        '--whitelist', 'false',
        '--disableCsrf', 'false',
    ];

    await import(`file://${path.join(root, 'server.js')}`);
    await waitForUpstream(port);
    await completeFirstRun(nodeDataRoot);
}

/**
 * Marks the vendored server's settings as past first run.
 *
 * Upstream's first run opens an onboarding dialog that asks the user for a name.
 * That dialog is part of the web UI; here it would wait forever and block the
 * core's settings load. The engine has its own UI, so it answers that question
 * ahead of time with the default name the settings already carry.
 */
async function completeFirstRun(nodeDataRoot) {
    const settingsDir = path.join(nodeDataRoot, 'default-user');
    const settingsFile = path.join(settingsDir, 'settings.json');
    try {
        const raw = await readFile(settingsFile, 'utf8');
        const settings = JSON.parse(raw);
        if (settings.firstRun) {
            settings.firstRun = false;
            await writeFile(settingsFile, JSON.stringify(settings, null, 4), 'utf8');
            console.log('[upstream] marked first run complete');
        }
    } catch {
        // No settings yet: upstream will create them, and the next start is clean.
    }
}

async function waitForUpstream(port, timeoutMs = 180000) {
    const deadline = Date.now() + timeoutMs;
    let lastError = null;
    while (Date.now() < deadline) {
        try {
            const response = await fetch(`http://127.0.0.1:${port}/csrf-token`, {
                signal: AbortSignal.timeout(5000),
            });
            if (response.ok) return;
            lastError = new Error(`csrf-token responded ${response.status}`);
        } catch (error) {
            lastError = error;
        }
        await new Promise((resolve) => setTimeout(resolve, 250));
    }
    throw lastError ?? new Error('Upstream SillyTavern did not start in time.');
}

async function pickFreePort() {
    return new Promise((resolve, reject) => {
        const server = createServer();
        server.once('error', reject);
        server.listen(0, '127.0.0.1', () => {
            const { port } = server.address();
            server.close(() => resolve(port));
        });
    });
}
