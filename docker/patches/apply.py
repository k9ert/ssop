#!/usr/bin/env python3
"""
SSOP Agent Hot-Patch Applier
Applies known OpenClaw Nostr plugin fixes at Docker build time.

Patches:
  1. openclaw#7448: subscribeMany double-wraps filter array → use subscribe
  2. openclaw#7449: handleInboundMessage not a function → full dispatch pipeline
  3. openclaw#8570: normalizePubkey fails with nostr-tools 2.23+ (string vs Uint8Array)
"""

import os
import re
import sys
import glob

def find_nostr_extension():
    """Locate the installed @openclaw/nostr extension source."""
    candidates = [
        "/usr/lib/node_modules/openclaw/extensions/nostr/src",
        "/usr/local/lib/node_modules/openclaw/extensions/nostr/src",
        "/usr/lib/node_modules/@openclaw/nostr/src",
        "/usr/local/lib/node_modules/@openclaw/nostr/src",
    ]
    # Also search dynamically
    for base in ["/usr/lib/node_modules", "/usr/local/lib/node_modules"]:
        for path in glob.glob(f"{base}/**/nostr/src/channel.ts", recursive=True):
            candidates.insert(0, os.path.dirname(path))
    
    for c in candidates:
        if os.path.isdir(c):
            return c
    return None


def patch_subscribe_many(nostr_bus_path):
    """Fix #7448: subscribeMany double-wraps filter into [[filter]]."""
    if not os.path.exists(nostr_bus_path):
        print(f"  SKIP: {nostr_bus_path} not found")
        return False
    
    with open(nostr_bus_path, 'r') as f:
        content = f.read()
    
    if 'pool.subscribeMany' not in content:
        print("  SKIP #7448: subscribeMany not found (already patched or different version)")
        return False
    
    patched = re.sub(
        r'pool\.subscribeMany\(relays, \[(\{ kinds: \[4\], "#p": \[pk\], since \})\], \{',
        r'pool.subscribe(relays, \1, {',
        content
    )
    
    if patched == content:
        print("  SKIP #7448: regex didn't match")
        return False
    
    with open(nostr_bus_path, 'w') as f:
        f.write(patched)
    print("  APPLIED #7448: subscribeMany → subscribe")
    return True


