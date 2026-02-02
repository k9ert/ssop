package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
)

// Server holds the application state
type Server struct {
	cfg Config
	db  *sql.DB
}

// NewServer creates a new server instance
func NewServer(cfg Config, db *sql.DB) *Server {
	return &Server{cfg: cfg, db: db}
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
	{ID: "tiny", Name: "Tiny", CPU: 1, RAM: "1 GB", Disk: "40 GB SSD", SatsMo: 4200, FiatMo: "~$3.20", LNVPSTemplate: 1},
	{ID: "small", Name: "Small", CPU: 2, RAM: "2 GB", Disk: "80 GB SSD", SatsMo: 8400, FiatMo: "~$6.05", LNVPSTemplate: 2},
	{ID: "medium", Name: "Medium", CPU: 4, RAM: "4 GB", Disk: "160 GB SSD", SatsMo: 16800, FiatMo: "~$11.74", LNVPSTemplate: 3},
	{ID: "large", Name: "Large", CPU: 8, RAM: "8 GB", Disk: "400 GB SSD", SatsMo: 33600, FiatMo: "~$25.99", LNVPSTemplate: 4},
}

var models = []Model{
	{ID: "claude-opus-4-5", Name: "Claude Opus 4.5", Provider: "Anthropic", Description: "Most capable", InputPer1M: 5.0, OutputPer1M: 25.0, Context: "200K", PPQModelID: "claude-opus-4.5"},
	{ID: "claude-3-7-sonnet", Name: "Claude 3.7 Sonnet", Provider: "Anthropic", Description: "Balanced, recommended", InputPer1M: 3.0, OutputPer1M: 15.0, Context: "200K", PPQModelID: "anthropic/claude-3.7-sonnet"},
	{ID: "kimi-k2", Name: "Kimi K2 Instruct", Provider: "Moonshot AI", Description: "Best for agentic tasks", InputPer1M: 0.39, OutputPer1M: 1.90, Context: "256K", PPQModelID: "moonshotai/kimi-k2-0905"},
	{ID: "qwen3-30b-a3b", Name: "Qwen3-30B-A3B", Provider: "Alibaba", Description: "Cheapest, fast", InputPer1M: 0.08, OutputPer1M: 0.33, Context: "262K", PPQModelID: "qwen/qwen3-30b-a3b-instruct-2507"},
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

// CreateOrderRequest is the request body for creating an order
type CreateOrderRequest struct {
	Pubkey string `json:"pubkey"`
	Plan   string `json:"plan"`
	Model  string `json:"model"`
}

// HandleCreateOrder creates a new deployment order
func (s *Server) HandleCreateOrder(w http.ResponseWriter, r *http.Request) {
	var req CreateOrderRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	// Validate plan
	var plan *Plan
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

	// Calculate total (VPS + margin + setup fee)
	vpsSats := int64(float64(plan.SatsMo) * (1 + s.cfg.MarginPercent/100))
	totalSats := vpsSats + s.cfg.SetupFeeSats

	order := &Order{
		ID:         orderID,
		State:      "pending_setup",
		Plan:       req.Plan,
		Model:      req.Model,
		Pubkey:     req.Pubkey,
		AmountSats: totalSats,
	}

	if err := CreateOrder(s.db, order); err != nil {
		log.Printf("Failed to create order: %v", err)
		httpError(w, "Internal error", http.StatusInternalServerError)
		return
	}

	// TODO: Generate Lightning invoice for setup fee
	// TODO: Return invoice in response

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]any{
		"order_id":    orderID,
		"state":       order.State,
		"amount_sats": totalSats,
		"plan":        plan,
		"model":       model,
		// "invoice": setupInvoice,
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
