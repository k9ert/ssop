/**
 * Nostr key generation utilities.
 * Uses nostr-tools via ESM CDN — no build step needed.
 */

import { generateSecretKey, getPublicKey } from 'https://esm.sh/nostr-tools@2.10.4/pure';
import { nsecEncode, npubEncode } from 'https://esm.sh/nostr-tools@2.10.4/nip19';

/**
 * Generate a new Nostr keypair.
 * Everything happens client-side — private key never leaves the browser.
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
