/**
 * SSOP Frontend — multi-step agent deployment wizard.
 *
 * Flow:
 *   1. Setup Fee (100 sats)
 *   2. Choose VPS Plan        ← fetched from orchestrator API
 *   3. Choose Model + usage   ← fetched from orchestrator API
 *   4. Generate Nostr Identity
 *   5. Pay (VPS + model credits)
 *   6. Provisioning
 *   7. Done
 *
 * Testability:
 *   ?mock=true   — force mock mode, no API calls
 *   ?api=<url>   — override orchestrator URL
 *   ?step=<id>   — jump to step (e.g. ?step=step-model)
 */

import { generateKeypair, importKeypair } from './nostr.js';
import { fetchPlans, fetchModels, createOrder, checkPayment, getOrder, checkHealth, isMockMode } from './client.js';

// --- Constants ---
const SATS_PER_USD = 1000; // ~$100k/BTC approximation

// Usage tiers: estimated tokens per month based on agent activity
const USAGE_TIERS = [
  {
    id: 'light',
    name: 'Light',
    description: 'Heartbeats + a few conversations/day',
    turnsPerDay: 50,
    avgInputTokens: 3000,
    avgOutputTokens: 1000,
  },
  {
    id: 'medium',
    name: 'Medium',
    description: 'Active agent: crons, engagement, regular chats',
    turnsPerDay: 150,
    avgInputTokens: 3000,
    avgOutputTokens: 1000,
  },
  {
    id: 'heavy',
    name: 'Heavy',
    description: 'Always-on: coding, research, multiple channels',
    turnsPerDay: 400,
    avgInputTokens: 3500,
    avgOutputTokens: 1500,
  },
];

// --- State ---
let state = {
  plans: [],
  models: [],
  selectedPlan: null,
  selectedModel: null,
  selectedUsage: USAGE_TIERS[1], // default: medium
  keypair: null,
  orderId: null,
  // Injectable overrides
  byom: null,        // { host, user, port } — bring your own machine
  ppqApiKey: null,    // user-provided ppq.ai key
  sshPubKey: null,    // user-provided SSH public key
  ownerNpub: null,   // owner's npub for auto-pairing
};

// --- DOM Helpers ---
const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

