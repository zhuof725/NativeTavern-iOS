import { mkdir, writeFile, rename } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { startLocalHost } from './host.mjs';

const [dataRoot, launchID] = process.argv.slice(2);
if (!dataRoot || !path.isAbsolute(dataRoot)) throw new Error('An absolute app-owned data directory is required.');
await mkdir(dataRoot, { recursive: true, mode: 0o700 });
const host = await startLocalHost({ launchID });
const temporary = path.join(dataRoot, `.endpoint-${randomUUID()}.json`);
try {
    await writeFile(temporary, JSON.stringify(host.endpoint), { encoding: 'utf8', mode: 0o600, flag: 'wx' });
    await rename(temporary, path.join(dataRoot, 'endpoint.json'));
} catch (error) {
    await host.close();
    throw error;
}
// No token or endpoint credential is printed to stdout.
console.log('NativeTavern local transport started; SillyTavern core integration is pending.');
