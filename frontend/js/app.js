/**
 * SSOP Frontend — multi-step agent deployment wizard.
 *
 * Flow:
 *   1. Setup Fee (100 sats) → platform wallet
 *   2. Choose VPS Plan
 *   3. Choose Model + usage tier → cost estimate
 *   4. Pay (VPS + model credits)
 *   5. Provisioning
 *   6. Done
 */

import { generateKeypair } from './nostr.js';

// --- Config ---
const API_BASE = ''; // Orchestrator URL when ready
const SATS_PER_USD = 1000; // ~$100k/BTC approximation

// --- State ---
let state = {
  selectedPlan: null,
  selectedModel: null,
  selectedUsage: null,
  keypair: null,
  orderId: null,
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
  // Scroll to active step
  $(`#${stepId}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

// --- Models & Pricing ---
const MODELS = [
  {
    id: 'claude-opus-4-5',
    name: 'Claude Opus 4.5',
    provider: 'Anthropic',
    description: 'Most capable. Deep reasoning, nuanced writing, complex tasks.',
    inputPer1M: 5.0,    // $/1M tokens
    outputPer1M: 25.0,
    context: '200K',
    badge: 'Max Quality',
    badgeClass: 'badge-premium',
  },
  {
    id: 'claude-3-7-sonnet',
    name: 'Claude 3.7 Sonnet',
    provider: 'Anthropic',
    description: 'Great balance of speed and intelligence. Recommended for most agents.',
    inputPer1M: 3.0,
    outputPer1M: 15.0,
    context: '200K',
    badge: 'Recommended',
    badgeClass: 'badge-recommended',
  },
];

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

// --- Plans ---
const PLANS = [
  {
    id: 'tiny',
    name: 'Tiny',
    cpu: '1 vCPU',
    ram: '512 MB',
    disk: '10 GB',
    satsMo: 4200,
    fiat: '~€2.70/mo',
  },
  {
    id: 'small',
    name: 'Small',
    cpu: '1 vCPU',
    ram: '1 GB',
    disk: '20 GB',
    satsMo: 8400,
    fiat: '~€5.40/mo',
  },
  {
    id: 'medium',
    name: 'Medium',
    cpu: '2 vCPU',
    ram: '2 GB',
    disk: '40 GB',
    satsMo: 16800,
    fiat: '~€10.80/mo',
  },
  {
    id: 'large',
    name: 'Large',
    cpu: '4 vCPU',
    ram: '4 GB',
    disk: '80 GB',
    satsMo: 33600,
    fiat: '~€21.60/mo',
  },
];

// ========================================
// Step 1: Setup Fee
// ========================================
function setupFeeStep() {
  $('#btn-pay-setup').addEventListener('click', () => {
    // TODO: generate real Lightning invoice for 100 sats
    // For now, simulate payment
    const btn = $('#btn-pay-setup');
    btn.textContent = '⏳ Waiting for payment...';
    btn.disabled = true;

    // Mock: auto-advance after 1s
    setTimeout(() => {
      btn.textContent = '✅ Paid!';
      btn.classList.add('btn-success');
      setTimeout(() => showStep('step-plan'), 500);
    }, 1000);
  });
}

// ========================================
// Step 2: Choose Plan
// ========================================
function renderPlans() {
  const grid = $('#plans-grid');
  grid.innerHTML = '';
  PLANS.forEach((plan) => {
    const card = document.createElement('div');
    card.className = 'plan-card';
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
      showStep('step-model');
    });
    grid.appendChild(card);
  });
}

// ========================================
// Step 3: Choose Model + Usage
// ========================================
function renderModels() {
  const grid = $('#models-grid');
  grid.innerHTML = '';
  MODELS.forEach((model) => {
    const card = document.createElement('div');
    card.className = 'model-card';
    card.innerHTML = `
      <div class="model-header">
        <span class="model-name">${model.name}</span>
        <span class="badge ${model.badgeClass}">${model.badge}</span>
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

  // Usage tier selector
  const tierContainer = $('#usage-tiers');
  tierContainer.innerHTML = '';
  USAGE_TIERS.forEach((tier) => {
    const btn = document.createElement('button');
    btn.className = `btn btn-tier ${tier.id === 'medium' ? 'selected' : ''}`;
    btn.textContent = tier.name;
    btn.title = tier.description;
    btn.addEventListener('click', () => {
      $$('.btn-tier').forEach((b) => b.classList.remove('selected'));
      btn.classList.add('selected');
      state.selectedUsage = tier;
      updateCostEstimate();
    });
    tierContainer.appendChild(btn);
  });

  // Default to medium
  state.selectedUsage = USAGE_TIERS[1];
}

function updateCostEstimate() {
  const el = $('#cost-estimate');
  if (!state.selectedModel || !state.selectedUsage) {
    el.classList.add('hidden');
    return;
  }

  const cost = calcModelMonthlyCost(state.selectedModel, state.selectedUsage);
  const vpsSats = state.selectedPlan?.satsMo || 0;
  const totalSats = cost.sats + vpsSats + 100; // model + VPS + setup fee

  el.classList.remove('hidden');
  el.innerHTML = `
    <h3>Monthly Cost Estimate</h3>
    <table class="cost-table">
      <tr>
        <td>Setup fee (one-time)</td>
        <td class="cost-val">⚡ 100 sats</td>
      </tr>
      <tr>
        <td>VPS (${state.selectedPlan?.name || '—'})</td>
        <td class="cost-val">⚡ ${vpsSats.toLocaleString()} sats/mo</td>
      </tr>
      <tr>
        <td>
          Model (${state.selectedModel.name})
          <div class="cost-detail">${state.selectedUsage.name}: ~${cost.monthlyTurns.toLocaleString()} turns/mo</div>
          <div class="cost-detail">${cost.inputTokensM}M in + ${cost.outputTokensM}M out tokens</div>
        </td>
        <td class="cost-val">⚡ ${cost.sats.toLocaleString()} sats/mo<br><span class="cost-usd">~$${cost.usd}</span></td>
      </tr>
      <tr class="cost-total">
        <td>Total first month</td>
        <td class="cost-val">⚡ ${totalSats.toLocaleString()} sats</td>
      </tr>
    </table>
    <button id="btn-continue-to-identity" class="btn btn-primary">Continue →</button>
  `;

  $('#btn-continue-to-identity').addEventListener('click', () => {
    showStep('step-identity');
  });
}

// ========================================
// Step 4: Generate Identity
// ========================================
function setupIdentity() {
  $('#btn-generate').addEventListener('click', () => {
    state.keypair = generateKeypair();
    $('#npub').textContent = state.keypair.npub;
    $('#nsec').textContent = state.keypair.nsec;
    $('#identity-result').classList.remove('hidden');

    $('#btn-reveal').addEventListener('click', () => {
      $('#nsec').classList.toggle('revealed');
      $('#btn-reveal').textContent = $('#nsec').classList.contains('revealed')
        ? 'Hide'
        : 'Reveal';
    });

    setTimeout(() => showStep('step-pay'), 500);
    renderPaymentSummary();
  });
}

// ========================================
// Step 5: Pay (VPS + Model credits)
// ========================================
function renderPaymentSummary() {
  const cost = calcModelMonthlyCost(state.selectedModel, state.selectedUsage);
  const vpsSats = state.selectedPlan.satsMo;
  const totalSats = cost.sats + vpsSats;

  $('#payment-amount').textContent = `⚡ ${totalSats.toLocaleString()} sats`;
  $('#payment-breakdown').textContent =
    `${state.selectedPlan.name} VPS (${vpsSats.toLocaleString()}) + ${state.selectedModel.name} credits (${cost.sats.toLocaleString()})`;

  // Mock invoice
  const mockInvoice = 'lnbc' + totalSats + 'n1pn...mock_invoice...';
  $('#invoice-text').textContent = mockInvoice;
  $('#qr-code').textContent = `[ ${totalSats.toLocaleString()} sats ]`;

  $('#btn-copy-invoice').addEventListener('click', async () => {
    await navigator.clipboard.writeText(mockInvoice);
    $('#btn-copy-invoice').textContent = 'Copied!';
    setTimeout(() => ($('#btn-copy-invoice').textContent = 'Copy'), 2000);
  });
}

// ========================================
// Step 6 & 7: Provision + Done
// ========================================
function handleStatusUpdate(msg) {
  switch (msg.status) {
    case 'paid':
      $('#payment-status .status-dot').className = 'status-dot done';
      $('#payment-status span:last-child').textContent = 'Payment received!';
      showStep('step-provision');
      break;
    case 'provisioning':
      addLogLine(msg.message || 'Provisioning...');
      break;
    case 'ready':
      addLogLine('Agent is live! ✅', 'success');
      showAgentDetails(msg);
      setTimeout(() => showStep('step-done'), 1000);
      break;
    case 'error':
      addLogLine(`Error: ${msg.message}`, 'error');
      break;
  }
}

function addLogLine(text, cls = '') {
  const log = $('#provision-log');
  const line = document.createElement('div');
  line.className = `log-line ${cls}`;
  line.textContent = text;
  log.appendChild(line);
  log.scrollTop = log.scrollHeight;
}

function showAgentDetails(msg) {
  $('#agent-npub').textContent = state.keypair.npub;
  $('#agent-lnaddr').textContent = `${state.keypair.publicKey.slice(0, 16)}...@npub.cash`;
  $('#agent-ssh').textContent = msg.ssh || 'ssh root@<ip>';
  const statusUrl = msg.statusUrl || '#';
  $('#agent-status-url').href = statusUrl;
  $('#agent-status-url').textContent = statusUrl;
}

// --- Init ---
document.addEventListener('DOMContentLoaded', () => {
  setupFeeStep();
  renderPlans();
  renderModels();
  setupIdentity();
});
