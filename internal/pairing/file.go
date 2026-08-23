// Package pairing defines the portable PendingNet VPS pairing file.
//
// A pairing file bootstraps trust with PendingNet Server. It deliberately does
// not contain proxy protocols, routing rules, or a generated sing-box config.
package pairing

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	Format  = "pendingnet-pairing"
	Version = 1

	// URLScheme and URLHost form the fixed prefix of a pairing link:
	// pendingnet://pair?v=1&d=<base64url payload>.
	URLScheme = "pendingnet"
	URLHost   = "pair"
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

// URL renders the pairing document as a single pendingnet:// pairing link.
//
// The whole *.pdn JSON document is base64url-encoded (no padding) into one "d"
// parameter instead of being spread over query fields. A client base64-decodes
// it and hands the bytes straight to Parse, so a second transport shape does
// not mean a second parser — and no field can drift between the two.
func (f File) URL(now time.Time) (string, error) {
	if err := f.Validate(now); err != nil {
		return "", err
	}
	payload, err := json.Marshal(f)
	if err != nil {
		return "", fmt.Errorf("encode pairing link: %w", err)
	}
	// Built by hand rather than with url.Values.Encode: the base64url alphabet
	// needs no escaping, and this keeps v before d as documented.
	return fmt.Sprintf("%s://%s?v=%d&d=%s",
		URLScheme, URLHost, Version, base64.RawURLEncoding.EncodeToString(payload)), nil
}

// ParseURL decodes a pendingnet:// pairing link and validates the document it
// carries. Surrounding whitespace is tolerated because links arrive pasted.
func ParseURL(raw string, now time.Time) (File, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return File{}, fmt.Errorf("parse pairing link: %w", err)
	}
	if !strings.EqualFold(u.Scheme, URLScheme) {
		return File{}, fmt.Errorf("not a %s:// pairing link", URLScheme)
	}
	if !strings.EqualFold(u.Host, URLHost) || (u.Path != "" && u.Path != "/") {
		return File{}, fmt.Errorf("pairing link must be %s://%s", URLScheme, URLHost)
	}
	query, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return File{}, fmt.Errorf("parse pairing link: %w", err)
	}
	for key, values := range query {
		if key != "v" && key != "d" {
			return File{}, fmt.Errorf("pairing link has unknown parameter %q", key)
		}
		if len(values) != 1 {
			return File{}, fmt.Errorf("pairing link repeats parameter %q", key)
		}
	}
	if version := query.Get("v"); version != strconv.Itoa(Version) {
		return File{}, fmt.Errorf("unsupported pairing link version %q", version)
	}
	// Padding is not emitted, but a link that picked some up on the way stays
	// readable: the payload itself is what has to be exact, not its padding.
	payload, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(query.Get("d"), "="))
	if err != nil {
		return File{}, fmt.Errorf("pairing link payload is not base64url: %w", err)
	}
	return Parse(payload, now)
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
