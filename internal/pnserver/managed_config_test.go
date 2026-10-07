package pnserver

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func managedConfigFixture(t *testing.T) (*Store, string, ManagedConfig) {
	t.Helper()
	return provisionedManagedConfigFixture(t)
}

func TestManagedConfigRejectsStaleRevisionBeforeMutation(t *testing.T) {
	store, services, original := managedConfigFixture(t)
	candidate := original
	candidate.Revision = "stale"
	candidate.Xray = append(append([]byte(nil), original.Xray...), '\n')
	called := false
	err := store.ApplyManagedConfig(services, candidate, ManagedConfigHooks{
		Validate: func(ManagedConfigPaths) error { called = true; return nil },
		Restart:  func() error { called = true; return nil },
	})
	if !errors.Is(err, ErrManagedConfigConflict) || called {
		t.Fatalf("stale revision changed state: %v", err)
	}
	after, err := store.ReadManagedConfig(services)
	if err != nil || after.Revision != original.Revision {
		t.Fatalf("stale request changed files: %#v %v", after, err)
	}
}

func TestManagedConfigRejectsInvalidJSONAndChangesDuringValidation(t *testing.T) {
	store, services, original := managedConfigFixture(t)
	bad := original
	bad.Hysteria = []byte(`{"broken":`)
	called := false
	if err := store.ApplyManagedConfig(services, bad, ManagedConfigHooks{
		Validate: func(ManagedConfigPaths) error { called = true; return nil },
		Restart:  func() error { called = true; return nil },
	}); err == nil || called {
		t.Fatal("invalid JSON reached validator or restart")
	}
	candidate := original
	candidate.Xray = append(append([]byte(nil), original.Xray...), '\n')
	err := store.ApplyManagedConfig(services, candidate, ManagedConfigHooks{
		Validate: func(ManagedConfigPaths) error {
			return os.WriteFile(filepath.Join(services, "xray.json"), []byte(`{"external":true}`), 0o600)
		},
		Restart: func() error { called = true; return nil },
	})
	if !errors.Is(err, ErrManagedConfigConflict) || called {
		t.Fatalf("concurrent edit was overwritten: %v", err)
	}
	after, err := store.ReadManagedConfig(services)
	if err != nil || string(after.Xray) != `{"external":true}` {
		t.Fatalf("external change lost: %#v %v", after, err)
	}
}

func TestManagedConfigValidationFailureAndRestartFailureRollBack(t *testing.T) {
	store, services, original := managedConfigFixture(t)
	candidate := original
	candidate.Xray = append(append([]byte(nil), original.Xray...), '\n')
	for _, stage := range []string{"validation", "restart"} {
		restarts := 0
		err := store.ApplyManagedConfig(services, candidate, ManagedConfigHooks{
			Validate: func(paths ManagedConfigPaths) error {
				if _, err := os.Stat(paths.Xray); err != nil {
					t.Fatal(err)
				}
				if stage == "validation" {
					return errors.New("invalid engine config")
				}
				return nil
			},
			Restart: func() error {
				restarts++
				if stage == "restart" && restarts == 1 {
					return errors.New("service failed")
				}
				return nil
			},
		})
		if err == nil {
			t.Fatalf("%s failure was accepted", stage)
		}
		if stage == "validation" && restarts != 0 {
			t.Fatal("restarted before validation")
		}
		if stage == "restart" && restarts != 2 {
			t.Fatalf("rollback restart count %d", restarts)
		}
		after, readErr := store.ReadManagedConfig(services)
		if readErr != nil || after.Revision != original.Revision {
			t.Fatalf("%s did not restore original: %#v %v", stage, after, readErr)
		}
	}
}

func TestManagedConfigReportsFailedRollbackRestartAndKeepsRecoveryBackup(t *testing.T) {
	store, services, original := managedConfigFixture(t)
	candidate := original
	candidate.Xray = append(append([]byte(nil), original.Xray...), '\n')
	firstFailure := errors.New("candidate restart failed")
	rollbackFailure := errors.New("rollback restart failed")
	restarts := 0
	err := store.ApplyManagedConfig(services, candidate, ManagedConfigHooks{
		Validate: func(ManagedConfigPaths) error { return nil },
		Restart: func() error {
			restarts++
			if restarts == 1 {
				return firstFailure
			}
			return rollbackFailure
		},
	})
	if restarts != 2 || !errors.Is(err, firstFailure) || !errors.Is(err, rollbackFailure) {
		t.Fatalf("failed rollback restart was not reported: restarts=%d err=%v", restarts, err)
	}
	after, readErr := store.ReadManagedConfig(services)
	if readErr != nil || after.Revision != original.Revision {
		t.Fatalf("failed rollback restart did not restore original files: %v", readErr)
	}
	backup := filepath.Join(store.Dir, "management-backups", original.Revision)
	for name, want := range map[string][]byte{
		"node.json": original.Node, "xray.json": original.Xray, "hysteria.json": original.Hysteria,
	} {
		got, readErr := readManagedFile(filepath.Join(backup, name))
		if readErr != nil || string(got) != string(want) {
			t.Fatalf("recovery backup %s missing or changed: %v", name, readErr)
		}
	}
}

