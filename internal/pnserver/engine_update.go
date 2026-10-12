package pnserver

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
)

type EngineUpdateOptions struct{ StateDir, XrayBinary, HysteriaBinary string }
type EngineUpdateHooks struct {
	Managed  func(unit, binary string) error
	Active   func(unit string) (bool, error)
	Validate func(xray, hysteria string) error
	Stop     func(unit string) error
	Start    func(unit string) error
	Healthy  func(unit string) error
}
type engineUpdateEntry struct {
	Unit, Destination, Backup       string
	Active                          bool
	OriginalSHA256, CandidateSHA256 string
}
type engineUpdateJournal struct {
	Directory string
	Entries   []engineUpdateEntry
}

// Only executable files change. This transaction never provisions, edits node
// configuration, rotates credentials, or touches an unrelated sing-box service.
func UpdateReleaseProxyEngines(ctx context.Context, opts EngineUpdateOptions, hooks EngineUpdateHooks) error {
	lock, err := ReleaseEngineLock()
	if err != nil {
		return err
	}
	return newReleaseInstaller().updateEngines(ctx, opts, hooks, lock)
}

func (i *releaseInstaller) updateEngines(ctx context.Context, opts EngineUpdateOptions, h EngineUpdateHooks, lock EngineLock) error {
	opts.StateDir = filepath.Clean(opts.StateDir)
	if h.Managed == nil || h.Active == nil || h.Validate == nil || h.Stop == nil || h.Start == nil || h.Healthy == nil {
		return errors.New("engine update requires management, validation and health hooks")
	}
	for _, p := range []string{opts.StateDir, opts.XrayBinary, opts.HysteriaBinary} {
		if !filepath.IsAbs(p) {
			return errors.New("update paths must be absolute")
		}
	}
	if opts.XrayBinary == opts.HysteriaBinary {
		return errors.New("engine destinations must differ")
	}
	file, err := os.OpenFile(filepath.Join(opts.StateDir, "engine-update.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	if err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return fmt.Errorf("another engine update is active: %w", err)
	}
	defer syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	journalPath := filepath.Join(opts.StateDir, "engine-update.json")
	if data, err := os.ReadFile(journalPath); err == nil {
		var journal engineUpdateJournal
		if err = json.Unmarshal(data, &journal); err != nil {
			return errors.New("invalid engine update recovery journal; preserve backups for manual recovery")
		}
		if len(journal.Entries) != 2 || journal.Entries[0].Unit != "pendingnet-xray.service" || journal.Entries[1].Unit != "pendingnet-hysteria.service" || filepath.Dir(journal.Directory) != opts.StateDir || journal.Entries[0].Destination != opts.XrayBinary || journal.Entries[1].Destination != opts.HysteriaBinary {
			return errors.New("engine recovery journal belongs to different update paths")
		}
		if err = recoverEngineUpdate(journal, h); err != nil {
			return fmt.Errorf("pending engine update recovery failed: %w", err)
		}
		if err = os.Remove(journalPath); err != nil {
			return err
		}
		return errors.New("recovered interrupted engine update; rerun to apply this release")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	entries := []engineUpdateEntry{{Unit: "pendingnet-xray.service", Destination: opts.XrayBinary}, {Unit: "pendingnet-hysteria.service", Destination: opts.HysteriaBinary}}
	for n := range entries {
		e := &entries[n]
		info, err := os.Lstat(e.Destination)
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.Mode()&0111 == 0 {
			return fmt.Errorf("engine must be an existing regular executable: %s", e.Destination)
		}
		if err = h.Managed(e.Unit, e.Destination); err != nil {
			return err
		}
		e.Active, err = h.Active(e.Unit)
		if err != nil {
			return err
		}
	}
	stage, err := os.MkdirTemp(opts.StateDir, "engine-update-")
	if err != nil {
		return err
	}
	keep := false
	defer func() {
		if !keep {
			_ = os.RemoveAll(stage)
		}
	}()
	xray, hy2 := filepath.Join(stage, "xray.new"), filepath.Join(stage, "hysteria.new")
	if _, err = i.installLocked(ctx, lock.Xray, runtime.GOARCH, "xray", xray); err != nil {
		return err
	}
	if _, err = i.installLocked(ctx, lock.Hysteria2, runtime.GOARCH, "", hy2); err != nil {
		return err
	}
	if err = h.Validate(xray, hy2); err != nil {
		return fmt.Errorf("candidate validation: %w", err)
	}
	changed := false
	for n, source := range []string{xray, hy2} {
		a, err := os.ReadFile(source)
		if err != nil {
			return err
		}
		b, err := os.ReadFile(entries[n].Destination)
		if err != nil {
			return err
		}
		if sha256.Sum256(a) != sha256.Sum256(b) {
			changed = true
		}
		entries[n].OriginalSHA256 = engineContentHash(b)
		entries[n].CandidateSHA256 = engineContentHash(a)
		entries[n].Backup = filepath.Join(stage, fmt.Sprintf("engine-%d.previous", n))
		if err = InstallExecutable(entries[n].Destination, entries[n].Backup); err != nil {
			return err
		}
	}
	if !changed {
		return nil
	}
	journal := engineUpdateJournal{Directory: stage, Entries: entries}
	if err = syncEngineDirectory(stage); err != nil {
		return err
	}
	if err = writePrivateJSON(journalPath, journal); err != nil {
		return err
	}
	// Once the journal exists, every error must retain its referenced backups.
	keep = true
	journalFile, err := os.OpenFile(journalPath, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	err = journalFile.Sync()
	closeErr := journalFile.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = syncEngineDirectory(opts.StateDir); err != nil {
		return err
	}
	apply := func() error {
		for _, e := range entries {
			if e.Active {
				if err := h.Stop(e.Unit); err != nil {
					return err
				}
			}
		}
		for n, source := range []string{xray, hy2} {
			if err := InstallExecutable(source, entries[n].Destination); err != nil {
				return err
			}
			if err := syncEngineDirectory(filepath.Dir(entries[n].Destination)); err != nil {
				return err
			}
		}
		for _, e := range entries {
			if e.Active {
				if err := h.Start(e.Unit); err != nil {
					return err
				}
			}
		}
		for _, e := range entries {
			if e.Active {
				if err := h.Healthy(e.Unit); err != nil {
					return err
				}
			}
		}
		return nil
	}
	if err = apply(); err != nil {
		recovery := recoverEngineUpdate(journal, h)
		if recovery != nil {
			return errors.Join(fmt.Errorf("engine update failed: %w", err), fmt.Errorf("rollback failed; retained journal %s: %w", journalPath, recovery))
		}
		if removeErr := os.Remove(journalPath); removeErr != nil {
			return errors.Join(err, removeErr)
		}
		return fmt.Errorf("engine update failed; previous binaries and service states restored (backups: %s): %w", stage, err)
	}
	if err = os.Remove(journalPath); err != nil {
		return err
	}
	// Retain the private backup directory for explicit manual rollback.
	return nil
}

func recoverEngineUpdate(j engineUpdateJournal, h EngineUpdateHooks) error {
	// Validate all backups and ownership before stopping any service.
	for _, e := range j.Entries {
		if err := h.Managed(e.Unit, e.Destination); err != nil {
			return err
		}
		if !filepath.IsAbs(e.Backup) || filepath.Dir(e.Backup) != j.Directory {
			return errors.New("invalid engine backup path")
		}
		info, err := os.Lstat(e.Backup)
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return errors.New("invalid engine backup")
		}
		backup, err := os.ReadFile(e.Backup)
		if err != nil {
			return err
		}
		current, err := os.ReadFile(e.Destination)
		if err != nil {
			return err
		}
		if e.OriginalSHA256 == "" || e.CandidateSHA256 == "" || engineContentHash(backup) != e.OriginalSHA256 {
			return errors.New("engine recovery backup integrity check failed")
		}
		currentHash := engineContentHash(current)
		if currentHash != e.OriginalSHA256 && currentHash != e.CandidateSHA256 {
			return errors.New("engine changed after interrupted update; preserve journal for manual recovery")
		}
	}
	var errs []error
	for _, e := range j.Entries {
		if err := h.Stop(e.Unit); err != nil {
			errs = append(errs, err)
		}
	}
	if len(errs) > 0 {
		return errors.Join(errs...)
	}
	for _, e := range j.Entries {
		if err := InstallExecutable(e.Backup, e.Destination); err != nil {
			errs = append(errs, err)
		}
		if err := syncEngineDirectory(filepath.Dir(e.Destination)); err != nil {
			errs = append(errs, err)
		}
	}
	for _, e := range j.Entries {
		if e.Active {
			if err := h.Start(e.Unit); err != nil {
				errs = append(errs, err)
			} else if err := h.Healthy(e.Unit); err != nil {
				errs = append(errs, err)
			}
		}
	}
	return errors.Join(errs...)
}

func syncEngineDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func engineContentHash(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
