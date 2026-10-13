package main

import (
	"bytes"
	"os"
	"path/filepath"
	"sbtally/internal/pairing"
	"sbtally/internal/pnserver"
	"strings"
	"testing"
	"time"
)

func TestLinksAndUsersCommands(t *testing.T) {
	originalSync := syncUserServicesForCLI
	syncUserServicesForCLI = func(store *pnserver.Store) error { _, err := store.EnsureUserProxyAccounts(); return err }
	defer func() { syncUserServicesForCLI = originalSync }()
	dir := t.TempDir()
	store := pnserver.NewStore(dir)
	if _, err := store.Initialize("VPS", "https://203.0.113.1:7443"); err != nil {
		t.Fatal(err)
	}
	profile := pnserver.NodeProfile{Protocols: []pnserver.NodeProtocol{{Type: "vless-reality", DisplayName: "Reality", VLESSReality: &pnserver.VLESSReality{Server: "203.0.113.1", ServerPort: 443, UUID: "uuid", Flow: "xtls-rprx-vision", ServerName: "www.example.com", PublicKey: "pub", ShortID: "abcd"}}}}
	if err := store.SaveNodeProfile(profile); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(filepath.Join(dir, "node.json"))
	var out, errs bytes.Buffer
	if err := run([]string{"links", "--state-dir", dir}, &out, &errs); err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{"vless://", "pendingnet://", "pendingnetm://"} {
		if !strings.Contains(out.String(), s) {
			t.Fatal("missing " + s)
		}
	}
	after, _ := os.ReadFile(filepath.Join(dir, "node.json"))
	if !bytes.Equal(before, after) {
		t.Fatal("rotated node")
	}
	state, _ := store.Load()
	if len(state.Pairings) != 2 {
		t.Fatal("must issue one client and one admin grant")
	}
	for _, line := range strings.Split(out.String(), "\n") {
		if strings.HasPrefix(line, "pendingnetm://") {
			p, err := pairing.ParseURL(line, time.Now())
			if err != nil || p.Enrollment.Role != "admin" {
				t.Fatal("invalid admin link")
			}
		}
	}
	out.Reset()
	if err := run([]string{"users", "list", "--state-dir", dir}, &out, &errs); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String(), "token_sha256") {
		t.Fatal("list exposed credential hashes")
	}
	grant, err := store.CreatePairing(time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	cred, err := store.Enroll(grant.Enrollment.Token, "test device")
	if err != nil {
		t.Fatal(err)
	}
	state, _ = store.Load()
	var userID string
	for _, d := range state.Devices {
		if d.ID == cred.DeviceID {
			userID = d.UserID
		}
	}
	if err := run([]string{"users", "revoke", userID, "--state-dir", dir}, &out, &errs); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Authenticate(cred.Token); err != pnserver.ErrUnauthorized {
		t.Fatal("revoke did not invalidate device")
	}
}

func TestMenuCanExitAndGenerateLinksWithProvidedInput(t *testing.T) {
	var out, errs bytes.Buffer
	if err := runMenu(strings.NewReader("0\n"), &out, &errs, defaultStateDir); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "PendingNet") {
		t.Fatal("no menu")
	}
}
