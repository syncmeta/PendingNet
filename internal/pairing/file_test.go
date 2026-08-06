package pairing

import (
	"strings"
	"testing"
	"time"
)

func validFile(now time.Time) File {
	return File{
		Format:   Format,
		Version:  Version,
		ServerID: "pn_server_123",
		Name:     "VPS 154",
		Control: Control{
			Endpoint:          "https://203.0.113.10:7443",
			CertificateSHA256: "sha256:" + strings.Repeat("ab", 32),
		},
		Enrollment: Enrollment{
			Token:     strings.Repeat("t", 43),
			ExpiresAt: now.Add(time.Hour),
		},
	}
}

func TestPairingRoundTrip(t *testing.T) {
	now := time.Date(2026, 7, 31, 12, 0, 0, 0, time.UTC)
	want := validFile(now)
	b, err := want.Marshal(now)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Parse(b, now)
	if err != nil {
		t.Fatal(err)
	}
	if got.ServerID != want.ServerID || got.Control.Endpoint != want.Control.Endpoint || got.Enrollment.Token != want.Enrollment.Token {
		t.Fatalf("round trip mismatch: %#v", got)
	}
}

func TestPairingRejectsExpiredFile(t *testing.T) {
	now := time.Date(2026, 7, 31, 12, 0, 0, 0, time.UTC)
	f := validFile(now)
	f.Enrollment.ExpiresAt = now
	if _, err := f.Marshal(now); err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatalf("expected expiry error, got %v", err)
	}
}

func TestPairingRejectsUnsafeEndpoint(t *testing.T) {
	now := time.Date(2026, 7, 31, 12, 0, 0, 0, time.UTC)
	for _, endpoint := range []string{
		"http://203.0.113.10:7443",
		"https://user:pass@203.0.113.10:7443",
		"https://203.0.113.10:7443/api",
	} {
		f := validFile(now)
		f.Control.Endpoint = endpoint
		if _, err := f.Marshal(now); err == nil {
			t.Errorf("expected endpoint %q to fail", endpoint)
		}
	}
}

func TestPairingRejectsUnknownFields(t *testing.T) {
	now := time.Date(2026, 7, 31, 12, 0, 0, 0, time.UTC)
	data := []byte(`{
      "format":"pendingnet-pairing","version":1,"server_id":"pn_1","name":"vps",
      "control":{"endpoint":"https://example.com:7443","certificate_sha256":"sha256:abababababababababababababababababababababababababababababababab"},
      "enrollment":{"token":"tttttttttttttttttttttttttttttttt","expires_at":"2026-08-01T00:00:00Z"},
      "routing":{"mode":"global"}
    }`)
	if _, err := Parse(data, now); err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("expected unknown field error, got %v", err)
	}
}
