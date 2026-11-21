// Synchronous SHA-256 over a UTF-8 string, returning lowercase hex.
// Matches the js-sha256 call shape upstream uses (sha256(str)).
import { createHash } from 'node:crypto';

export function sha256(value) {
    return createHash('sha256').update(String(value ?? ''), 'utf8').digest('hex');
}

export default sha256;
