package pnserver

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSystemdUnitIsSelfContainedAndHardened(t *testing.T) {
	unit, err := SystemdUnit("/usr/local/bin/pendingnet-server", "/etc/pendingnet")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`ExecStart="/usr/local/bin/pendingnet-server" serve --state-dir "/etc/pendingnet"`,
		"Restart=on-failure", "NoNewPrivileges=true", "ProtectSystem=strict",
		`ReadWritePaths="/etc/pendingnet"`,
	} {
		if !strings.Contains(unit, want) {
			t.Errorf("unit missing %q:\n%s", want, unit)
		}
	}
	if strings.Contains(unit, ".sh") {
		t.Fatalf("unit unexpectedly depends on a shell script:\n%s", unit)
	}
}

func TestInstallExecutableCopiesAtomically(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source")
	destination := filepath.Join(dir, "bin", "pendingnet-server")
	if err := os.WriteFile(source, []byte("binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := InstallExecutable(source, destination); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "binary" {
		t.Fatalf("destination contains %q", data)
	}
	info, _ := os.Stat(destination)
	if info.Mode().Perm() != 0o755 {
		t.Fatalf("permissions %o", info.Mode().Perm())
	}
}

func TestManagementAliasPreservesOtherCommandsAndFollowsUpdates(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "pendingnet-server")
	alias := filepath.Join(dir, "pendingnet")
	if err := os.WriteFile(target, []byte("old"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := InstallCommandAlias(target, alias); err != nil {
		t.Fatal(err)
	}
	if err := InstallCommandAlias(target, alias); err != nil {
		t.Fatal(err)
	}
	replacement := filepath.Join(dir, "new")
	_ = os.WriteFile(replacement, []byte("new"), 0755)
	if err := os.Rename(replacement, target); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(alias)
	if string(data) != "new" {
		t.Fatal("alias retained old executable")
	}
	other := filepath.Join(dir, "other-command")
	_ = os.WriteFile(other, []byte("keep"), 0755)
	if err := InstallCommandAlias(target, other); err == nil {
		t.Fatal("overwrote unrelated command")
	}
	data, _ = os.ReadFile(other)
	if string(data) != "keep" {
		t.Fatal("changed existing command")
	}
}
