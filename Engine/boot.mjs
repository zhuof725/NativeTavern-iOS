// Boots the ORIGINAL SillyTavern server and frontend core inside the app's
// Node runtime, then exposes them over a loopback-only, token-gated transport.
//
// Nothing here reimplements SillyTavern: it starts upstream's own server.js,
// then runs upstream's own public/script.js module graph on a minimal DOM so the
// real world-info, macro and prompt-assembly code is what answers the app.
import { mkdir, writeFile, rename } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:net';
import { fileURLToPath } from 'node:url';
import { startLocalHost } from './host.mjs';
import { createEngineApi } from './api.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));

const [dataRoot, launchID] = process.argv.slice(2);
if (!dataRoot || !path.isAbsolute(dataRoot)) {
    throw new Error('An absolute app-owned data directory is required.');
}

const coreRoot = path.join(here, 'core');
const enginePort = await pickFreePort();

// Both the backend and the frontend core talk to the upstream origin.
const upstream = `http://127.0.0.1:${enginePort}`;

// The core is started lazily: the transport must come up first so the app can
// show progress instead of waiting on a multi-second module boot.
let corePromise = null;
const loadCore = () => {
    corePromise ??= (async () => {
        const runtime = await import('./core-runtime.mjs');
        return runtime.startCore({ upstream, coreRoot, log: (m) => console.log('[core]', m) });
    })();
    return corePromise;
};

const engine = createEngineApi({ getCore: loadCore });

// Start the backend in the background and let the transport answer immediately.
const upstreamReady = startUpstream(coreRoot, dataRoot, enginePort).catch((error) => {
    console.log('[upstream] failed:', error?.message ?? error);
    throw error;
});

const host = await startLocalHost({ launchID, upstream, engine });

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

    // Upstream reads these before its own argument parser runs. It also chdirs
    // to its own directory, so the core root is captured before that happens.
    globalThis.DATA_ROOT = nodeDataRoot;
    globalThis.NT_CORE_ROOT = root;
    process.env.SILLYTAVERN_DATAROOT = nodeDataRoot;
    process.chdir(root);

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
