package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// BootstrapConfig is the config.json sent to the target machine
type BootstrapConfig struct {
	Nsec           string `json:"nsec"`
	Npub           string `json:"npub"`
	ModelID        string `json:"model_id"`
	PPQAPIKey      string `json:"ppq_api_key"`
	AgentName      string `json:"agent_name"`
	OwnerNpub      string `json:"owner_npub,omitempty"`
	OwnerPubkeyHex string `json:"owner_pubkey_hex,omitempty"` // user's hex pubkey for USER.md
	PlanName       string `json:"plan_name,omitempty"`        // for IDENTITY.md
	ModelName      string `json:"model_name,omitempty"`       // for IDENTITY.md
	GatewayPort    int    `json:"gateway_port,omitempty"`     // unique port per agent (local mode)
	TargetUser     string `json:"target_user,omitempty"`      // system user for agent (local mode)
}

const localBasePort = 18790 // 18789 reserved for orchestrator

// ProvisionOrder runs the full bootstrap pipeline for a paid order.
// Called as a goroutine after payment is confirmed.
func (s *Server) ProvisionOrder(orderID string) {
	log.Printf("Order %s: === PROVISIONING START ===", orderID)

	if err := UpdateOrderState(s.db, orderID, "provisioning"); err != nil {
		log.Printf("Order %s: failed to set state: %v", orderID, err)
	}

	order, err := GetOrder(s.db, orderID)
	if err != nil {
		s.provisionError(orderID, fmt.Sprintf("failed to get order: %v", err))
		return
	}

	// Retrieve in-memory secrets
	s.mu.Lock()
	secrets, ok := s.pending[orderID]
	s.mu.Unlock()
	if !ok {
		s.provisionError(orderID, "no pending secrets found (server may have restarted during payment)")
		return
	}

	// --- Determine provisioning mode ---
	isLocal := order.Plan != "byom"
	var host, user string
	var port int

	if order.Plan == "byom" && secrets.BYOM != nil {
		host = secrets.BYOM.Host
		user = secrets.BYOM.User
		port = secrets.BYOM.Port
	} else if order.Plan == "byom" {
		s.provisionError(orderID, "BYOM config missing from request")
		return
	}
	// else: local provisioning (handled below)

	// --- Resolve model's ppq.ai model ID ---
	var ppqModelID string
	for _, m := range models {
		if m.ID == order.Model {
			ppqModelID = m.PPQModelID
			break
		}
	}
	if ppqModelID == "" {
		s.provisionError(orderID, fmt.Sprintf("unknown model ID: %s", order.Model))
		return
	}

	// --- Determine ppq.ai API key ---
	ppqKey := secrets.PPQAPIKey
	if ppqKey == "" {
		ppqKey = s.cfg.SharedPPQKey
	}
	if ppqKey == "" {
		s.provisionError(orderID, "no ppq.ai API key (user didn't provide one, no shared key configured)")
		return
	}

	// --- Resolve plan name ---
	planName := order.Plan
	for _, p := range plans {
		if p.ID == order.Plan {
			planName = p.Name
			break
		}
	}

	// --- Resolve model name ---
	var modelName string
	for _, m := range models {
		if m.ID == order.Model {
			modelName = m.Name
			break
		}
	}

	// --- Build bootstrap config ---
	bsCfg := BootstrapConfig{
		Nsec:           secrets.Nsec,
		Npub:           secrets.Npub,
		ModelID:        ppqModelID,
		PPQAPIKey:      ppqKey,
		AgentName:      "Agent",
		OwnerNpub:      secrets.OwnerNpub,
		OwnerPubkeyHex: order.Pubkey,    // user's hex pubkey for USER.md
		PlanName:       planName,
		ModelName:      modelName,
	}

	// --- Allocate gateway port for local provisioning ---
	var gatewayPort int
	if isLocal {
		gwPort, err := AllocateNextPort(s.db, localBasePort)
		if err != nil {
			s.provisionError(orderID, fmt.Sprintf("port allocation: %v", err))
			return
		}
		gatewayPort = gwPort
		bsCfg.GatewayPort = gatewayPort

		// Create a unique agent user for this order
		agentUser := "agent-" + orderID[:8]
		bsCfg.TargetUser = agentUser
	}

	// Create temp directory for config
	tmpDir, err := os.MkdirTemp("", "ssop-provision-*")
	if err != nil {
		s.provisionError(orderID, fmt.Sprintf("temp dir: %v", err))
		return
	}
	defer func() {
		os.RemoveAll(tmpDir)
		log.Printf("Order %s: cleaned up temp dir", orderID)
	}()

	// Write config.json (contains secrets — will be deleted after)
	configPath := filepath.Join(tmpDir, "config.json")
	configBytes, _ := json.MarshalIndent(bsCfg, "", "  ")
	if err := os.WriteFile(configPath, configBytes, 0600); err != nil {
		s.provisionError(orderID, fmt.Sprintf("write config: %v", err))
		return
	}

	// Locate bootstrap script
	bootstrapPath := s.cfg.BootstrapPath
	if _, err := os.Stat(bootstrapPath); err != nil {
		s.provisionError(orderID, fmt.Sprintf("bootstrap.sh not found at %s", bootstrapPath))
		return
	}

	if isLocal {
		s.provisionLocal(orderID, configPath, bootstrapPath, bsCfg.TargetUser, gatewayPort)
	} else {
		s.provisionRemote(orderID, configPath, bootstrapPath, host, user, port, gatewayPort)
	}
}