func TestManagedConfigRequiresValidatorAndPreservesBackup(t *testing.T) {
	store, services, original := managedConfigFixture(t)
	candidate := original
	candidate.Xray = append(append([]byte(nil), original.Xray...), '\n')
	if err := store.ApplyManagedConfig(services, candidate, ManagedConfigHooks{}); !errors.Is(err, ErrManagedConfigUnavailable) {
		t.Fatalf("missing hooks accepted: %v", err)
	}
	if err := store.ApplyManagedConfig(services, candidate, ManagedConfigHooks{
		Validate: func(ManagedConfigPaths) error { return nil },
		Restart:  func() error { return nil },
	}); err != nil {
		t.Fatal(err)
	}
	after, err := store.ReadManagedConfig(services)
	if err != nil || after.Revision == original.Revision {
		t.Fatalf("new config not committed: %#v %v", after, err)
	}
	backup := filepath.Join(store.Dir, "management-backups", original.Revision)
	info, err := os.Stat(backup)
	if err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("protected backup missing: %v", err)
	}
	for _, name := range []string{"node.json", "xray.json", "hysteria.json"} {
		info, err := os.Stat(filepath.Join(backup, name))
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("protected %s backup missing: %v", name, err)
		}
	}
}

func TestManagedConfigRejectsSymlinkedBackupDirectory(t *testing.T) {
	store, services, original := managedConfigFixture(t)
	backupBase := filepath.Join(store.Dir, "management-backups")
	outside := t.TempDir()
	if err := os.Chmod(outside, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, backupBase); err != nil {
		t.Fatal(err)
	}
	candidate := original
	candidate.Xray = append(append([]byte(nil), original.Xray...), '\n')
	restarted := false
	err := store.ApplyManagedConfig(services, candidate, ManagedConfigHooks{
		Validate: func(ManagedConfigPaths) error { return nil },
		Restart:  func() error { restarted = true; return nil },
	})
	if err == nil || restarted {
		t.Fatalf("symlinked backup directory accepted: %v", err)
	}
	if after, readErr := store.ReadManagedConfig(services); readErr != nil || after.Revision != original.Revision {
		t.Fatalf("symlinked backup changed live configuration: %v", readErr)
	}
	if entries, readErr := os.ReadDir(outside); readErr != nil || len(entries) != 0 {
		t.Fatalf("backup escaped state directory: entries=%d err=%v", len(entries), readErr)
	}
}

func TestManagedConfigRejectsSymlinkedExistingBackup(t *testing.T) {
	store, services, original := managedConfigFixture(t)
	backupBase := filepath.Join(store.Dir, "management-backups")
	if err := os.Mkdir(backupBase, 0o700); err != nil {
		t.Fatal(err)
	}
	outside := t.TempDir()
	if err := os.Chmod(outside, 0o700); err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string][]byte{
		"node.json": original.Node, "xray.json": original.Xray, "hysteria.json": original.Hysteria,
	} {
		if err := os.WriteFile(filepath.Join(outside, name), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(outside, filepath.Join(backupBase, original.Revision)); err != nil {
		t.Fatal(err)
	}
	candidate := original
	candidate.Xray = append(append([]byte(nil), original.Xray...), '\n')
	restarted := false
	err := store.ApplyManagedConfig(services, candidate, ManagedConfigHooks{
		Validate: func(ManagedConfigPaths) error { return nil },
		Restart:  func() error { restarted = true; return nil },
	})
	if err == nil || restarted {
		t.Fatalf("symlinked existing backup accepted: %v", err)
	}
	if after, readErr := store.ReadManagedConfig(services); readErr != nil || after.Revision != original.Revision {
		t.Fatalf("symlinked existing backup changed live configuration: %v", readErr)
	}
}

func TestManagedConfigRejectsSymlinkAndNodeIdentityChange(t *testing.T) {
	store, services, original := managedConfigFixture(t)
	xray := filepath.Join(services, "xray.json")
	if err := os.Remove(xray); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(services, "hysteria.json"), xray); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ReadManagedConfig(services); err == nil {
		t.Fatal("symlinked engine configuration was accepted")
	}
	if err := os.Remove(xray); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(xray, original.Xray, 0o600); err != nil {
		t.Fatal(err)
	}
	candidate := original
	candidate.Node = []byte(`{"version":1,"server_id":"different","protocols":[{"id":"reality","type":"vless-reality","display_name":"Reality"}]}`)
	called := false
	err := store.ApplyManagedConfig(services, candidate, ManagedConfigHooks{
		Validate: func(ManagedConfigPaths) error { called = true; return nil },
		Restart:  func() error { called = true; return nil },
	})
	if err == nil || called {
		t.Fatalf("node identity edit reached validator or restart: %v", err)
	}
}
