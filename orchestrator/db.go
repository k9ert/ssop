package main

import (
	"database/sql"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// Order represents an agent deployment order
type Order struct {
	ID        string    `json:"id"`
	CreatedAt time.Time `json:"created_at"`
	State     string    `json:"state"` // pending_setup, pending_payment, paid, provisioning, ready, error
	Plan      string    `json:"plan"`
	Model     string    `json:"model"`
	Pubkey    string    `json:"pubkey"`

	// Payment
	SetupInvoice string `json:"setup_invoice,omitempty"`
	SetupPaid    bool   `json:"setup_paid"`
	MainInvoice  string `json:"main_invoice,omitempty"`
	MainPaid     bool   `json:"main_paid"`
	AmountSats   int64  `json:"amount_sats"`

	// Provisioning
	VMID        int    `json:"vm_id,omitempty"`
	VMIP        string `json:"vm_ip,omitempty"`
	SSHAccess   string `json:"ssh_access,omitempty"`
	GatewayPort int    `json:"gateway_port,omitempty"`
	ErrorMsg    string `json:"error_msg,omitempty"`
	IsBYOM      bool   `json:"is_byom"`           // true if user provided their own machine
}

// InitDB creates the SQLite database and tables
func InitDB(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite3", path+"?_journal_mode=WAL")
	if err != nil {
		return nil, err
	}

	schema := `
	CREATE TABLE IF NOT EXISTS orders (
		id TEXT PRIMARY KEY,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		state TEXT NOT NULL DEFAULT 'pending_setup',
		plan TEXT NOT NULL,
		model TEXT NOT NULL,
		pubkey TEXT NOT NULL,
		setup_invoice TEXT,
		setup_paid BOOLEAN DEFAULT FALSE,
		main_invoice TEXT,
		main_paid BOOLEAN DEFAULT FALSE,
		amount_sats INTEGER DEFAULT 0,
		vm_id INTEGER,
		vm_ip TEXT,
		ssh_access TEXT,
		gateway_port INTEGER DEFAULT 0,
		error_msg TEXT
	);

	CREATE INDEX IF NOT EXISTS idx_orders_state ON orders(state);
	CREATE INDEX IF NOT EXISTS idx_orders_pubkey ON orders(pubkey);
	`

	_, err = db.Exec(schema)
	if err != nil {
		return nil, err
	}

	return db, nil
}

// CreateOrder inserts a new order
func CreateOrder(db *sql.DB, o *Order) error {
	_, err := db.Exec(
		`INSERT INTO orders (id, state, plan, model, pubkey, amount_sats)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		o.ID, o.State, o.Plan, o.Model, o.Pubkey, o.AmountSats,
	)
	return err
}

// GetOrder retrieves an order by ID
func GetOrder(db *sql.DB, id string) (*Order, error) {
	o := &Order{}
	err := db.QueryRow(
		`SELECT id, created_at, state, plan, model, pubkey,
		        COALESCE(setup_invoice,''), setup_paid,
		        COALESCE(main_invoice,''), main_paid, amount_sats,
		        COALESCE(vm_id,0), COALESCE(vm_ip,''),
		        COALESCE(ssh_access,''), COALESCE(gateway_port,0),
		        COALESCE(error_msg,'')
		 FROM orders WHERE id = ?`, id,
	).Scan(
		&o.ID, &o.CreatedAt, &o.State, &o.Plan, &o.Model, &o.Pubkey,
		&o.SetupInvoice, &o.SetupPaid,
		&o.MainInvoice, &o.MainPaid, &o.AmountSats,
		&o.VMID, &o.VMIP, &o.SSHAccess, &o.GatewayPort, &o.ErrorMsg,
	)
	if err != nil {
		return nil, err
	}
	return o, nil
}

// UpdateOrderState updates the state of an order
func UpdateOrderState(db *sql.DB, id, state string) error {
	_, err := db.Exec(`UPDATE orders SET state = ? WHERE id = ?`, state, id)
	return err
}

// UpdateOrderInvoice stores the payment hash and bolt11 for an order
func UpdateOrderInvoice(db *sql.DB, id, paymentHash, bolt11 string) error {
	_, err := db.Exec(
		`UPDATE orders SET setup_invoice = ?, main_invoice = ? WHERE id = ?`,
		paymentHash, bolt11, id,
	)
	return err
}

// UpdateOrderPaid marks an order as paid
func UpdateOrderPaid(db *sql.DB, id string) error {
	_, err := db.Exec(
		`UPDATE orders SET setup_paid = TRUE, state = 'paid' WHERE id = ?`, id,
	)
	return err
}

// UpdateOrderVM updates the VM details of an order
func UpdateOrderVM(db *sql.DB, id string, vmID int, vmIP, sshAccess string, gatewayPort int) error {
	_, err := db.Exec(
		`UPDATE orders SET vm_id = ?, vm_ip = ?, ssh_access = ?, gateway_port = ?, state = 'ready' WHERE id = ?`,
		vmID, vmIP, sshAccess, gatewayPort, id,
	)
	return err
}

// AllocateNextPort finds the next available gateway port starting from basePort.
func AllocateNextPort(db *sql.DB, basePort int) (int, error) {
	var maxPort sql.NullInt64
	err := db.QueryRow(`SELECT MAX(gateway_port) FROM orders WHERE gateway_port > 0`).Scan(&maxPort)
	if err != nil {
		return 0, err
	}
	if maxPort.Valid && int(maxPort.Int64) >= basePort {
		return int(maxPort.Int64) + 1, nil
	}
	return basePort, nil
}
