package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
)

// PendingSecrets holds sensitive data in memory during provisioning (never persisted)
type PendingSecrets struct {
	Nsec      string      // Nostr private key
	Npub      string      // Nostr public key (bech32 npub1...)
	PPQAPIKey string      // ppq.ai API key (user's own, or empty for shared)
	SSHPubKey string      // user-provided SSH public key
	BYOM      *BYOMConfig // bring your own machine
	OwnerNpub string      // owner's npub for DM allowlist auto-pairing
}

// Server holds the application state
type Server struct {
	cfg     Config
	db      *sql.DB
	lnbits  *LNbitsClient
	mu      sync.Mutex
	pending map[string]*PendingSecrets // orderID → secrets (in-memory only, cleared after provisioning)
}

// NewServer creates a new server instance
func NewServer(cfg Config, db *sql.DB) *Server {
	return &Server{
		cfg:     cfg,
		db:      db,
		lnbits:  NewLNbitsClient(cfg.LNbitsURL, cfg.LNbitsKey),
		pending: make(map[string]*PendingSecrets),
	}
}

// Plan represents a VPS plan
type Plan struct {
	ID      string  `json:"id"`
	Name    string  `json:"name"`
	CPU     int     `json:"cpu"`
	RAM     string  `json:"ram"`
	Disk    string  `json:"disk"`
	SatsMo  int64   `json:"sats_mo"`
	FiatMo  string  `json:"fiat_mo"`
	LNVPSTemplate int `json:"lnvps_template_id"`
}

// Model represents an LLM model option
type Model struct {
	ID          string  `json:"id"`
	Name        string  `json:"name"`
	Provider    string  `json:"provider"`
	Description string  `json:"description"`
	InputPer1M  float64 `json:"input_per_1m"`
	OutputPer1M float64 `json:"output_per_1m"`
	Context     string  `json:"context"`
	PPQModelID  string  `json:"ppq_model_id"`
}

var plans = []Plan{
	{ID: "small", Name: "Small", CPU: 2, RAM: "2 GB", Disk: "80 GB SSD", SatsMo: 8400, FiatMo: "~$6.05", LNVPSTemplate: 2},
	{ID: "medium", Name: "Medium", CPU: 4, RAM: "4 GB", Disk: "160 GB SSD", SatsMo: 16800, FiatMo: "~$11.74", LNVPSTemplate: 3},
	{ID: "large", Name: "Large", CPU: 8, RAM: "8 GB", Disk: "400 GB SSD", SatsMo: 33600, FiatMo: "~$25.99", LNVPSTemplate: 4},
}

var models = []Model{
	{ID: "claude-opus-4-5", Name: "Claude Opus 4.5", Provider: "Anthropic", Description: "Most capable", InputPer1M: 5.0, OutputPer1M: 25.0, Context: "200K", PPQModelID: "claude-opus-4.5"},
	{ID: "claude-3-7-sonnet", Name: "Claude 3.7 Sonnet", Provider: "Anthropic", Description: "Balanced, recommended", InputPer1M: 3.0, OutputPer1M: 15.0, Context: "200K", PPQModelID: "anthropic/claude-3.7-sonnet"},
	{ID: "kimi-k2", Name: "Kimi K2 Instruct", Provider: "Moonshot AI", Description: "Best for agentic tasks", InputPer1M: 0.39, OutputPer1M: 1.90, Context: "256K", PPQModelID: "moonshotai/kimi-k2-0905"},
}

// HandleGetPlans returns available VPS plans
func (s *Server) HandleGetPlans(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"plans": plans})
}

// HandleGetModels returns available LLM models
func (s *Server) HandleGetModels(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"models": models})
}

// BYOMConfig is the "bring your own machine" SSH details
type BYOMConfig struct {
	Host string `json:"host"`
	User string `json:"user"`
	Port int    `json:"port"`
}

// CreateOrderRequest is the request body for creating an order
type CreateOrderRequest struct {
	Pubkey    string      `json:"pubkey"`
	Npub      string      `json:"npub,omitempty"`         // bech32 npub for bootstrap config
	Plan      string      `json:"plan"`
	Model     string      `json:"model"`
	Nsec      string      `json:"nsec,omitempty"`         // held in memory, never persisted
	BYOM      *BYOMConfig `json:"byom,omitempty"`         // bring your own machine
	PPQAPIKey string      `json:"ppq_api_key,omitempty"`  // held in memory, never persisted
	SSHPubKey string      `json:"ssh_pub_key,omitempty"`  // user-provided SSH public key
	OwnerNpub string      `json:"owner_npub,omitempty"`   // owner's npub for DM allowlist
}

