package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// LNbitsClient handles Lightning invoice creation and payment checking
type LNbitsClient struct {
	baseURL string
	apiKey  string // invoice key (read + create invoices)
	client  *http.Client
}

// NewLNbitsClient creates a new LNbits API client
func NewLNbitsClient(baseURL, apiKey string) *LNbitsClient {
	return &LNbitsClient{
		baseURL: baseURL,
		apiKey:  apiKey,
		client:  &http.Client{Timeout: 15 * time.Second},
	}
}

// CreateInvoiceRequest is the request to create a Lightning invoice
type CreateInvoiceRequest struct {
	Out    bool   `json:"out"`
	Amount int64  `json:"amount"` // in sats
	Memo   string `json:"memo"`
}

// CreateInvoiceResponse is the LNbits response for invoice creation
type CreateInvoiceResponse struct {
	PaymentHash    string `json:"payment_hash"`
	PaymentRequest string `json:"payment_request"` // bolt11
	CheckingID     string `json:"checking_id"`
}

// PaymentStatus is the LNbits response for payment status check
type PaymentStatus struct {
	Paid   bool   `json:"paid"`
	Status string `json:"status"`
}

// CreateInvoice generates a Lightning invoice via LNbits
func (c *LNbitsClient) CreateInvoice(amountSats int64, memo string) (*CreateInvoiceResponse, error) {
	body, _ := json.Marshal(CreateInvoiceRequest{
		Out:    false,
		Amount: amountSats,
		Memo:   memo,
	})

	req, err := http.NewRequest("POST", c.baseURL+"/api/v1/payments", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Api-Key", c.apiKey)

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("lnbits request: %w", err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 201 && resp.StatusCode != 200 {
		return nil, fmt.Errorf("lnbits error %d: %s", resp.StatusCode, string(respBody))
	}

	var result CreateInvoiceResponse
	if err := json.Unmarshal(respBody, &result); err != nil {
		return nil, fmt.Errorf("parse response: %w", err)
	}
	return &result, nil
}

// CheckPayment checks if a payment has been received
func (c *LNbitsClient) CheckPayment(paymentHash string) (*PaymentStatus, error) {
	req, err := http.NewRequest("GET", c.baseURL+"/api/v1/payments/"+paymentHash, nil)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("X-Api-Key", c.apiKey)

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("lnbits request: %w", err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("lnbits error %d: %s", resp.StatusCode, string(respBody))
	}

	var result PaymentStatus
	if err := json.Unmarshal(respBody, &result); err != nil {
		return nil, fmt.Errorf("parse response: %w", err)
	}
	return &result, nil
}

// WalletBalance returns the wallet balance in sats
type WalletInfo struct {
	Name    string `json:"name"`
	Balance int64  `json:"balance"` // in millisats
}

func (c *LNbitsClient) GetWallet() (*WalletInfo, error) {
	req, err := http.NewRequest("GET", c.baseURL+"/api/v1/wallet", nil)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("X-Api-Key", c.apiKey)

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("lnbits request: %w", err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("lnbits error %d: %s", resp.StatusCode, string(respBody))
	}

	var result WalletInfo
	if err := json.Unmarshal(respBody, &result); err != nil {
		return nil, fmt.Errorf("parse response: %w", err)
	}
	return &result, nil
}
