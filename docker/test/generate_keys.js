#!/usr/bin/env node
/**
 * Generate ephemeral Nostr keypairs for agent and tester.
 * Output: JSON with agentNsec, agentNpub, testerNsec, testerNpub
 */
const { generateSecretKey, getPublicKey } = require('nostr-tools');
const { nip19 } = require('nostr-tools');

const agentSk = generateSecretKey();
const testerSk = generateSecretKey();

const keys = {
  agentNsec: nip19.nsecEncode(agentSk),
  agentNpub: nip19.npubEncode(getPublicKey(agentSk)),
  testerNsec: nip19.nsecEncode(testerSk),
  testerNpub: nip19.npubEncode(getPublicKey(testerSk)),
};

console.log(JSON.stringify(keys, null, 2));
