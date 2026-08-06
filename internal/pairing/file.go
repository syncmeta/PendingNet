// Package pairing defines the portable PendingNet VPS pairing file.
//
// A pairing file bootstraps trust with PendingNet Server. It deliberately does
// not contain proxy protocols, routing rules, or a generated sing-box config.
package pairing

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strings"
	"time"
)

const (
	Format  = "pendingnet-pairing"
	Version = 1
)

// File is the versioned on-disk *.pdn pairing document.
type File struct {
	Format     string     `json:"format"`
	Version    int        `json:"version"`
	ServerID   string     `json:"server_id"`
	Name       string     `json:"name"`
	Control    Control    `json:"control"`
	Enrollment Enrollment `json:"enrollment"`
}

// Control identifies and pins the PendingNet Server control endpoint.
type Control struct {
	Endpoint          string `json:"endpoint"`
	CertificateSHA256 string `json:"certificate_sha256"`
}

// Enrollment contains a short-lived, single-use bootstrap token.
type Enrollment struct {
	Token     string    `json:"token"`
	ExpiresAt time.Time `json:"expires_at"`
}

// Parse decodes a pairing document, rejects unknown fields, and validates it.
func Parse(data []byte, now time.Time) (File, error) {
	var f File
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&f); err != nil {
		return File{}, fmt.Errorf("decode pairing file: %w", err)
	}
	var trailing any
	if err := dec.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return File{}, errors.New("decode pairing file: trailing JSON value")
		}
		return File{}, fmt.Errorf("decode pairing file: %w", err)
	}
	if err := f.Validate(now); err != nil {
		return File{}, err
	}
	return f, nil
}

// Marshal validates then emits a stable, human-inspectable JSON document.
func (f File) Marshal(now time.Time) ([]byte, error) {
	if err := f.Validate(now); err != nil {
		return nil, err
	}
	return json.MarshalIndent(f, "", "  ")
}

// Validate enforces the v1 trust and expiry invariants.
func (f File) Validate(now time.Time) error {
	if f.Format != Format {
		return fmt.Errorf("unsupported pairing format %q", f.Format)
	}
	if f.Version != Version {
		return fmt.Errorf("unsupported pairing version %d", f.Version)
	}
	if strings.TrimSpace(f.ServerID) == "" {
		return errors.New("pairing file has no server_id")
	}
	if strings.TrimSpace(f.Name) == "" {
		return errors.New("pairing file has no name")
	}
	endpoint, err := url.Parse(f.Control.Endpoint)
	if err != nil || endpoint.Scheme != "https" || endpoint.Host == "" {
		return errors.New("control endpoint must be an absolute https URL")
	}
	if endpoint.User != nil || endpoint.RawQuery != "" || endpoint.Fragment != "" || (endpoint.Path != "" && endpoint.Path != "/") {
		return errors.New("control endpoint must not contain credentials, path, query, or fragment")
	}
	if !validFingerprint(f.Control.CertificateSHA256) {
		return errors.New("certificate_sha256 must be sha256 followed by 64 hexadecimal characters")
	}
	if len(f.Enrollment.Token) < 32 {
		return errors.New("enrollment token is too short")
	}
	if f.Enrollment.ExpiresAt.IsZero() {
		return errors.New("enrollment expiry is missing")
	}
	if !now.Before(f.Enrollment.ExpiresAt) {
		return errors.New("pairing file has expired")
	}
	return nil
}

func validFingerprint(value string) bool {
	prefix, raw, ok := strings.Cut(value, ":")
	if !ok || strings.ToLower(prefix) != "sha256" || len(raw) != 64 {
		return false
	}
	_, err := hex.DecodeString(raw)
	return err == nil
}
