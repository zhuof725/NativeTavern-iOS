// Lists the runtime packages a booting engine actually resolves.
//
// Loaders run in a worker thread, so they cannot write files on exit. Instead
// this hook streams each resolved bare specifier to a pipe, and the parent
// process records what arrives.
import fs from 'node:fs';

const log = process.env.NT_TRACE_LOG;

export async function resolve(specifier, context, next) {
    if (log && !specifier.startsWith('.') && !specifier.startsWith('/')
        && !specifier.startsWith('node:') && !specifier.startsWith('file:') && !specifier.startsWith('data:')) {
        const name = specifier.startsWith('@')
            ? specifier.split('/').slice(0, 2).join('/')
            : specifier.split('/')[0];
        try { fs.appendFileSync(log, name + '\n'); } catch { /* tracing must never break boot */ }
    }
    return next(specifier, context);
}
