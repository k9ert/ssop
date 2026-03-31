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
	Port           int     `json:"port"`
	DBPath         string  `json:"db_path"`
	LNVPSBaseURL   string  `json:"lnvps_base_url"`
	NostrNsec      string  `json:"-"` // loaded from env, never serialized
	SetupFeeSats   int64   `json:"setup_fee_sats"`
	MarginPercent  float64 `json:"margin_percent"`
	LNbitsURL      string  `json:"lnbits_url"`
	LNbitsKey      string  `json:"-"` // invoice key, loaded from env
	SharedPPQKey   string  `json:"-"` // shared ppq.ai key for agents without their own
	BootstrapPath  string  `json:"bootstrap_path"`
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
		LNbitsURL:     getEnv("LNBITS_URL", "https://legend.lnbits.com"),
		LNbitsKey:     os.Getenv("LNBITS_KEY"),
		SharedPPQKey:  os.Getenv("SHARED_PPQ_KEY"),
		BootstrapPath: getEnv("BOOTSTRAP_PATH", "/opt/ssop/bootstrap.sh"),
	}

	if cfg.NostrNsec == "" {
		log.Fatal("NOSTR_NSEC environment variable is required")
	}
	if cfg.LNbitsKey == "" {
		log.Fatal("LNBITS_KEY environment variable is required (invoice key for SSOP wallet)")
	}
	if cfg.SharedPPQKey == "" {
		log.Println("WARNING: SHARED_PPQ_KEY not set — agents must provide their own ppq.ai key")
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
	mux.HandleFunc("GET /api/order/{id}/check", srv.HandleCheckPayment)
	// TODO: WebSocket endpoint for real-time status
	// mux.HandleFunc("GET /api/ws/{id}", srv.HandleWebSocket)

	// Agent-friendly docs
	mux.HandleFunc("GET /api", srv.HandleAPIDocs)

	// Health check
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]string{
			"status": "ok",
			"time":   time.Now().UTC().Format(time.RFC3339),
		})
	})

	// CORS preflight
	mux.HandleFunc("OPTIONS /", func(w http.ResponseWriter, r *http.Request) {
		setCORS(w)
		w.WriteHeader(http.StatusNoContent)
	})

	addr := fmt.Sprintf(":%d", cfg.Port)
	log.Printf("SSOP Orchestrator starting on %s", addr)
	log.Fatal(http.ListenAndServe(addr, corsMiddleware(mux)))
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func setCORS(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		setCORS(w)
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
