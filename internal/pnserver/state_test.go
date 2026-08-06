package pnserver

import (
	"crypto/x509"
	"encoding/pem"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

func testStore(t *testing.T) (*Store, time.Time) {
	t.Helper()
	now := time.Date(2026, 7, 31, 12, 0, 0, 0, time.UTC)
	s := NewStore(t.TempDir())
	s.Now = func() time.Time { return now }
	if _, err := s.Initialize("VPS 154", "https://203.0.113.10:7443"); err != nil {
		t.Fatal(err)
	}
	return s, now
}

func TestInitializeCreatesPrivateStateAndTLSIdentity(t *testing.T) {
	s, _ := testStore(t)
	state, err := s.Load()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(state.ServerID, "pns_") || !strings.HasPrefix(state.CertificateSHA256, "sha256:") {
		t.Fatalf("unexpected identity: %#v", state)
	}
	for path, wantPerm := range map[string]os.FileMode{
		s.statePath(): 0o600,
		s.certPath():  0o644,
		s.keyPath():   0o600,
	} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if got := info.Mode().Perm(); got != wantPerm {
			t.Errorf("%s permissions %o, want %o", path, got, wantPerm)
		}
	}
	if _, err := s.Initialize("again", "https://203.0.113.10:7443"); !errors.Is(err, ErrAlreadyInitialized) {
		t.Fatalf("expected already initialized, got %v", err)
	}
	certPEM, err := os.ReadFile(s.certPath())
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(certPEM)
	if block == nil {
		t.Fatal("control certificate is not PEM")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	if cert.PublicKeyAlgorithm != x509.ECDSA {
		t.Fatalf("control certificate algorithm %s, want ECDSA for Apple client compatibility", cert.PublicKeyAlgorithm)
	}
}

func TestPairingIsSingleUseAndIssuesIndependentDeviceToken(t *testing.T) {
	s, now := testStore(t)
	pairFile, err := s.CreatePairing(10 * time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if pairFile.ServerID == "" || pairFile.Enrollment.Token == "" || pairFile.Enrollment.ExpiresAt != now.Add(10*time.Minute) {
		t.Fatalf("unexpected pairing file: %#v", pairFile)
	}
	state, _ := s.Load()
	stateJSON, _ := os.ReadFile(s.statePath())
	if strings.Contains(string(stateJSON), pairFile.Enrollment.Token) {
		t.Fatal("raw enrollment token leaked into state")
	}
	if len(state.Pairings) != 1 {
		t.Fatalf("got %d pairings", len(state.Pairings))
	}

	cred, err := s.Enroll(pairFile.Enrollment.Token, "Hey's Mac")
	if err != nil {
		t.Fatal(err)
	}
	if cred.Token == pairFile.Enrollment.Token || cred.DeviceID == "" {
		t.Fatalf("bad device credential: %#v", cred)
	}
	if _, err := s.Authenticate(cred.Token); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Enroll(pairFile.Enrollment.Token, "second device"); !errors.Is(err, ErrInvalidPairing) {
		t.Fatalf("expected one-time token failure, got %v", err)
	}
}

func TestExpiredPairingCannotEnroll(t *testing.T) {
	s, now := testStore(t)
	pairFile, err := s.CreatePairing(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	s.Now = func() time.Time { return now.Add(2 * time.Minute) }
	if _, err := s.Enroll(pairFile.Enrollment.Token, "late device"); !errors.Is(err, ErrInvalidPairing) {
		t.Fatalf("expected expired pairing, got %v", err)
	}
}
