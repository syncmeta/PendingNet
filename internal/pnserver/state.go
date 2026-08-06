// Package pnserver implements the PendingNet Server control-plane state and
// one-time pairing lifecycle.
package pnserver

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"sbtally/internal/pairing"
)

const stateVersion = 1

var (
	ErrAlreadyInitialized = errors.New("PendingNet Server is already initialized")
	ErrNotInitialized     = errors.New("PendingNet Server is not initialized")
	ErrInvalidPairing     = errors.New("pairing token is invalid, expired, or already used")
	ErrUnauthorized       = errors.New("device token is unauthorized")
)

// State is private server control-plane state. Secret tokens are only stored
// as SHA-256 hashes; raw enrollment and device tokens are returned once.
type State struct {
	Version           int            `json:"version"`
	ServerID          string         `json:"server_id"`
	Name              string         `json:"name"`
	ControlEndpoint   string         `json:"control_endpoint"`
	CertificateSHA256 string         `json:"certificate_sha256"`
	CreatedAt         time.Time      `json:"created_at"`
	Pairings          []PairingGrant `json:"pairings"`
	Devices           []Device       `json:"devices"`
}

type PairingGrant struct {
	ID          string     `json:"id"`
	TokenSHA256 string     `json:"token_sha256"`
	CreatedAt   time.Time  `json:"created_at"`
	ExpiresAt   time.Time  `json:"expires_at"`
	UsedAt      *time.Time `json:"used_at,omitempty"`
}

type Device struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	TokenSHA256 string    `json:"token_sha256"`
	CreatedAt   time.Time `json:"created_at"`
}

// DeviceCredential is returned once after a successful enrollment.
type DeviceCredential struct {
	DeviceID   string
	DeviceName string
	Token      string
}

// Store serializes state transitions and persists them atomically.
type Store struct {
	Dir  string
	Now  func() time.Time
	Rand io.Reader

	mu sync.Mutex
}

func NewStore(dir string) *Store {
	return &Store{Dir: dir, Now: time.Now, Rand: rand.Reader}
}

func (s *Store) statePath() string { return filepath.Join(s.Dir, "state.json") }
func (s *Store) certPath() string  { return filepath.Join(s.Dir, "control.crt") }
func (s *Store) keyPath() string   { return filepath.Join(s.Dir, "control.key") }

func (s *Store) CertificatePath() string { return s.certPath() }
func (s *Store) PrivateKeyPath() string  { return s.keyPath() }

// Initialize creates the private state and self-signed TLS identity used by
// the pinned control endpoint.
func (s *Store) Initialize(name, endpoint string) (State, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	name = strings.TrimSpace(name)
	if name == "" {
		return State{}, errors.New("server name is required")
	}
	u, err := validateControlEndpoint(endpoint)
	if err != nil {
		return State{}, err
	}
	if _, err := os.Stat(s.statePath()); err == nil {
		return State{}, ErrAlreadyInitialized
	} else if !errors.Is(err, os.ErrNotExist) {
		return State{}, err
	}
	if err := os.MkdirAll(s.Dir, 0o700); err != nil {
		return State{}, err
	}

	certPEM, keyPEM, fingerprint, err := generateTLSIdentity(s.randReader(), u.Hostname(), name, s.now())
	if err != nil {
		return State{}, err
	}
	if err := writeExclusive(s.certPath(), certPEM, 0o644); err != nil {
		return State{}, err
	}
	if err := writeExclusive(s.keyPath(), keyPEM, 0o600); err != nil {
		_ = os.Remove(s.certPath())
		return State{}, err
	}

	serverID, err := randomValue(s.randReader(), "pns_", 18)
	if err != nil {
		return State{}, err
	}
	state := State{
		Version:           stateVersion,
		ServerID:          serverID,
		Name:              name,
		ControlEndpoint:   strings.TrimSuffix(endpoint, "/"),
		CertificateSHA256: fingerprint,
		CreatedAt:         s.now(),
		Pairings:          []PairingGrant{},
		Devices:           []Device{},
	}
	if err := s.writeState(state); err != nil {
		_ = os.Remove(s.certPath())
		_ = os.Remove(s.keyPath())
		return State{}, err
	}
	return state, nil
}

// Load returns a validated copy of the current server state.
func (s *Store) Load() (State, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loadState()
}

