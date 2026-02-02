package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

// Config holds server configuration
type Config struct {
	Port           int    `json:"port"`
	DBPath         string `json:"db_path"`
	LNVPSBaseURL   string `json:"lnvps_base_url"`
	NostrNsec      string `json:"-"` // loaded from env, never serialized
	SetupFeeSats   int64  `json:"setup_fee_sats"`
	MarginPercent  float64 `json:"margin_percent"`
}

func main() {
	port := flag.Int("port", 8080, "Server port")
	dbPath := flag.String("db", "ssop.db", "SQLite database path")
	flag.Parse()

	cfg := Config{
		Port:          *port,
		DBPath:        *dbPath,
		LNVPSBaseURL:  getEnv("LNVPS_API_URL", "https://api.lnvps.net/api/v1"),
		NostrNsec:     os.Getenv("NOSTR_NSEC"),
		SetupFeeSats:  100,
		MarginPercent: 20.0,
	}

	if cfg.NostrNsec == "" {
		log.Fatal("NOSTR_NSEC environment variable is required")
	}

	// Initialize database
	db, err := InitDB(cfg.DBPath)
	if err != nil {
		log.Fatalf("Failed to initialize database: %v", err)
	}
	defer db.Close()

	// Create server
	srv := NewServer(cfg, db)

	// Routes
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/plans", srv.HandleGetPlans)
	mux.HandleFunc("GET /api/models", srv.HandleGetModels)
	mux.HandleFunc("POST /api/order", srv.HandleCreateOrder)
	mux.HandleFunc("GET /api/order/{id}", srv.HandleGetOrder)
	// TODO: WebSocket endpoint for real-time status
	// mux.HandleFunc("GET /api/ws/{id}", srv.HandleWebSocket)

	// Health check
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]string{
			"status": "ok",
			"time":   time.Now().UTC().Format(time.RFC3339),
		})
	})

	addr := fmt.Sprintf(":%d", cfg.Port)
	log.Printf("SSOP Orchestrator starting on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
