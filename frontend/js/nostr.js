/**
 * Nostr key generation and import utilities.
 * Uses nostr-tools via ESM CDN — no build step needed.
 */

import { generateSecretKey, getPublicKey } from 'https://esm.sh/nostr-tools@2.10.4/pure';
import { nsecEncode, npubEncode, decode as nip19decode } from 'https://esm.sh/nostr-tools@2.10.4/nip19';

/**
 * Generate a new Nostr keypair.
 * Everything happens client-side.
 * @returns {{ secretKey: Uint8Array, publicKey: string, nsec: string, npub: string }}
 */
export function generateKeypair() {
  const secretKey = generateSecretKey();
  const publicKey = getPublicKey(secretKey);
  return {
    secretKey,
    publicKey,
    nsec: nsecEncode(secretKey),
    npub: npubEncode(publicKey),
  };
}

/**
 * Import a keypair from an existing nsec string.
 * @param {string} nsec — bech32-encoded nsec1...
 * @returns {{ secretKey: Uint8Array, publicKey: string, nsec: string, npub: string }}
 * @throws {Error} if nsec is invalid
 */
export function importKeypair(nsec) {
  nsec = nsec.trim();
  if (!nsec.startsWith('nsec1')) {
    throw new Error('Invalid nsec — must start with nsec1');
  }
  const decoded = nip19decode(nsec);
  if (decoded.type !== 'nsec') {
    throw new Error('Invalid nsec encoding');
  }
  const secretKey = decoded.data;
  const publicKey = getPublicKey(secretKey);
  return {
    secretKey,
    publicKey,
    nsec: nsecEncode(secretKey),
    npub: npubEncode(publicKey),
  };
}
