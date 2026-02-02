/**
 * SSOP Frontend — main application logic.
 *
 * Flow: Select Plan → Generate Identity → Pay Invoice → Provision → Done
 *
 * For MVP, the orchestrator API is stubbed with mock data.
 * Replace API_BASE when the orchestrator is live.
 */

import { generateKeypair } from './nostr.js';

// --- Config ---
const API_BASE = ''; // Set to orchestrator URL when ready

// --- State ---
let state = {
  selectedPlan: null,
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
}

// --- Plans ---
// Mock plans until orchestrator is live
const MOCK_PLANS = [
  {
    id: 'tiny',
    name: 'Tiny',
    cpu: '1 vCPU',
    ram: '512 MB',
    disk: '10 GB',
    sats: 4200,
    fiat: '~€2.70/mo',
  },
  {
    id: 'small',
    name: 'Small',
    cpu: '1 vCPU',
    ram: '1 GB',
    disk: '20 GB',
    sats: 8400,
    fiat: '~€5.40/mo',
  },
  {
    id: 'medium',
    name: 'Medium',
    cpu: '2 vCPU',
    ram: '2 GB',
    disk: '40 GB',
    sats: 16800,
    fiat: '~€10.80/mo',
  },
  {
    id: 'large',
    name: 'Large',
    cpu: '4 vCPU',
    ram: '4 GB',
    disk: '80 GB',
    sats: 33600,
    fiat: '~€21.60/mo',
  },
];

async function loadPlans() {
  // TODO: fetch from orchestrator API when live
  // const res = await fetch(`${API_BASE}/api/plans`);
  // const plans = await res.json();
  const plans = MOCK_PLANS;
  renderPlans(plans);
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
      <div class="plan-price">⚡ ${plan.sats.toLocaleString()} sats/mo</div>
      <div class="plan-price-fiat">${plan.fiat}</div>
    `;
    card.addEventListener('click', () => selectPlan(plan, card));
    grid.appendChild(card);
  });
}

function selectPlan(plan, card) {
  $$('.plan-card').forEach((c) => c.classList.remove('selected'));
  card.classList.add('selected');
  state.selectedPlan = plan;
  showStep('step-identity');
}

// --- Identity ---
function setupIdentity() {
  $('#btn-generate').addEventListener('click', () => {
    state.keypair = generateKeypair();
    $('#npub').textContent = state.keypair.npub;
    $('#nsec').textContent = state.keypair.nsec;
    $('#identity-result').classList.remove('hidden');

    // Reveal toggle
    $('#btn-reveal').addEventListener('click', () => {
      $('#nsec').classList.toggle('revealed');
      $('#btn-reveal').textContent = $('#nsec').classList.contains('revealed')
        ? 'Hide'
        : 'Reveal';
    });

    // Move to payment step
    setTimeout(() => showStep('step-pay'), 500);
    requestInvoice();
  });
}

// --- Payment ---
async function requestInvoice() {
  // TODO: call orchestrator API
  // const res = await fetch(`${API_BASE}/api/order`, {
  //   method: 'POST',
  //   headers: { 'Content-Type': 'application/json' },
  //   body: JSON.stringify({
  //     plan: state.selectedPlan.id,
  //     pubkey: state.keypair.publicKey,
  //   }),
  // });
  // const order = await res.json();
  // state.orderId = order.id;

  // Mock invoice for now
  const mockInvoice =
    'lnbc42000n1pn...mock_invoice_placeholder...';
  $('#invoice-amount').textContent = `⚡ ${state.selectedPlan.sats.toLocaleString()} sats`;
  $('#invoice-text').textContent = mockInvoice;

  // QR code placeholder — will use qrcode.js library
  $('#qr-code').textContent = '[ QR code — needs qrcode.js ]';

  // Copy button
  $('#btn-copy-invoice').addEventListener('click', async () => {
    await navigator.clipboard.writeText(mockInvoice);
    $('#btn-copy-invoice').textContent = 'Copied!';
    setTimeout(() => ($('#btn-copy-invoice').textContent = 'Copy'), 2000);
  });

  // TODO: open WebSocket for payment status
  // watchPayment(order.id);
}

// --- Provisioning (WebSocket) ---
function watchPayment(orderId) {
  // TODO: connect to orchestrator WebSocket
  // const ws = new WebSocket(`${API_BASE.replace('http', 'ws')}/api/ws/${orderId}`);
  // ws.onmessage = (event) => {
  //   const msg = JSON.parse(event.data);
  //   handleStatusUpdate(msg);
  // };
}

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
      $('#provision-status .status-dot').className = 'status-dot done';
      $('#provision-status span:last-child').textContent = 'Done!';
      showAgentDetails(msg);
      setTimeout(() => showStep('step-done'), 1000);
      break;

    case 'error':
      addLogLine(`Error: ${msg.message}`, 'error');
      $('#provision-status .status-dot').className = 'status-dot error';
      $('#provision-status span:last-child').textContent = 'Something went wrong.';
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
  loadPlans();
  setupIdentity();
});
