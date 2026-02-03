/**
 * SSOP API client — fetches plans/models from orchestrator,
 * falls back to mock data when API is unreachable.
 *
 * Config via URL params for testability:
 *   ?api=http://localhost:8080   — override API base
 *   ?mock=true                   — force mock mode (no network)
 */

// --- Config ---
const ORCHESTRATOR_URL = 'https://146-190-230-121.sslip.io';

function getConfig() {
  const params = new URLSearchParams(window.location.search);
  return {
    apiBase: params.get('api') || ORCHESTRATOR_URL,
    forceMock: params.get('mock') === 'true',
  };
}

// --- Mock Data ---
const MOCK_PLANS = [
  { id: 'tiny', name: 'Tiny', cpu: 1, ram: '1 GB', disk: '40 GB SSD', sats_mo: 4200, fiat_mo: '~$3.20' },
  { id: 'small', name: 'Small', cpu: 2, ram: '2 GB', disk: '80 GB SSD', sats_mo: 8400, fiat_mo: '~$6.05' },
  { id: 'medium', name: 'Medium', cpu: 4, ram: '4 GB', disk: '160 GB SSD', sats_mo: 16800, fiat_mo: '~$11.74' },
  { id: 'large', name: 'Large', cpu: 8, ram: '8 GB', disk: '400 GB SSD', sats_mo: 33600, fiat_mo: '~$25.99' },
];

const MOCK_MODELS = [
  { id: 'claude-opus-4-5', name: 'Claude Opus 4.5', provider: 'Anthropic', description: 'Most capable', input_per_1m: 5.0, output_per_1m: 25.0, context: '200K', ppq_model_id: 'claude-opus-4.5' },
  { id: 'claude-3-7-sonnet', name: 'Claude 3.7 Sonnet', provider: 'Anthropic', description: 'Balanced, recommended', input_per_1m: 3.0, output_per_1m: 15.0, context: '200K', ppq_model_id: 'anthropic/claude-3.7-sonnet' },
  { id: 'kimi-k2', name: 'Kimi K2 Instruct', provider: 'Moonshot AI', description: 'Best for agentic tasks', input_per_1m: 0.39, output_per_1m: 1.90, context: '256K', ppq_model_id: 'moonshotai/kimi-k2-0905' },
  { id: 'qwen3-30b-a3b', name: 'Qwen3-30B-A3B', provider: 'Alibaba', description: 'Cheapest, fast', input_per_1m: 0.08, output_per_1m: 0.33, context: '262K', ppq_model_id: 'qwen/qwen3-30b-a3b-instruct-2507' },
];

// --- API Client ---
let _useMock = false;

async function apiFetch(path, options = {}) {
  const cfg = getConfig();
  if (cfg.forceMock) {
    _useMock = true;
    return null;
  }
  try {
    const resp = await fetch(`${cfg.apiBase}${path}`, {
      ...options,
      headers: { 'Content-Type': 'application/json', ...options.headers },
    });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    return await resp.json();
  } catch (err) {
    console.warn(`API fetch failed (${path}): ${err.message} — using mock data`);
    _useMock = true;
    return null;
  }
}

/**
 * Fetch plans from API, fall back to mock.
 * Normalizes field names to camelCase for frontend use.
 */
export async function fetchPlans() {
  const data = await apiFetch('/api/plans');
  const raw = data?.plans || MOCK_PLANS;
  return raw.map((p) => ({
    id: p.id,
    name: p.name,
    cpu: typeof p.cpu === 'number' ? `${p.cpu} vCPU` : p.cpu,
    ram: p.ram,
    disk: p.disk,
    satsMo: p.sats_mo,
    fiat: p.fiat_mo,
  }));
}

/**
 * Fetch models from API, fall back to mock.
 * Adds badge metadata (frontend-only concern).
 */
export async function fetchModels() {
  const data = await apiFetch('/api/models');
  const raw = data?.models || MOCK_MODELS;

  const badges = {
    'claude-opus-4-5': { badge: 'Max Quality', badgeClass: 'badge-premium' },
    'claude-3-7-sonnet': { badge: 'Recommended', badgeClass: 'badge-recommended' },
    'kimi-k2': { badge: 'Best Agentic', badgeClass: 'badge-agentic' },
    'qwen3-30b-a3b': { badge: 'Cheapest', badgeClass: 'badge-cheap' },
  };

  return raw.map((m) => ({
    id: m.id,
    name: m.name,
    provider: m.provider,
    description: m.description,
    inputPer1M: m.input_per_1m,
    outputPer1M: m.output_per_1m,
    context: m.context,
    ppqModelId: m.ppq_model_id,
    ...(badges[m.id] || { badge: '', badgeClass: '' }),
  }));
}

/**
 * Create an order on the orchestrator.
 * Sends all injectable keys for provisioning.
 *
 * @param {string} pubkey — Nostr public key (hex)
 * @param {string} planId — VPS plan ID or 'byom'
 * @param {string} modelId — model ID
 * @param {string} nsec — Nostr private key (for LNVPS NIP-98 auth)
 * @param {object} extras — optional overrides:
 *   - byom: { host, user, port } — bring your own machine
 *   - ppqApiKey: string — user's own ppq.ai key
 *   - sshPubKey: string — user's own SSH public key
 */
export async function createOrder(pubkey, planId, modelId, nsec, extras = {}) {
  const body = {
    pubkey,
    plan: planId,
    model: modelId,
    nsec,
  };
  if (extras.npub) body.npub = extras.npub;
  if (extras.byom) body.byom = extras.byom;
  if (extras.ppqApiKey) body.ppq_api_key = extras.ppqApiKey;
  if (extras.sshPubKey) body.ssh_pub_key = extras.sshPubKey;
  if (extras.ownerNpub) body.owner_npub = extras.ownerNpub;

  const data = await apiFetch('/api/order', {
    method: 'POST',
    body: JSON.stringify(body),
  });

  if (data) return data;

  // Mock response
  return {
    order_id: 'mock-' + Math.random().toString(36).slice(2, 10),
    state: 'pending_setup',
    amount_sats: planId === 'byom' ? 100 : 5000,
    mock: true,
  };
}

/**
 * Poll order status.
 */
export async function getOrder(orderId) {
  const data = await apiFetch(`/api/order/${orderId}`);
  return data || { id: orderId, state: 'pending_setup', mock: true };
}

/**
 * Check if an order's invoice has been paid.
 */
export async function checkPayment(orderId) {
  const data = await apiFetch(`/api/order/${orderId}/check`);
  return data || { paid: false, mock: true };
}

/**
 * Check API health. Returns { ok, mode, apiBase }.
 */
export async function checkHealth() {
  const cfg = getConfig();
  if (cfg.forceMock) return { ok: false, mode: 'mock', apiBase: cfg.apiBase };
  try {
    const resp = await fetch(`${cfg.apiBase}/health`);
    const data = await resp.json();
    return { ok: data.status === 'ok', mode: 'live', apiBase: cfg.apiBase };
  } catch {
    return { ok: false, mode: 'mock', apiBase: cfg.apiBase };
  }
}

export function isMockMode() {
  return _useMock || getConfig().forceMock;
}