// provisionLocal runs bootstrap.sh on the local machine for a dedicated agent user.
func (s *Server) provisionLocal(orderID, configPath, bootstrapPath, agentUser string, gatewayPort int) {
	// --- Step 1: Create agent system user ---
	log.Printf("Order %s: [1/4] Creating agent user %s...", orderID, agentUser)
	createCmd := exec.Command("sudo", "useradd", "-m", "-s", "/bin/bash", agentUser)
	if out, err := createCmd.CombinedOutput(); err != nil {
		// Ignore "already exists" error
		if !strings.Contains(string(out), "already exists") {
			s.provisionError(orderID, fmt.Sprintf("useradd %s: %v — %s", agentUser, err, trimOutput(out)))
			return
		}
	}
	// Enable systemd user lingering so services persist
	lingerCmd := exec.Command("sudo", "loginctl", "enable-linger", agentUser)
	lingerCmd.CombinedOutput() // best-effort
	log.Printf("Order %s: [1/4] User %s ready", orderID, agentUser)

	// --- Step 2: Copy config to temp location accessible by bootstrap ---
	log.Printf("Order %s: [2/4] Preparing bootstrap config...", orderID)
	tmpConfig := fmt.Sprintf("/tmp/ssop-config-%s.json", orderID[:8])
	cpCmd := exec.Command("sudo", "cp", configPath, tmpConfig)
	if out, err := cpCmd.CombinedOutput(); err != nil {
		s.provisionError(orderID, fmt.Sprintf("copy config: %v — %s", err, trimOutput(out)))
		return
	}
	defer func() {
		exec.Command("sudo", "rm", "-f", tmpConfig).CombinedOutput()
	}()

	// --- Step 3: Run bootstrap.sh locally ---
	log.Printf("Order %s: [3/4] Running bootstrap locally for user %s (port %d)...", orderID, agentUser, gatewayPort)
	runCmd := exec.Command("sudo", "bash", bootstrapPath, tmpConfig, "--mode=native")
	runCmd.Env = append(os.Environ(),
		fmt.Sprintf("SUDO_USER=%s", agentUser),
	)
	runOut, err := runCmd.CombinedOutput()
	output := string(runOut)

	logOutput := output
	if len(logOutput) > 3000 {
		logOutput = "...\n" + logOutput[len(logOutput)-3000:]
	}
	log.Printf("Order %s: [3/4] bootstrap output:\n%s", orderID, logOutput)

	if err != nil {
		s.provisionError(orderID, fmt.Sprintf("local bootstrap failed: %v", err))
		return
	}

	// --- Step 4: Health check ---
	log.Printf("Order %s: [4/4] Checking health on port %d...", orderID, gatewayPort)
	healthURL := fmt.Sprintf("http://127.0.0.1:%d/health", gatewayPort)
	healthy := false
	for i := 0; i < 20; i++ {
		client := &http.Client{Timeout: 5 * time.Second}
		resp, err := client.Get(healthURL)
		if err == nil && resp.StatusCode == 200 {
			resp.Body.Close()
			healthy = true
			break
		}
		if resp != nil {
			resp.Body.Close()
		}
		time.Sleep(3 * time.Second)
	}

	if !healthy {
		s.provisionError(orderID, fmt.Sprintf("agent gateway not healthy on port %d after 60s — check journalctl --user -u openclaw-gateway for user %s", gatewayPort, agentUser))
		return
	}

	// --- Success ---
	localIP := "185.18.221.5"
	sshAccess := fmt.Sprintf("ssh %s@%s", agentUser, localIP)
	if err := UpdateOrderVM(s.db, orderID, 0, localIP, sshAccess, gatewayPort); err != nil {
		log.Printf("Order %s: failed to update order: %v", orderID, err)
	}

	s.mu.Lock()
	delete(s.pending, orderID)
	s.mu.Unlock()

	log.Printf("Order %s: === PROVISIONING COMPLETE === Agent live at %s:%d (user: %s)", orderID, localIP, gatewayPort, agentUser)
}