// HandleCreateOrder creates a new deployment order
func (s *Server) HandleCreateOrder(w http.ResponseWriter, r *http.Request) {
	var req CreateOrderRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	// Validate plan (BYOM skips VPS plan)
	isBYOM := req.Plan == "byom" && req.BYOM != nil
	var plan *Plan
	if isBYOM {
		plan = &Plan{ID: "byom", Name: "Your Machine", SatsMo: 0}
	} else {
		for i := range plans {
			if plans[i].ID == req.Plan {
				plan = &plans[i]
				break
			}
		}
		if plan == nil {
			httpError(w, "Invalid plan", http.StatusBadRequest)
			return
		}
	}

	// Validate model
	var model *Model
	for i := range models {
		if models[i].ID == req.Model {
			model = &models[i]
			break
		}
	}
	if model == nil {
		httpError(w, "Invalid model", http.StatusBadRequest)
		return
	}

	// Generate order ID
	orderID := generateID()

	// Calculate total (VPS + margin + setup fee; BYOM = setup fee only)
	var totalSats int64
	if isBYOM {
		totalSats = s.cfg.SetupFeeSats
	} else {
		vpsSats := int64(float64(plan.SatsMo) * (1 + s.cfg.MarginPercent/100))
		totalSats = vpsSats + s.cfg.SetupFeeSats
	}

	order := &Order{
		ID:         orderID,
		State:      "pending_setup",
		Plan:       req.Plan,
		Model:      req.Model,
		Pubkey:     req.Pubkey,
		AmountSats: totalSats,
		IsBYOM:     isBYOM,
	}

	if err := CreateOrder(s.db, order); err != nil {
		log.Printf("Failed to create order: %v", err)
		httpError(w, "Internal error", http.StatusInternalServerError)
		return
	}

	// Hold secrets in memory for provisioning — NEVER persisted to DB or logs
	secrets := &PendingSecrets{
		Nsec:      req.Nsec,
		Npub:      req.Npub,
		PPQAPIKey: req.PPQAPIKey,
		SSHPubKey: req.SSHPubKey,
		BYOM:      req.BYOM,
		OwnerNpub: req.OwnerNpub,
	}
	s.mu.Lock()
	s.pending[orderID] = secrets
	s.mu.Unlock()

	mode := "lnvps"
	if req.BYOM != nil {
		mode = "byom:" + req.BYOM.Host
	}
	pubPrefix := req.Pubkey
	if len(pubPrefix) > 16 {
		pubPrefix = pubPrefix[:16]
	}
	log.Printf("Order %s: mode=%s, pubkey=%s..., has_nsec=%v, has_ppq=%v, has_ssh=%v",
		orderID, mode, pubPrefix, req.Nsec != "", req.PPQAPIKey != "", req.SSHPubKey != "")

	// Create Lightning invoice via LNbits
	memo := fmt.Sprintf("SSOP: %s + %s", plan.Name, model.Name)
	invoice, err := s.lnbits.CreateInvoice(totalSats, memo)
	if err != nil {
		log.Printf("Order %s: LNbits invoice error: %v", orderID, err)
		httpError(w, "Failed to create Lightning invoice", http.StatusInternalServerError)
		return
	}

	// Store payment hash for tracking
	if err := UpdateOrderInvoice(s.db, orderID, invoice.PaymentHash, invoice.PaymentRequest); err != nil {
		log.Printf("Order %s: failed to store invoice: %v", orderID, err)
	}

	log.Printf("Order %s: invoice created for %d sats (hash: %s...)", orderID, totalSats, invoice.PaymentHash[:16])

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]any{
		"order_id":    orderID,
		"state":       order.State,
		"amount_sats": totalSats,
		"plan":        plan,
		"model":       model,
		"bolt11":      invoice.PaymentRequest,
		"payment_hash": invoice.PaymentHash,
	})
}

// HandleGetOrder returns the status of an order
func (s *Server) HandleGetOrder(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		httpError(w, "Missing order ID", http.StatusBadRequest)
		return
	}

	order, err := GetOrder(s.db, id)
	if err == sql.ErrNoRows {
		httpError(w, "Order not found", http.StatusNotFound)
		return
	}
	if err != nil {
		log.Printf("Failed to get order: %v", err)
		httpError(w, "Internal error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(order)
}

// HandleCheckPayment checks if an order's invoice has been paid
func (s *Server) HandleCheckPayment(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		httpError(w, "Missing order ID", http.StatusBadRequest)
		return
	}

	order, err := GetOrder(s.db, id)
	if err == sql.ErrNoRows {
		httpError(w, "Order not found", http.StatusNotFound)
		return
	}
	if err != nil {
		httpError(w, "Internal error", http.StatusInternalServerError)
		return
	}

	// Already paid?
	if order.SetupPaid {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"paid": true, "state": order.State})
		return
	}

	// No invoice yet
	if order.SetupInvoice == "" {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"paid": false, "state": order.State})
		return
	}

	// Check with LNbits
	status, err := s.lnbits.CheckPayment(order.SetupInvoice)
	if err != nil {
		log.Printf("Order %s: payment check error: %v", id, err)
		httpError(w, "Payment check failed", http.StatusInternalServerError)
		return
	}

	if status.Paid {
		// Mark as paid
		if err := UpdateOrderPaid(s.db, id); err != nil {
			log.Printf("Order %s: failed to mark paid: %v", id, err)
		}
		log.Printf("Order %s: payment confirmed! Triggering provisioning...", id)
		go s.ProvisionOrder(id)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"paid": status.Paid, "state": order.State})
}