// CreatePairing creates and persists a one-time grant, returning the only copy
// of its raw token in a portable pairing file.
func (s *Store) CreatePairing(ttl time.Duration) (pairing.File, error) {
	if ttl <= 0 || ttl > 24*time.Hour {
		return pairing.File{}, errors.New("pairing ttl must be greater than zero and at most 24h")
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	state, err := s.loadState()
	if err != nil {
		return pairing.File{}, err
	}
	now := s.now()
	token, err := randomValue(s.randReader(), "", 32)
	if err != nil {
		return pairing.File{}, err
	}
	grantID, err := randomValue(s.randReader(), "pair_", 12)
	if err != nil {
		return pairing.File{}, err
	}
	expires := now.Add(ttl)
	state.Pairings = append(state.Pairings, PairingGrant{
		ID: grantID, TokenSHA256: hashToken(token), CreatedAt: now, ExpiresAt: expires,
	})
	if err := s.writeState(state); err != nil {
		return pairing.File{}, err
	}
	return pairing.File{
		Format: pairing.Format, Version: pairing.Version,
		ServerID: state.ServerID, Name: state.Name,
		Control: pairing.Control{
			Endpoint: state.ControlEndpoint, CertificateSHA256: state.CertificateSHA256,
		},
		Enrollment: pairing.Enrollment{Token: token, ExpiresAt: expires},
	}, nil
}

// Enroll consumes a one-time pairing token and creates an independent device
// credential. A token can never be used twice, even for the same device.
func (s *Store) Enroll(token, deviceName string) (DeviceCredential, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, err := s.loadState()
	if err != nil {
		return DeviceCredential{}, err
	}
	deviceName = strings.TrimSpace(deviceName)
	if deviceName == "" || len(deviceName) > 128 {
		return DeviceCredential{}, errors.New("device name must be 1-128 characters")
	}
	now := s.now()
	wantHash := hashToken(token)
	match := -1
	for i := range state.Pairings {
		grant := state.Pairings[i]
		if secureEqual(grant.TokenSHA256, wantHash) && grant.UsedAt == nil && now.Before(grant.ExpiresAt) {
			match = i
		}
	}
	if match < 0 {
		return DeviceCredential{}, ErrInvalidPairing
	}

	deviceToken, err := randomValue(s.randReader(), "", 32)
	if err != nil {
		return DeviceCredential{}, err
	}
	deviceID, err := randomValue(s.randReader(), "dev_", 12)
	if err != nil {
		return DeviceCredential{}, err
	}
	state.Pairings[match].UsedAt = &now
	state.Devices = append(state.Devices, Device{
		ID: deviceID, Name: deviceName, TokenSHA256: hashToken(deviceToken), CreatedAt: now,
	})
	if err := s.writeState(state); err != nil {
		return DeviceCredential{}, err
	}
	return DeviceCredential{DeviceID: deviceID, DeviceName: deviceName, Token: deviceToken}, nil
}

// Authenticate verifies a previously issued device bearer token.
func (s *Store) Authenticate(token string) (Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, err := s.loadState()
	if err != nil {
		return Device{}, err
	}
	wantHash := hashToken(token)
	for _, device := range state.Devices {
		if secureEqual(device.TokenSHA256, wantHash) {
			return device, nil
		}
	}
	return Device{}, ErrUnauthorized
}

func (s *Store) loadState() (State, error) {
	b, err := os.ReadFile(s.statePath())
	if errors.Is(err, os.ErrNotExist) {
		return State{}, ErrNotInitialized
	}
	if err != nil {
		return State{}, err
	}
	var state State
	if err := json.Unmarshal(b, &state); err != nil {
		return State{}, fmt.Errorf("decode server state: %w", err)
	}
	if state.Version != stateVersion || state.ServerID == "" || state.ControlEndpoint == "" {
		return State{}, errors.New("server state is invalid or unsupported")
	}
	if state.Pairings == nil {
		state.Pairings = []PairingGrant{}
	}
	if state.Devices == nil {
		state.Devices = []Device{}
	}
	return state, nil
}

func (s *Store) writeState(state State) error {
	return writePrivateJSON(s.statePath(), state)
}

func (s *Store) now() time.Time {
	if s.Now == nil {
		return time.Now().UTC()
	}
	return s.Now().UTC()
}

func (s *Store) randReader() io.Reader {
	if s.Rand == nil {
		return rand.Reader
	}
	return s.Rand
}

func validateControlEndpoint(endpoint string) (*url.URL, error) {
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "https" || u.Host == "" {
		return nil, errors.New("control endpoint must be an absolute https URL")
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return nil, errors.New("control endpoint must not contain credentials, path, query, or fragment")
	}
	return u, nil
}

func generateTLSIdentity(reader io.Reader, host, name string, now time.Time) ([]byte, []byte, string, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), reader)
	if err != nil {
		return nil, nil, "", err
	}
	serialLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(reader, serialLimit)
	if err != nil {
		return nil, nil, "", err
	}
	template := x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: name},
		NotBefore:    now.Add(-5 * time.Minute),
		NotAfter:     now.AddDate(5, 0, 0),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IsCA:         false,
	}
	if ip := net.ParseIP(host); ip != nil {
		template.IPAddresses = []net.IP{ip}
	} else {
		template.DNSNames = []string{host}
	}
	der, err := x509.CreateCertificate(reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, "", err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, nil, "", err
	}
	sum := sha256.Sum256(der)
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}),
		"sha256:" + hex.EncodeToString(sum[:]), nil
}

func randomValue(reader io.Reader, prefix string, size int) (string, error) {
	b := make([]byte, size)
	if _, err := io.ReadFull(reader, b); err != nil {
		return "", err
	}
	return prefix + base64.RawURLEncoding.EncodeToString(b), nil
}

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func secureEqual(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func writeExclusive(path string, data []byte, mode os.FileMode) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		_ = os.Remove(path)
		return err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(path)
		return err
	}
	return os.Chmod(path, mode)
}

func writePrivateJSON(path string, value any) error {
	b, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o600); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func jsonUnmarshalStrict(data []byte, value any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	return decoder.Decode(value)
}
