package pairing

import (
	"encoding/base64"
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

func TestPairingURLRoundTrip(t *testing.T) {
	now := time.Date(2026, 7, 31, 12, 0, 0, 0, time.UTC)
	want := validFile(now)
	link, err := want.URL(now)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(link, "pendingnet://pair?v=1&d=") {
		t.Fatalf("unexpected link shape: %s", link)
	}
	got, err := ParseURL(link, now)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("round trip mismatch:\n got %#v\nwant %#v", got, want)
	}
}

// A link and the *.pdn file it came from must decode to exactly the same
// document — that is the whole point of encoding the JSON wholesale.
func TestPairingURLMatchesFile(t *testing.T) {
	now := time.Date(2026, 7, 31, 12, 0, 0, 0, time.UTC)
	f := validFile(now)
	link, err := f.URL(now)
	if err != nil {
		t.Fatal(err)
	}
	b, err := f.Marshal(now)
	if err != nil {
		t.Fatal(err)
	}
	fromLink, err := ParseURL(link, now)
	if err != nil {
		t.Fatal(err)
	}
	fromFile, err := Parse(b, now)
	if err != nil {
		t.Fatal(err)
	}
	if fromLink != fromFile {
		t.Fatalf("link and file disagree:\nlink %#v\nfile %#v", fromLink, fromFile)
	}
}

func TestPairingURLTolerantOfPaste(t *testing.T) {
	now := time.Date(2026, 7, 31, 12, 0, 0, 0, time.UTC)
	link, err := validFile(now).URL(now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ParseURL("  \n"+link+"\n ", now); err != nil {
		t.Fatalf("pasted link with surrounding whitespace: %v", err)
	}
	if _, err := ParseURL(link+"==", now); err != nil {
		t.Fatalf("link that picked up base64 padding: %v", err)
	}
}

func TestPairingURLRejectsExpired(t *testing.T) {
	now := time.Date(2026, 7, 31, 12, 0, 0, 0, time.UTC)
	link, err := validFile(now).URL(now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ParseURL(link, now.Add(2*time.Hour)); err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatalf("expected expiry error, got %v", err)
	}
	f := validFile(now)
	f.Enrollment.ExpiresAt = now
	if _, err := f.URL(now); err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatalf("expected URL() to refuse an expired file, got %v", err)
	}
}

func TestPairingURLRejectsMalformed(t *testing.T) {
	now := time.Date(2026, 7, 31, 12, 0, 0, 0, time.UTC)
	valid, err := validFile(now).URL(now)
	if err != nil {
		t.Fatal(err)
	}
	payload := strings.TrimPrefix(valid, "pendingnet://pair?v=1&d=")
	notPairingJSON := base64.RawURLEncoding.EncodeToString([]byte(`{"hello":"world"}`))
	wrongFormat := base64.RawURLEncoding.EncodeToString(
		[]byte(`{"format":"something-else","version":1,"server_id":"x","name":"x","control":{"endpoint":"https://203.0.113.10:7443","certificate_sha256":"sha256:` +
			strings.Repeat("ab", 32) + `"},"enrollment":{"token":"` + strings.Repeat("t", 43) + `","expires_at":"2026-07-31T13:00:00Z"}}`))

	for name, link := range map[string]string{
		"empty":            "",
		"plain text":       "just some text a user pasted",
		"wrong scheme":     "https://pair?v=1&d=" + payload,
		"wrong host":       "pendingnet://connect?v=1&d=" + payload,
		"has path":         "pendingnet://pair/import?v=1&d=" + payload,
		"missing version":  "pendingnet://pair?d=" + payload,
		"future version":   "pendingnet://pair?v=2&d=" + payload,
		"unknown param":    "pendingnet://pair?v=1&d=" + payload + "&extra=1",
		"repeated param":   "pendingnet://pair?v=1&d=" + payload + "&d=" + payload,
		"missing payload":  "pendingnet://pair?v=1",
		"not base64url":    "pendingnet://pair?v=1&d=not*base64*url",
		"base64 not json":  "pendingnet://pair?v=1&d=" + base64.RawURLEncoding.EncodeToString([]byte("not json at all")),
		"json not pairing": "pendingnet://pair?v=1&d=" + notPairingJSON,
		"wrong format":     "pendingnet://pair?v=1&d=" + wrongFormat,
	} {
		if _, err := ParseURL(link, now); err == nil {
			t.Fatalf("%s: expected an error, got none", name)
		}
	}
}