// skillMD is the canonical SKILL.md content served at /api and also at frontend/SKILL.md
const skillMD = `---
name: ssop
version: 0.1.0
description: Deploy a self-sovereign AI agent on your own VPS. Pay with Lightning. No KYC. No cloud accounts.
homepage: https://ssop.pages.dev
metadata: {"category": "infrastructure", "api_base": "https://185-18-221-5.sslip.io"}
---

# SSOP — Self Sovereign OpenClaw Platform

Deploy your own AI agent on dedicated infrastructure. Pay with Lightning. Own your keys.

**Frontend:** https://ssop.pages.dev
**API:** https://185-18-221-5.sslip.io
**SKILL.md:** https://ssop.pages.dev/SKILL.md

## What You Get

Each deployed agent receives:
- Dedicated KVM VPS on LNVPS (https://lnvps.net) (or your own machine)
- Nostr keypair (agent identity)
- Lightning address via npub.cash (https://npub.cash)
- Pre-configured OpenClaw (https://docs.openclaw.ai) gateway
- LLM inference via ppq.ai (https://ppq.ai)

## Quick Start (for agents)

You need: a Nostr keypair, a Lightning wallet, and HTTP access.

### 1. Check available plans and models

    curl https://185-18-221-5.sslip.io/api/plans
    curl https://185-18-221-5.sslip.io/api/models

### 2. Create an order

    curl -X POST https://185-18-221-5.sslip.io/api/order \
      -H "Content-Type: application/json" \
      -d '{
        "pubkey": "<your_nostr_hex_pubkey>",
        "plan": "small",
        "model": "kimi-k2",
        "nsec": "<nsec1...>"
      }'

Response:

    {
      "order_id": "abc123...",
      "bolt11": "lnbc...",
      "amount_sats": 5140,
      "payment_hash": "def456..."
    }

### 3. Pay the Lightning invoice

Pay the bolt11 with any Lightning wallet. Then poll for confirmation:

    curl https://185-18-221-5.sslip.io/api/order/<order_id>/check
    # -> {"paid": true, "state": "provisioning"}

### 4. Wait for provisioning

Poll order status until state is "ready":

    curl https://185-18-221-5.sslip.io/api/order/<order_id>

When ready, your agent has SSH access, OpenClaw running, Nostr DMs, and ppq.ai configured.

## API Reference

Base URL: https://185-18-221-5.sslip.io

GET  /api/plans            List VPS plans
GET  /api/models           List AI models
POST /api/order            Create deployment order (returns bolt11 invoice)
GET  /api/order/{id}       Get order status
GET  /api/order/{id}/check Check payment status
GET  /api                  This documentation (SKILL.md)
GET  /health               Health check

### POST /api/order

    {
      "pubkey": "hex nostr pubkey (required)",
      "plan": "small|medium|large|byom (required)",
      "model": "claude-opus-4-5|claude-3-7-sonnet|kimi-k2 (required)",
      "nsec": "nsec1... (required — held in memory only, never stored)",
      "byom": {"host": "1.2.3.4", "user": "root", "port": 22},
      "ppq_api_key": "your own ppq.ai key (optional)",
      "ssh_pub_key": "ssh-ed25519 AAAA... (optional)"
    }

## Plans

small:  2 vCPU, 2 GB,  80 GB SSD — 8,400 sats/mo (~$6.05)
medium: 4 vCPU, 4 GB, 160 GB SSD — 16,800 sats/mo (~$11.74)
large:  8 vCPU, 8 GB, 400 GB SSD — 33,600 sats/mo (~$25.99)
byom:   bring your own machine    — 100 sats (setup fee only)

## Models (via ppq.ai)

claude-opus-4-5:    $5.00/$25.00 per 1M tokens — most capable
claude-3-7-sonnet:  $3.00/$15.00 per 1M tokens — recommended
kimi-k2:            $0.39/$1.90  per 1M tokens — best agentic

Cheapest agent: Small + Kimi K2 ~ 8,930 sats/mo (~$6.44)

## BYOM (Bring Your Own Machine)

Set plan to "byom" and include byom config. Cost: 100 sats setup fee only. We SSH in and bootstrap OpenClaw.

## Security

- nsec is held in memory only during provisioning — never persisted to database or logs
- Only the pubkey prefix is logged for debugging
- All communication over HTTPS

## After Deployment

Your agent runs OpenClaw with Nostr DMs enabled.
- Nostr DM: Message the agent's npub from any Nostr client
- SSH: Log in and customize SOUL.md, add skills, configure channels
- Telegram: Set up a bot token in OpenClaw config

Built with Lightning by SSOP — Nostr, Lightning, LNVPS, OpenClaw, ppq.ai
`

// HandleAPIDocs returns the SKILL.md content as agent-friendly API documentation
func (s *Server) HandleAPIDocs(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/markdown; charset=utf-8")
	fmt.Fprint(w, skillMD)
}

func httpError(w http.ResponseWriter, msg string, code int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func generateID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}
