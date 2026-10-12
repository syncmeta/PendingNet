package pnserver

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func engineFixture(t *testing.T) (*releaseInstaller, EngineLock, EngineUpdateOptions, EngineUpdateHooks, *[]string) {
	t.Helper()
	dir := t.TempDir()
	opts := EngineUpdateOptions{StateDir: dir, XrayBinary: filepath.Join(dir, "xray"), HysteriaBinary: filepath.Join(dir, "hy2")}
	for _, p := range []string{opts.XrayBinary, opts.HysteriaBinary} {
		if err := os.WriteFile(p, []byte("old"), 0755); err != nil {
			t.Fatal(err)
		}
	}
	var z bytes.Buffer
	w := zip.NewWriter(&z)
	f, _ := w.Create("xray")
	f.Write([]byte("new-xray"))
	w.Close()
	payloads := map[string][]byte{"https://fixture/xray": z.Bytes(), "https://fixture/hy2": []byte("new-hy2")}
	asset := func(url string) EngineAsset {
		sum := sha256.Sum256(payloads[url])
		return EngineAsset{URL: url, Digest: "sha256:" + hex.EncodeToString(sum[:])}
	}
	lock := EngineLock{Xray: LockedEngine{Version: "locked-xray", Assets: map[string]EngineAsset{runtime.GOARCH: asset("https://fixture/xray")}}, Hysteria2: LockedEngine{Version: "locked-hy2", Assets: map[string]EngineAsset{runtime.GOARCH: asset("https://fixture/hy2")}}}
	i := &releaseInstaller{fetch: func(_ context.Context, u string, _ int64) ([]byte, error) {
		if p, ok := payloads[u]; ok {
			return p, nil
		}
		return nil, fmt.Errorf("unlocked URL: %s", u)
	}}
	var events []string
	h := EngineUpdateHooks{Managed: func(unit, path string) error { return nil }, Active: func(string) (bool, error) { return true, nil }, Validate: func(string, string) error { return nil }, Stop: func(u string) error { events = append(events, "stop:"+u); return nil }, Start: func(u string) error { events = append(events, "start:"+u); return nil }, Healthy: func(u string) error { events = append(events, "health:"+u); return nil }}
	return i, lock, opts, h, &events
}

