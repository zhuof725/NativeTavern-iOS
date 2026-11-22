// Boots the engine in-process for tests that need the real core.
//
// The transport is the real one; only the launch identity is generated here, so
// tests exercise the same path the Swift app uses.
import { randomUUID } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { once } from 'node:events';

const bootEntry = fileURLToPath(new URL('../../Engine/boot.mjs', import.meta.url));

export async function installResolversAndBoot() {
    const directory = await mkdtemp(path.join(os.tmpdir(), 'native-tavern-gen-'));
    const launchID = randomUUID();
    const child = spawn(process.execPath, [bootEntry, directory, launchID], {
        stdio: ['ignore', 'pipe', 'pipe'],
        env: {},
    });
    let log = '';
    if (process.env.NT_TEST_VERBOSE) {
        const echo = (chunk) => {
            for (const line of String(chunk).split('\n')) {
                if (/\[core\]|\[upstream\]|Error|error/.test(line)) console.log(`  engine> ${line}`);
            }
        };
        child.stdout.on('data', echo);
        child.stderr.on('data', echo);
    }
    child.stdout.on('data', (chunk) => { log += chunk; });
    child.stderr.on('data', (chunk) => { log += chunk; });

    const endpointFile = path.join(directory, 'endpoint.json');
    const deadline = Date.now() + 180000;
    let endpoint = null;
    while (Date.now() < deadline) {
        try {
            endpoint = JSON.parse(await readFile(endpointFile, 'utf8'));
            break;
        } catch {
            await new Promise((resolve) => setTimeout(resolve, 250));
        }
    }
    if (!endpoint) throw new Error(`engine did not publish an endpoint:\n${log}`);

    const headers = {
        authorization: `Bearer ${endpoint.token}`,
        'content-type': 'application/json',
    };

    const post = async (apiPath, body) => {
        const response = await fetch(`${endpoint.url}/st${apiPath}`, {
            method: 'POST',
            headers,
            body: JSON.stringify(body ?? {}),
        });
        const text = await response.text();
        try { return JSON.parse(text); } catch { return text; }
    };

    const call = async (method, args = {}) => {
        const response = await fetch(`${endpoint.url}/engine/rpc`, {
            method: 'POST',
            headers,
            body: JSON.stringify({ id: randomUUID(), method, args }),
        });
        const body = await response.json();
        if (body.error) {
            // Include the engine's own log: its failures are only reported there.
            const tail = log.split('\n').filter((line) => /\[core\]|\[upstream\]|Error/.test(line)).slice(-8).join(' | ');
            throw new Error(`${body.error.code}: ${body.error.message}${tail ? ` [engine: ${tail}]` : ''}`);
        }
        return body.result;
    };

    return {
        endpoint,
        post,
        call,
        log: () => log,
        baseSettings: () => ({
            firstRun: false,
            username: 'User',
            user_avatar: 'user-default.png',
            amount_gen: 300,
            max_context: 8192,
            main_api: 'openai',
        }),
        async shutdown() {
            child.kill('SIGTERM');
            await once(child, 'exit').catch(() => {});
            await rm(directory, { recursive: true, force: true });
        },
    };
}