def patch_handle_inbound_message(channel_path):
    """Fix #7449: Replace broken handleInboundMessage with full dispatch pipeline."""
    if not os.path.exists(channel_path):
        print(f"  SKIP: {channel_path} not found")
        return False
    
    with open(channel_path, 'r') as f:
        content = f.read()
    
    # Already patched?
    if 'dispatcherOptions' in content:
        print("  SKIP #7449: already patched (dispatcherOptions present)")
        return False
    
    # Find the onMessage handler
    marker = 'onMessage: async (senderPubkey, text, reply) => {'
    start = content.find(marker)
    if start == -1:
        print("  SKIP #7449: onMessage handler not found")
        return False
    
    # Find end boundary
    end = content.find('        onError: (error, context) => {', start + 50)
    if end == -1:
        print("  SKIP #7449: onError boundary not found")
        return False
    
    new_handler = """onMessage: async (senderPubkey, text, reply) => {
          ctx.log?.debug(`[${account.accountId}] DM from ${senderPubkey}: ${text.slice(0, 50)}...`);
          const runtime = getNostrRuntime();
          const cfg = runtime.config.loadConfig();
          const nostrCfg = (cfg as any).channels?.nostr ?? {};
          const dmPolicy = nostrCfg.dmPolicy ?? "pairing";
          const configAllowFrom = (nostrCfg.allowFrom ?? []).map((e: any) => String(e).trim()).filter(Boolean);
          let storeAllowFrom: string[] = [];
          try { storeAllowFrom = await runtime.channel.pairing.readAllowFromStore("nostr"); } catch {}
          const allAllowed = [...configAllowFrom, ...storeAllowFrom];
          const hasWildcard = allAllowed.includes("*");
          const normalizedSender = normalizePubkey(senderPubkey);
          const isAllowed = dmPolicy === "open" || hasWildcard ||
            allAllowed.some((a: string) => { try { return normalizePubkey(a) === normalizedSender; } catch { return a === senderPubkey; } });
          if (!isAllowed) {
            if (dmPolicy === "pairing") {
              try {
                const { code, created } = await runtime.channel.pairing.upsertPairingRequest({ channel: "nostr", id: normalizedSender, meta: { name: normalizedSender.slice(0, 12) + "..." } });
                if (created) {
                  ctx.log?.info(`[${account.accountId}] Nostr pairing request from ${normalizedSender}, code=${code}`);
                  await reply(runtime.channel.pairing.buildPairingReply({ channel: "nostr", idLine: `Your Nostr pubkey: ${normalizedSender}`, code }));
                }
              } catch (err: any) { ctx.log?.error(`[${account.accountId}] pairing error: ${err.message}`); }
            } else { ctx.log?.debug(`[${account.accountId}] blocked ${normalizedSender} (dmPolicy=${dmPolicy})`); }
            return;
          }
          const route = runtime.channel.routing.resolveAgentRoute({ cfg, channel: "nostr", accountId: account.accountId, peer: { kind: "dm" as const, id: normalizedSender } });
          const ctxPayload = runtime.channel.reply.finalizeInboundContext({
            Body: text, RawBody: text, CommandBody: text, From: normalizedSender, To: account.publicKey,
            SessionKey: route.sessionKey, AccountId: route.accountId, MessageSid: `nostr-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
            ChatType: "direct", ConversationLabel: normalizedSender, SenderName: normalizedSender.slice(0, 12) + "...",
            SenderId: normalizedSender, CommandAuthorized: true, Provider: "nostr", Surface: "nostr",
            OriginatingChannel: "nostr", OriginatingTo: normalizedSender, Timestamp: Date.now(),
          });
          try {
            const storePath = runtime.channel.session.resolveStorePath(cfg, route.agentId);
            await runtime.channel.session.recordSessionMetaFromInbound({ storePath, sessionKey: route.sessionKey, ctx: ctxPayload });
          } catch (err: any) { ctx.log?.warn(`[${account.accountId}] session meta: ${err.message}`); }
          try {
            await runtime.channel.reply.dispatchReplyWithBufferedBlockDispatcher({
              ctx: ctxPayload, cfg,
              dispatcherOptions: {
                deliver: async (payload: any, _info: any) => { const t = payload?.text?.trim(); if (t) await reply(t); },
                onReplyStart: undefined, onIdle: undefined,
                onSkip: (_p: any, info: any) => { ctx.log?.debug(`[${account.accountId}] reply skipped: ${info?.reason}`); },
                onError: (err: any, info: any) => { ctx.log?.error(`[${account.accountId}] dispatch error (${info?.kind}): ${String(err)}`); },
              },
            });
          } catch (err: any) {
            ctx.log?.error(`[${account.accountId}] dispatch error: ${err.message}`);
            try { await reply("I encountered an error processing your message."); } catch {}
          }
        },
        """
    
    with open(channel_path, 'w') as f:
        f.write(content[:start] + new_handler + content[end:])
    print("  APPLIED #7449: full dispatch pipeline")
    return True


def patch_normalize_pubkey(nostr_bus_path):
    """Fix #8570: normalizePubkey fails with nostr-tools 2.23+ (string data)."""
    if not os.path.exists(nostr_bus_path):
        print(f"  SKIP: {nostr_bus_path} not found")
        return False
    
    with open(nostr_bus_path, 'r') as f:
        content = f.read()
    
    if 'typeof decoded.data === "string"' in content:
        print("  SKIP #8570: normalizePubkey already handles string data")
        return False
    
    old = '// Convert Uint8Array to hex string'
    new = ('// Handle both string (nostr-tools 2.23+) and Uint8Array (older)\n'
           '    if (typeof decoded.data === "string") {\n'
           '      return decoded.data.toLowerCase();\n'
           '    }\n'
           '    // Convert Uint8Array to hex string (legacy)')
    
    if old not in content:
        print("  SKIP #8570: marker comment not found")
        return False
    
    with open(nostr_bus_path, 'w') as f:
        f.write(content.replace(old, new))
    print("  APPLIED #8570: normalizePubkey handles string + Uint8Array")
    return True


def main():
    print("=== SSOP Hot-Patch Applier ===")
    
    ext_dir = find_nostr_extension()
    if not ext_dir:
        print("WARNING: Nostr extension not found — skipping all patches")
        print("  This may mean openclaw or @openclaw/nostr failed to install")
        sys.exit(0)  # Don't fail build — patches are best-effort
    
    print(f"Found Nostr extension at: {ext_dir}")
    
    bus_path = os.path.join(ext_dir, "nostr-bus.ts")
    channel_path = os.path.join(ext_dir, "channel.ts")
    
    applied = 0
    applied += patch_subscribe_many(bus_path)
    applied += patch_handle_inbound_message(channel_path)
    applied += patch_normalize_pubkey(bus_path)
    
    print(f"\n{applied} patch(es) applied.")


if __name__ == "__main__":
    main()
