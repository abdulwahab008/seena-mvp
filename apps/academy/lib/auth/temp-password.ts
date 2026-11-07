import { randomInt } from 'node:crypto';

// No 0/O, 1/l/I: these get read off a printed slip by a child.
const ALPHABET = 'abcdefghjkmnpqrstuvwxyz23456789';

/** A 10-character temporary password, e.g. "k7m2p9x4qa". */
export function tempPassword(length = 10): string {
  return Array.from({ length }, () => ALPHABET[randomInt(ALPHABET.length)]).join('');
}
