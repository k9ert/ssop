#!/usr/bin/env node
/**
 * SSOP Agent E2E Test — Send a Nostr DM and wait for reply.
 *
 * Usage: node send_dm.js <agent_npub> <sender_nsec> [timeout_seconds]
 *
 * Generates NIP-04 encrypted DM, sends to agent, listens for reply.
 * Exits 0 if reply received, 1 on timeout.
 */

const { generateSecretKey, getPublicKey, finalizeEvent, nip04, nip19 } = require("nostr-tools");
const { Relay } = require("nostr-tools/relay");
const { useWebSocketImplementation } = require("nostr-tools/relay");

// Use ws for Node.js
const WebSocket = require("ws");
useWebSocketImplementation(WebSocket);

const RELAY_URL = process.env.RELAY_URL || "wss://relay.damus.io";
const TEST_MESSAGE = process.env.TEST_MESSAGE || "Hello! Please reply with the word PONG.";
const TIMEOUT_S = parseInt(process.env.TIMEOUT_S || process.argv[4] || "60", 10);

function decodePubkey(input) {
  if (input.startsWith("npub1")) {
    const decoded = nip19.decode(input);
    return typeof decoded.data === "string" ? decoded.data : Buffer.from(decoded.data).toString("hex");
  }
  return input;
}

function decodeSeckey(input) {
  if (input.startsWith("nsec1")) {
    const decoded = nip19.decode(input);
    return typeof decoded.data === "string"
      ? Uint8Array.from(Buffer.from(decoded.data, "hex"))
      : decoded.data;
  }
  return Uint8Array.from(Buffer.from(input, "hex"));
}

async function main() {
  const agentNpub = process.argv[2];
  const senderNsec = process.argv[3];

  if (!agentNpub || !senderNsec) {
    console.error("Usage: node send_dm.js <agent_npub> <sender_nsec> [timeout_s]");
    process.exit(1);
  }

  const agentPubkeyHex = decodePubkey(agentNpub);
  const senderSeckey = decodeSeckey(senderNsec);
  const senderPubkeyHex = getPublicKey(senderSeckey);

  console.log(`Agent pubkey: ${agentPubkeyHex.slice(0, 16)}...`);
  console.log(`Sender pubkey: ${senderPubkeyHex.slice(0, 16)}...`);
  console.log(`Relay: ${RELAY_URL}`);
  console.log(`Timeout: ${TIMEOUT_S}s`);
  console.log(`Message: ${TEST_MESSAGE}`);
  console.log("");

  // Connect to relay
  const relay = await Relay.connect(RELAY_URL);
  console.log(`Connected to ${RELAY_URL}`);

  // Subscribe to replies BEFORE sending (so we don't miss fast replies)
  let replyReceived = false;
  const now = Math.floor(Date.now() / 1000);

  const sub = relay.subscribe(
    [{ kinds: [4], authors: [agentPubkeyHex], "#p": [senderPubkeyHex], since: now - 5 }],
    {
      onevent: async (event) => {
        try {
          const decrypted = await nip04.decrypt(senderSeckey, agentPubkeyHex, event.content);
          console.log(`\n✅ REPLY RECEIVED (${((Date.now() / 1000) - now).toFixed(1)}s):`);
          console.log(decrypted.slice(0, 500));
          replyReceived = true;
          cleanup(0);
        } catch (err) {
          console.error("Failed to decrypt reply:", err.message);
        }
      },
    }
  );

  // Send DM (NIP-04)
  const ciphertext = await nip04.encrypt(senderSeckey, agentPubkeyHex, TEST_MESSAGE);
  const event = finalizeEvent(
    {
      kind: 4,
      created_at: now,
      tags: [["p", agentPubkeyHex]],
      content: ciphertext,
    },
    senderSeckey
  );

  await relay.publish(event);
  console.log(`DM sent (event ${event.id.slice(0, 16)}...)`);
  console.log("Waiting for reply...");

  // Timeout
  const timer = setTimeout(() => {
    if (!replyReceived) {
      console.error(`\n❌ TIMEOUT: No reply after ${TIMEOUT_S}s`);
      cleanup(1);
    }
  }, TIMEOUT_S * 1000);

  function cleanup(code) {
    clearTimeout(timer);
    try { sub.close(); } catch {}
    try { relay.close(); } catch {}
    process.exit(code);
  }
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