func TestEngineUpdatePreservesConfigurationAndIsIdempotent(t *testing.T) {
	i, lock, opts, h, events := engineFixture(t)
	state := filepath.Join(opts.StateDir, "state.json")
	os.WriteFile(state, []byte("private existing credentials"), 0600)
	config := filepath.Join(opts.StateDir, "node.json")
	os.WriteFile(config, []byte("existing node keys"), 0600)
	if err := i.updateEngines(context.Background(), opts, h, lock); err != nil {
		t.Fatal(err)
	}
	for p, want := range map[string]string{opts.XrayBinary: "new-xray", opts.HysteriaBinary: "new-hy2", state: "private existing credentials", config: "existing node keys"} {
		b, _ := os.ReadFile(p)
		if string(b) != want {
			t.Fatalf("changed %s", p)
		}
	}
	if len(*events) != 6 {
		t.Fatalf("events %v", *events)
	}
	if _, err := os.Stat(filepath.Join(opts.StateDir, "engine-update.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("journal retained after success")
	}
	*events = nil
	if err := i.updateEngines(context.Background(), opts, h, lock); err != nil {
		t.Fatal(err)
	}
	if len(*events) != 0 {
		t.Fatal("identical release restarted services")
	}
}

func TestEngineUpdateRejectsPreparationBeforeStopping(t *testing.T) {
	for _, stage := range []string{"download", "checksum", "ownership", "validation"} {
		t.Run(stage, func(t *testing.T) {
			i, lock, opts, h, events := engineFixture(t)
			switch stage {
			case "download":
				i.fetch = func(context.Context, string, int64) ([]byte, error) { return nil, errors.New("offline") }
			case "checksum":
				e := lock.Hysteria2.Assets[runtime.GOARCH]
				e.Digest = "sha256:" + string(bytes.Repeat([]byte{'0'}, 64))
				lock.Hysteria2.Assets[runtime.GOARCH] = e
			case "ownership":
				h.Managed = func(string, string) error { return errors.New("unmanaged") }
			case "validation":
				h.Validate = func(string, string) error { return errors.New("invalid candidate") }
			}
			if err := i.updateEngines(context.Background(), opts, h, lock); err == nil {
				t.Fatal("accepted failed preparation")
			}
			if len(*events) > 0 {
				t.Fatalf("affected services: %v", *events)
			}
			for _, p := range []string{opts.XrayBinary, opts.HysteriaBinary} {
				b, _ := os.ReadFile(p)
				if string(b) != "old" {
					t.Fatal("changed old engine")
				}
			}
		})
	}
}

func TestEngineUpdateRollsBackHealthFailure(t *testing.T) {
	i, lock, opts, h, _ := engineFixture(t)
	calls := 0
	h.Healthy = func(string) error {
		calls++
		if calls == 1 {
			return errors.New("candidate listener missing")
		}
		return nil
	}
	if err := i.updateEngines(context.Background(), opts, h, lock); err == nil {
		t.Fatal("health failure accepted")
	}
	for _, p := range []string{opts.XrayBinary, opts.HysteriaBinary} {
		b, _ := os.ReadFile(p)
		if string(b) != "old" {
			t.Fatal("old executable not restored")
		}
	}
	if calls != 3 {
		t.Fatalf("rollback health checks %d", calls)
	}
}

func TestEngineUpdatePreservesInactiveService(t *testing.T) {
	i, lock, opts, h, events := engineFixture(t)
	h.Active = func(u string) (bool, error) { return u == "pendingnet-xray.service", nil }
	if err := i.updateEngines(context.Background(), opts, h, lock); err != nil {
		t.Fatal(err)
	}
	for _, e := range *events {
		if bytes.Contains([]byte(e), []byte("hysteria")) {
			t.Fatal("started inactive Hysteria")
		}
	}
}

func TestEngineUpdateRecoversInterruptedTransaction(t *testing.T) {
	i, lock, opts, h, _ := engineFixture(t)
	stage := filepath.Join(opts.StateDir, "interrupted")
	os.Mkdir(stage, 0700)
	j := engineUpdateJournal{Directory: stage, Entries: []engineUpdateEntry{{Unit: "pendingnet-xray.service", Destination: opts.XrayBinary, Backup: filepath.Join(stage, "xray"), Active: true}, {Unit: "pendingnet-hysteria.service", Destination: opts.HysteriaBinary, Backup: filepath.Join(stage, "hy2"), Active: false}}}
	for n := range j.Entries {
		j.Entries[n].OriginalSHA256 = engineContentHash([]byte("saved"))
		j.Entries[n].CandidateSHA256 = engineContentHash([]byte("partial-new"))
		e := j.Entries[n]
		os.WriteFile(e.Backup, []byte("saved"), 0755)
		os.WriteFile(e.Destination, []byte("partial-new"), 0755)
	}
	writePrivateJSON(filepath.Join(opts.StateDir, "engine-update.json"), j)
	i.fetch = func(context.Context, string, int64) ([]byte, error) {
		t.Fatal("download before recovery")
		return nil, nil
	}
	if err := i.updateEngines(context.Background(), opts, h, lock); err == nil {
		t.Fatal("recovery must request rerun")
	}
	for _, e := range j.Entries {
		b, _ := os.ReadFile(e.Destination)
		if string(b) != "saved" {
			t.Fatal("interrupted update not restored")
		}
	}
}

func TestEmbeddedEngineLockIsComplete(t *testing.T) {
	if _, err := ReleaseEngineLock(); err != nil {
		t.Fatal(err)
	}
}

func TestEngineUpdateRetainsJournalWhenRollbackFails(t *testing.T) {
	i, lock, opts, h, _ := engineFixture(t)
	h.Healthy = func(string) error { return errors.New("no listener") }
	if err := i.updateEngines(context.Background(), opts, h, lock); err == nil {
		t.Fatal("accepted failed rollback")
	}
	data, err := os.ReadFile(filepath.Join(opts.StateDir, "engine-update.json"))
	if err != nil || len(data) == 0 {
		t.Fatal("lost recovery journal")
	}
	backups, err := filepath.Glob(filepath.Join(opts.StateDir, "engine-update-*", "engine-*.previous"))
	if err != nil || len(backups) != 2 {
		t.Fatal("lost recovery backups")
	}
}

func TestConcurrentEngineUpdateRefusesBeforeServiceChanges(t *testing.T) {
	i, lock, opts, h, events := engineFixture(t)
	entered, release := make(chan struct{}), make(chan struct{})
	original := i.fetch
	first := true
	i.fetch = func(ctx context.Context, u string, n int64) ([]byte, error) {
		if first {
			first = false
			close(entered)
			<-release
		}
		return original(ctx, u, n)
	}
	finished := make(chan error, 1)
	go func() { finished <- i.updateEngines(context.Background(), opts, h, lock) }()
	<-entered
	other := &releaseInstaller{fetch: original}
	err := other.updateEngines(context.Background(), opts, h, lock)
	count := len(*events)
	close(release)
	if firstErr := <-finished; firstErr != nil {
		t.Fatal(firstErr)
	}
	if err == nil || count != 0 {
		t.Fatal("concurrent update reached service mutation")
	}
}