// provisionRemote runs the SSH-based bootstrap pipeline for BYOM orders.
func (s *Server) provisionRemote(orderID, configPath, bootstrapPath, host, user string, port, gatewayPort int) {
	if port == 0 {
		port = 22
	}
	if user == "" {
		user = "root"
	}

	target := fmt.Sprintf("%s@%s", user, host)
	portStr := fmt.Sprintf("%d", port)
	sshOpts := []string{
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "ConnectTimeout=30",
		"-o", "LogLevel=ERROR",
		"-p", portStr,
	}

	// --- Step 1: Test SSH connectivity ---
	log.Printf("Order %s: [1/5] Testing SSH to %s:%d...", orderID, host, port)
	testCmd := exec.Command("ssh", append(sshOpts, target, "echo", "SSOP_OK")...)
	testOut, err := testCmd.CombinedOutput()
	if err != nil {
		s.provisionError(orderID, fmt.Sprintf("SSH connection failed: %v — %s", err, trimOutput(testOut)))
		return
	}
	if !strings.Contains(string(testOut), "SSOP_OK") {
		s.provisionError(orderID, fmt.Sprintf("SSH test unexpected output: %s", trimOutput(testOut)))
		return
	}
	log.Printf("Order %s: [1/5] SSH OK", orderID)

	// --- Step 2: Upload config.json ---
	log.Printf("Order %s: [2/5] Uploading config.json...", orderID)
	if err := scpFile(configPath, target+":/tmp/ssop-config.json", portStr); err != nil {
		s.provisionError(orderID, fmt.Sprintf("SCP config: %v", err))
		return
	}

	// --- Step 3: Upload bootstrap.sh ---
	log.Printf("Order %s: [3/5] Uploading bootstrap.sh...", orderID)
	if err := scpFile(bootstrapPath, target+":/tmp/ssop-bootstrap.sh", portStr); err != nil {
		s.provisionError(orderID, fmt.Sprintf("SCP bootstrap: %v", err))
		return
	}

	// --- Step 4: Execute bootstrap ---
	log.Printf("Order %s: [4/5] Running bootstrap (may take several minutes)...", orderID)
	runCmd := exec.Command("ssh", append(sshOpts, target, "sudo", "bash", "/tmp/ssop-bootstrap.sh", "/tmp/ssop-config.json")...)
	runOut, err := runCmd.CombinedOutput()
	output := string(runOut)

	logOutput := output
	if len(logOutput) > 3000 {
		logOutput = "...\n" + logOutput[len(logOutput)-3000:]
	}
	log.Printf("Order %s: [4/5] bootstrap output:\n%s", orderID, logOutput)

	if err != nil {
		s.provisionError(orderID, fmt.Sprintf("bootstrap exited with error: %v", err))
		return
	}

	// --- Step 5: Clean up secrets on target, then poll health ---
	log.Printf("Order %s: [5/5] Cleaning up secrets and checking health...", orderID)
	cleanCmd := exec.Command("ssh", append(sshOpts, target, "rm", "-f", "/tmp/ssop-config.json", "/tmp/ssop-bootstrap.sh")...)
	cleanCmd.CombinedOutput() // best-effort

	healthURL := fmt.Sprintf("http://%s:18789/health", host)
	healthy := false
	for i := 0; i < 20; i++ {
		client := &http.Client{Timeout: 5 * time.Second}
		resp, err := client.Get(healthURL)
		if err == nil && resp.StatusCode == 200 {
			resp.Body.Close()
			healthy = true
			break
		}
		if resp != nil {
			resp.Body.Close()
		}
		time.Sleep(3 * time.Second)
	}

	if !healthy {
		s.provisionError(orderID, "agent gateway not healthy after 60s — check journalctl -u openclaw-gateway on the target")
		return
	}

	// --- Success! ---
	sshAccess := fmt.Sprintf("ssh %s@%s", user, host)
	if port != 22 {
		sshAccess = fmt.Sprintf("ssh %s@%s -p %d", user, host, port)
	}
	if err := UpdateOrderVM(s.db, orderID, 0, host, sshAccess, 18789); err != nil {
		log.Printf("Order %s: failed to update order: %v", orderID, err)
	}

	// Clear secrets from memory
	s.mu.Lock()
	delete(s.pending, orderID)
	s.mu.Unlock()

	log.Printf("Order %s: === PROVISIONING COMPLETE === Agent live at %s", orderID, host)
}

func scpFile(src, dst, port string) error {
	cmd := exec.Command("scp",
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "LogLevel=ERROR",
		"-P", port,
		src, dst,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, trimOutput(out))
	}
	return nil
}

func (s *Server) provisionError(orderID, msg string) {
	log.Printf("Order %s: ❌ %s", orderID, msg)
	UpdateOrderState(s.db, orderID, "error")
	s.db.Exec(`UPDATE orders SET error_msg = ? WHERE id = ?`, msg, orderID)
	s.mu.Lock()
	delete(s.pending, orderID)
	s.mu.Unlock()
}

func trimOutput(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 500 {
		return s[len(s)-500:]
	}
	return s
}
