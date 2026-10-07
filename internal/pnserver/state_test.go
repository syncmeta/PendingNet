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

func TestPairingCreatesDistinctRandomNamedUsersAndRecordsFirstSeenIP(t *testing.T) {
	s, now := testStore(t)
	first, err := s.CreatePairing(10 * time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	second, err := s.CreatePairing(10 * time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	state, err := s.Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Users) != 2 || state.Users[0].ID == state.Users[1].ID ||
		state.Users[0].Name == state.Users[1].Name ||
		state.Pairings[0].UserID != state.Users[0].ID ||
		state.Pairings[1].UserID != state.Users[1].ID {
		t.Fatalf("pairings must have distinct named owners: %#v", state)
	}
	if state.Users[0].Name == "" || state.Users[1].Name == "" {
		t.Fatal("user names must not be empty")
	}
	cred, err := s.EnrollFromIP(first.Enrollment.Token, "Mac", "198.51.100.7")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.EnrollFromIP(second.Enrollment.Token, "iPhone", "203.0.113.9"); err != nil {
		t.Fatal(err)
	}
	state, err = s.Load()
	if err != nil {
		t.Fatal(err)
	}
	if state.Devices[0].UserID != state.Users[0].ID ||
		len(state.Users[0].LoginIPs) != 1 ||
		state.Users[0].LoginIPs[0].IP != "198.51.100.7" ||
		!state.Users[0].LoginIPs[0].FirstSeenAt.Equal(now) {
		t.Fatalf("first enrollment IP was not recorded: %#v", state)
	}
	if len(state.Users[1].LoginIPs) != 1 || state.Users[1].LoginIPs[0].IP != "203.0.113.9" {
		t.Fatalf("other user's IP was not recorded separately: %#v", state.Users[1])
	}
	s.Now = func() time.Time { return now.Add(time.Hour) }
	if _, err := s.AuthenticateFromIP(cred.Token, "198.51.100.7"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AuthenticateFromIP(cred.Token, "2001:db8::1"); err != nil {
		t.Fatal(err)
	}
	state, err = s.Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Users[0].LoginIPs) != 2 ||
		!state.Users[0].LoginIPs[0].FirstSeenAt.Equal(now) ||
		state.Users[0].LoginIPs[1].IP != "2001:db8::1" ||
		!state.Users[0].LoginIPs[1].FirstSeenAt.Equal(now.Add(time.Hour)) {
		t.Fatalf("first-seen IP timestamps changed or new IP missing: %#v", state.Users[0].LoginIPs)
	}
}

func TestLegacyPairingAndDeviceGainOwnersWithoutChangingCredentials(t *testing.T) {
	s, now := testStore(t)
	pairFile, err := s.CreatePairing(time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	state, err := s.Load()
	if err != nil {
		t.Fatal(err)
	}
	state.Pairings[0].UserID = ""
	state.Users = nil // Original state.json had no users key.
	if err := s.writeState(state); err != nil {
		t.Fatal(err)
	}
	cred, err := s.EnrollFromIP(pairFile.Enrollment.Token, "old-client", "192.0.2.10")
	if err != nil {
		t.Fatal(err)
	}
	state, err = s.Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Users) != 1 || state.Devices[0].UserID != state.Users[0].ID {
		t.Fatalf("legacy pairing did not gain owner: %#v", state)
	}
	state.Devices[0].UserID = ""
	state.Users = nil // Existing device from a pre-user-model server.
	if err := s.writeState(state); err != nil {
		t.Fatal(err)
	}
	s.Now = func() time.Time { return now.Add(time.Minute) }
	device, err := s.AuthenticateFromIP(cred.Token, "192.0.2.11")
	if err != nil {
		t.Fatal(err)
	}
	state, err = s.Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Users) != 1 || device.UserID != state.Users[0].ID ||
		len(state.Users[0].LoginIPs) != 1 || state.Users[0].LoginIPs[0].IP != "192.0.2.11" {
		t.Fatalf("legacy device did not gain owner: %#v", state)
	}
}

func TestAdminPairingIsSeparateAndRevocable(t *testing.T) {
	s, _ := testStore(t)
	regular, err := s.CreatePairing(10 * time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	admin, err := s.CreateAdminPairing(10 * time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if regular.Enrollment.Role != "" || admin.Enrollment.Role != "admin" {
		t.Fatalf("link roles: regular=%q admin=%q", regular.Enrollment.Role, admin.Enrollment.Role)
	}
	clientCredential, err := s.Enroll(regular.Enrollment.Token, "client")
	if err != nil {
		t.Fatal(err)
	}
	adminCredential, err := s.Enroll(admin.Enrollment.Token, "manager")
	if err != nil {
		t.Fatal(err)
	}
	client, err := s.Authenticate(clientCredential.Token)
	if err != nil {
		t.Fatal(err)
	}
	manager, err := s.Authenticate(adminCredential.Token)
	if err != nil {
		t.Fatal(err)
	}
	if client.Role != "" || manager.Role != "admin" || client.UserID == manager.UserID {
		t.Fatalf("roles or owners mixed: client=%#v manager=%#v", client, manager)
	}
	if err := s.RevokeUser(manager.UserID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Authenticate(adminCredential.Token); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("revoked admin credential still works: %v", err)
	}
	if _, err := s.Authenticate(clientCredential.Token); err != nil {
		t.Fatalf("revoking admin affected ordinary client: %v", err)
	}
}

func TestRevokedAdminPairingCannotEnroll(t *testing.T) {
	s, _ := testStore(t)
	admin, err := s.CreateAdminPairing(time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	state, err := s.Load()
	if err != nil {
		t.Fatal(err)
	}
	if err := s.RevokeUser(state.Pairings[0].UserID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Enroll(admin.Enrollment.Token, "late manager"); !errors.Is(err, ErrInvalidPairing) {
		t.Fatalf("revoked admin link enrolled: %v", err)
	}
}

func TestLinkRoleTextCannotElevateOrdinaryGrant(t *testing.T) {
	s, _ := testStore(t)
	regular, err := s.CreatePairing(time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	regular.Enrollment.Role = "admin" // An attacker can edit the link JSON.
	credential, err := s.Enroll(regular.Enrollment.Token, "ordinary")
	if err != nil {
		t.Fatal(err)
	}
	device, err := s.Authenticate(credential.Token)
	if err != nil {
		t.Fatal(err)
	}
	if device.Role != "" {
		t.Fatalf("link text elevated ordinary device: %#v", device)
	}
}

func TestMissingAdminOwnerFailsClosed(t *testing.T) {
	s, _ := testStore(t)
	admin, err := s.CreateAdminPairing(time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	credential, err := s.Enroll(admin.Enrollment.Token, "manager")
	if err != nil {
		t.Fatal(err)
	}
	state, err := s.Load()
	if err != nil {
		t.Fatal(err)
	}
	state.Users = nil
	if err := s.writeState(state); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Authenticate(credential.Token); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("admin token with missing owner was accepted: %v", err)
	}
}