function showStep(stepId) {
  $$('.step').forEach((el) => {
    if (el.id === stepId) {
      el.classList.add('active');
      el.classList.remove('completed');
    } else if (el.classList.contains('active')) {
      el.classList.remove('active');
      el.classList.add('completed');
    }
  });
  $(`#${stepId}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

// --- Pricing ---
function calcModelMonthlyCost(model, usage) {
  const monthlyTurns = usage.turnsPerDay * 30;
  const inputTokensM = (monthlyTurns * usage.avgInputTokens) / 1_000_000;
  const outputTokensM = (monthlyTurns * usage.avgOutputTokens) / 1_000_000;
  const usd = inputTokensM * model.inputPer1M + outputTokensM * model.outputPer1M;
  return {
    usd: Math.round(usd * 100) / 100,
    sats: Math.round(usd * SATS_PER_USD),
    inputTokensM: Math.round(inputTokensM * 10) / 10,
    outputTokensM: Math.round(outputTokensM * 10) / 10,
    monthlyTurns,
  };
}

// ========================================
// Status Banner
// ========================================
function showStatusBanner(health) {
  const existing = $('#api-status');
  if (existing) existing.remove();

  const banner = document.createElement('div');
  banner.id = 'api-status';
  banner.className = `api-status ${health.mode}`;

  if (health.mode === 'live') {
    banner.innerHTML = `<span class="status-dot done"></span> Live — ${health.apiBase}`;
  } else {
    banner.innerHTML = `<span class="status-dot error"></span> Mock mode — API unreachable`;
  }

  $('header').appendChild(banner);
}

// ========================================
// Step 1: Setup Fee
// ========================================
function setupFeeStep() {
  $('#btn-pay-setup').addEventListener('click', () => {
    const btn = $('#btn-pay-setup');
    btn.textContent = '⏳ Waiting for payment...';
    btn.disabled = true;

    // TODO: generate real Lightning invoice for 100 sats via orchestrator
    const mockInvoice = 'lnbc1000n1pnsetupfee00000000000000000000000000000000000000000000000000000mock';
    showQR('setup-qr', mockInvoice);

    // Mock: auto-advance after 2s (will be real payment detection)
    setTimeout(() => {
      btn.textContent = '✅ Paid!';
      btn.classList.add('btn-success');
      setTimeout(() => showStep('step-plan'), 500);
    }, 2000);
  });
}

// ========================================
// Step 2: Choose Plan (from API) or BYOM
// ========================================
function setupPlanStep() {
  const tabLnvps = $('#tab-lnvps');
  const tabByom = $('#tab-byom');
  const panelLnvps = $('#panel-lnvps');
  const panelByom = $('#panel-byom');

  tabLnvps.addEventListener('click', () => {
    tabLnvps.classList.add('active');
    tabByom.classList.remove('active');
    panelLnvps.classList.remove('hidden');
    panelByom.classList.add('hidden');
    state.byom = null;
  });

  tabByom.addEventListener('click', () => {
    tabByom.classList.add('active');
    tabLnvps.classList.remove('active');
    panelByom.classList.remove('hidden');
    panelLnvps.classList.add('hidden');
  });

  $('#btn-use-byom').addEventListener('click', () => {
    const host = $('#byom-host').value.trim();
    const user = $('#byom-user').value.trim() || 'root';
    const port = parseInt($('#byom-port').value.trim()) || 22;
    if (!host) { alert('Please enter a host IP or hostname.'); return; }
    state.byom = { host, user, port };
    state.selectedPlan = { id: 'byom', name: 'Your Machine', satsMo: 0, fiat: '$0', cpu: '?', ram: '?', disk: '?' };
    showStep('step-model');
  });
}

function renderPlans(plans) {
  const grid = $('#plans-grid');
  grid.innerHTML = '';
  plans.forEach((plan) => {
    const card = document.createElement('div');
    card.className = 'plan-card';
    card.dataset.planId = plan.id;
    card.innerHTML = `
      <div class="plan-name">${plan.name}</div>
      <div class="plan-specs">${plan.cpu} · ${plan.ram} · ${plan.disk}</div>
      <div class="plan-price">⚡ ${plan.satsMo.toLocaleString()} sats/mo</div>
      <div class="plan-price-fiat">${plan.fiat}</div>
    `;
    card.addEventListener('click', () => {
      $$('.plan-card').forEach((c) => c.classList.remove('selected'));
      card.classList.add('selected');
      state.selectedPlan = plan;
      state.byom = null;
      showStep('step-model');
    });
    grid.appendChild(card);
  });
}

// ========================================
// Step 3: Choose Model + Usage (from API)
// ========================================
function renderModels(models) {
  const grid = $('#models-grid');
  grid.innerHTML = '';
  models.forEach((model) => {
    const card = document.createElement('div');
    card.className = 'model-card';
    card.dataset.modelId = model.id;
    card.innerHTML = `
      <div class="model-header">
        <span class="model-name">${model.name}</span>
        ${model.badge ? `<span class="badge ${model.badgeClass}">${model.badge}</span>` : ''}
      </div>
      <div class="model-provider">${model.provider} · ${model.context} context</div>
      <div class="model-desc">${model.description}</div>
      <div class="model-pricing">
        <span>$${model.inputPer1M}/1M in</span> · <span>$${model.outputPer1M}/1M out</span>
      </div>
    `;
    card.addEventListener('click', () => {
      $$('.model-card').forEach((c) => c.classList.remove('selected'));
      card.classList.add('selected');
      state.selectedModel = model;
      updateCostEstimate();
    });
    grid.appendChild(card);
  });

  renderUsageTiers();
}

function renderUsageTiers() {
  const container = $('#usage-tiers');
  container.innerHTML = '';
  USAGE_TIERS.forEach((tier) => {
    const btn = document.createElement('button');
    btn.className = `btn btn-tier ${tier.id === state.selectedUsage.id ? 'selected' : ''}`;
    btn.textContent = tier.name;
    btn.title = tier.description;
    btn.dataset.tierId = tier.id;
    btn.addEventListener('click', () => {
      $$('.btn-tier').forEach((b) => b.classList.remove('selected'));
      btn.classList.add('selected');
      state.selectedUsage = tier;
      updateCostEstimate();
    });
    container.appendChild(btn);
  });
}

function updateCostEstimate() {
  const el = $('#cost-estimate');
  if (!state.selectedModel || !state.selectedUsage) {
    el.classList.add('hidden');
    return;
  }

  const cost = calcModelMonthlyCost(state.selectedModel, state.selectedUsage);
  const vpsSats = state.selectedPlan?.satsMo || 0;
  const totalSats = cost.sats + vpsSats + 100;

  el.classList.remove('hidden');
  el.innerHTML = `
    <h3>Monthly Cost Estimate</h3>
    <table class="cost-table">
      <tr><td>Setup fee (one-time)</td><td class="cost-val">⚡ 100 sats</td></tr>
      <tr><td>VPS (${state.selectedPlan?.name || '—'})</td><td class="cost-val">⚡ ${vpsSats.toLocaleString()} sats/mo</td></tr>
      <tr>
        <td>
          Model (${state.selectedModel.name})
          <div class="cost-detail">${state.selectedUsage.name}: ~${cost.monthlyTurns.toLocaleString()} turns/mo</div>
          <div class="cost-detail">${cost.inputTokensM}M in + ${cost.outputTokensM}M out tokens</div>
        </td>
        <td class="cost-val">⚡ ${cost.sats.toLocaleString()} sats/mo<br><span class="cost-usd">~$${cost.usd}</span></td>
      </tr>
      <tr class="cost-total"><td>Total first month</td><td class="cost-val">⚡ ${totalSats.toLocaleString()} sats</td></tr>
    </table>
    <button id="btn-continue-to-identity" class="btn btn-primary">Continue →</button>
  `;

  $('#btn-continue-to-identity').addEventListener('click', () => {
    showStep('step-identity');
  });
}

// ========================================
// Step 4: Agent Identity (Generate or Import)
// ========================================
function setupIdentity() {
  const tabGenerate = $('#tab-generate');
  const tabImport = $('#tab-import');
  const panelGenerate = $('#panel-generate');
  const panelImport = $('#panel-import');

  // Tab switching
  tabGenerate.addEventListener('click', () => {
    tabGenerate.classList.add('active');
    tabImport.classList.remove('active');
    panelGenerate.classList.remove('hidden');
    panelImport.classList.add('hidden');
  });

  tabImport.addEventListener('click', () => {
    tabImport.classList.add('active');
    tabGenerate.classList.remove('active');
    panelImport.classList.remove('hidden');
    panelGenerate.classList.add('hidden');
  });

  // Generate new keypair
  $('#btn-generate').addEventListener('click', () => {
    state.keypair = generateKeypair();
    showKeypairAndContinue();
  });

  // Import existing nsec
  $('#btn-import').addEventListener('click', () => {
    const nsecInput = $('#nsec-input').value;
    try {
      state.keypair = importKeypair(nsecInput);
      showKeypairAndContinue();
    } catch (err) {
      alert(`Invalid nsec: ${err.message}`);
    }
  });

  // Also allow Enter key in nsec input
  $('#nsec-input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') $('#btn-import').click();
  });
}

async function showKeypairAndContinue() {
  const cfg = new URLSearchParams(window.location.search);
  const isTest = cfg.get('mock') === 'true';

  $('#npub').textContent = state.keypair.npub;
  $('#nsec').textContent = state.keypair.nsec;
  $('#identity-result').classList.remove('hidden');

  // In test/mock mode, reveal nsec by default
  const nsecEl = $('#nsec');
  if (isTest) {
    nsecEl.classList.remove('blurred');
    nsecEl.classList.add('revealed');
  }

  // Reveal toggle
  $('#btn-reveal').addEventListener('click', () => {
    nsecEl.classList.toggle('revealed');
    nsecEl.classList.toggle('blurred');
    $('#btn-reveal').textContent = nsecEl.classList.contains('revealed')
      ? 'Hide' : 'Reveal';
  });

  // Collect injectable overrides
  const ppqKey = $('#ppq-key-input')?.value?.trim() || null;
  const sshKey = $('#ssh-key-input')?.value?.trim() || null;
  const ownerNpub = $('#owner-npub-input')?.value?.trim() || null;
  if (ppqKey) state.ppqApiKey = ppqKey;
  if (sshKey) state.sshPubKey = sshKey;
  if (ownerNpub) state.ownerNpub = ownerNpub;

  // Create order on orchestrator (sends all keys for provisioning)
  const order = await createOrder(
    state.keypair.publicKey,
    state.selectedPlan.id,
    state.selectedModel.id,
    state.keypair.nsec,
    {
      npub: state.keypair.npub,
      byom: state.byom,
      ppqApiKey: state.ppqApiKey,
      sshPubKey: state.sshPubKey,
      ownerNpub: state.ownerNpub,
    },
  );
  state.orderId = order.order_id;
  console.log('Order created:', order);

  setTimeout(() => showStep('step-pay'), 500);
  renderPaymentSummary(order);
}

// ========================================
// Step 5: Pay
// ========================================
function renderPaymentSummary(order) {
  const cost = calcModelMonthlyCost(state.selectedModel, state.selectedUsage);
  const vpsSats = state.selectedPlan.satsMo;
  const totalSats = order?.amount_sats || (cost.sats + vpsSats);

  $('#payment-amount').textContent = `⚡ ${totalSats.toLocaleString()} sats`;
  $('#payment-breakdown').textContent =
    `${state.selectedPlan.name} VPS (${vpsSats.toLocaleString()}) + ${state.selectedModel.name} credits (${cost.sats.toLocaleString()})`;

  const invoice = order?.bolt11 || 'lnbc_mock_no_api';
  $('#invoice-text').textContent = invoice;

  showQR('qr-code', invoice);

  // Copy button
  const copyBtn = $('#btn-copy-invoice');
  const newBtn = copyBtn.cloneNode(true);
  copyBtn.replaceWith(newBtn);
  newBtn.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(invoice);
      newBtn.textContent = 'Copied!';
      setTimeout(() => (newBtn.textContent = 'Copy'), 2000);
    } catch {
      newBtn.textContent = 'Copy failed';
    }
  });

  // Poll for payment (every 3s)
  if (order?.order_id && !order.mock) {
    startPaymentPolling(order.order_id);
  }
}

function startPaymentPolling(orderId) {
  const statusEl = $('#payment-status');
  const paymentPoll = setInterval(async () => {
    try {
      const result = await checkPayment(orderId);
      if (result?.paid) {
        clearInterval(paymentPoll);
        statusEl.innerHTML = '<span class="status-dot done"></span><span>Payment received! ⚡</span>';
        addLogLine('Payment confirmed. Starting provisioning...');
        showStep('step-provision');
        // Switch to provisioning status polling
        startProvisionPolling(orderId);
      }
    } catch (err) {
      console.warn('Payment poll error:', err);
    }
  }, 3000);
}

function startProvisionPolling(orderId) {
  const statusEl = $('#provision-status');
  let lastState = '';

  const poll = setInterval(async () => {
    try {
      const order = await getOrder(orderId);
      const st = order?.state || 'unknown';

      // Show state transitions as log lines
      if (st !== lastState) {
        lastState = st;
        if (st === 'provisioning') {
          addLogLine('Connecting to server via SSH...');
          addLogLine('Uploading bootstrap script...');
          statusEl.innerHTML = '<span class="status-dot working"></span><span>Installing OpenClaw (this may take a few minutes)...</span>';
        } else if (st === 'ready') {
          clearInterval(poll);
          addLogLine('Agent gateway is healthy! ✅', 'success');
          statusEl.innerHTML = '<span class="status-dot done"></span><span>Provisioning complete!</span>';
          showStep('step-done');
          showAgentDetails({
            vm_ip: order.vm_ip || state.byom?.host || 'pending',
            ssh: order.ssh_access || `ssh root@${order.vm_ip || state.byom?.host || '<ip>'}`,
            lnaddr: state.keypair?.npub + '@npub.cash',
          });
        } else if (st === 'error') {
          clearInterval(poll);
          const errMsg = order.error_msg || 'Unknown error during provisioning';
          addLogLine(`Error: ${errMsg}`, 'error');
          statusEl.innerHTML = '<span class="status-dot error"></span><span>Provisioning failed</span>';
        }
      }
    } catch (err) {
      console.warn('Provision poll error:', err);
    }
  }, 4000);
}

// ========================================
// Step 6 & 7: Provision + Done
// ========================================
function addLogLine(text, cls = '') {
  const log = $('#provision-log');
  const line = document.createElement('div');
  line.className = `log-line ${cls}`;
  line.textContent = text;
  log.appendChild(line);
  log.scrollTop = log.scrollHeight;
}

function showAgentDetails(details) {
  $('#agent-npub').textContent = state.keypair?.npub || details.pubkey || '—';
  $('#agent-lnaddr').textContent = details.lnaddr || '—';
  $('#agent-ssh').textContent = details.ssh || `ssh root@${details.vm_ip || '<ip>'}`;
  const statusUrl = details.statusUrl || '#';
  $('#agent-status-url').href = statusUrl;
  $('#agent-status-url').textContent = statusUrl;
}

// ========================================
// QR Code helper
// ========================================
function showQR(containerId, data) {
  const container = document.getElementById(containerId);
  if (!container || typeof QRCode === 'undefined') return;
  container.innerHTML = '';
  container.classList.remove('hidden');
  const canvas = document.createElement('canvas');
  container.appendChild(canvas);
  QRCode.toCanvas(canvas, data.toUpperCase(), {
    width: 200, margin: 2,
    color: { dark: '#000000', light: '#ffffff' },
  }).catch(() => {
    container.textContent = '[ QR failed ]';
  });
}

// ========================================
// Debug: jump to step via ?step=
// ========================================
function handleStepParam() {
  const params = new URLSearchParams(window.location.search);
  const step = params.get('step');
  if (step) {
    // Activate all prior steps as completed
    const steps = [...$$('.step')];
    let found = false;
    steps.forEach((el) => {
      if (el.id === step) {
        found = true;
        el.classList.add('active');
        el.classList.remove('completed');
      } else if (!found) {
        el.classList.add('completed');
        el.classList.remove('active');
      } else {
        el.classList.remove('active', 'completed');
      }
    });
  }
}

// ========================================
// Init
// ========================================
document.addEventListener('DOMContentLoaded', async () => {
  // Check API health and show status
  const health = await checkHealth();
  showStatusBanner(health);

  // Fetch data from API (or mock)
  const [plans, models] = await Promise.all([fetchPlans(), fetchModels()]);
  state.plans = plans;
  state.models = models;

  // Render
  setupFeeStep();
  setupPlanStep();
  renderPlans(plans);
  renderModels(models);
  setupIdentity();

  // Debug: allow jumping to a step
  handleStepParam();

  console.log(`SSOP initialized — mode: ${health.mode}, plans: ${plans.length}, models: ${models.length}`);
});
