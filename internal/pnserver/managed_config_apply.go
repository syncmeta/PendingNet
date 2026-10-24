package pnserver

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

var (
	ErrManagedConfigConflict    = errors.New("managed configuration changed since it was read")
	ErrManagedConfigInvalid     = errors.New("managed configuration is invalid")
	ErrManagedConfigUnavailable = errors.New("managed configuration validation and restart are unavailable")
)

type ManagedConfigPaths struct {
	Node     string
	Xray     string
	Hysteria string
}

// Production callers must supply both hooks. Validate must inspect all staged
// files before any live file changes; Restart must verify both data-plane units
// are healthy before returning nil. Neither hook may expose config contents in
// its errors, because callers can surface those errors in management UI.
type ManagedConfigHooks struct {
	Validate func(ManagedConfigPaths) error
	Restart  func() error
}

// ApplyManagedConfig validates a full data-plane snapshot, checks its revision,
// retains private rollback material, then installs all three documents. If
// restart fails it restores every original and restarts again. Individual
// files are atomically replaced; the group is not crash-atomic, so the retained
// backup is also the manual recovery source after a machine crash.
func (s *Store) ApplyManagedConfig(servicesDir string, candidate ManagedConfig, hooks ManagedConfigHooks) error {
	return s.applyManagedConfig(servicesDir, candidate, hooks, ValidateManagedConfigConsistency)
}

func (s *Store) applyManagedConfig(servicesDir string, candidate ManagedConfig, hooks ManagedConfigHooks, validate func(ManagedConfig, string) error) error {
	if hooks.Validate == nil || hooks.Restart == nil {
		return ErrManagedConfigUnavailable
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	original, err := s.readManagedConfigLocked(servicesDir)
	if err != nil {
		return err
	}
	if candidate.Revision != original.Revision {
		return ErrManagedConfigConflict
	}
	if err := validateManagedCandidate(candidate, original.Node); err != nil {
		return fmt.Errorf("%w: %v", ErrManagedConfigInvalid, err)
	}
	if servicesDir == "" {
		servicesDir = DefaultServicesDir
	}
	if err := validate(candidate, servicesDir); err != nil {
		return fmt.Errorf("%w: %v", ErrManagedConfigInvalid, err)
	}
	stage, err := os.MkdirTemp(s.Dir, ".managed-stage-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	staged := ManagedConfigPaths{
		Node:     filepath.Join(stage, "node.json"),
		Xray:     filepath.Join(stage, "xray.json"),
		Hysteria: filepath.Join(stage, "hysteria.json"),
	}
	for _, item := range []struct {
		path string
		data []byte
	}{
		{staged.Node, candidate.Node}, {staged.Xray, candidate.Xray}, {staged.Hysteria, candidate.Hysteria},
	} {
		if err := os.WriteFile(item.path, item.data, 0o600); err != nil {
			return err
		}
	}
	if err := hooks.Validate(staged); err != nil {
		return fmt.Errorf("%w: %v", ErrManagedConfigInvalid, err)
	}
	// A CLI or other process may have changed files while validation ran.
	latest, err := s.readManagedConfigLocked(servicesDir)
	if err != nil {
		return err
	}
	if latest.Revision != original.Revision {
		return ErrManagedConfigConflict
	}
	if err := s.saveManagedBackup(original); err != nil {
		return err
	}
	live := ManagedConfigPaths{
		Node:     s.nodePath(),
		Xray:     filepath.Join(servicesDir, "xray.json"),
		Hysteria: filepath.Join(servicesDir, "hysteria.json"),
	}
	items := []struct {
		path        string
		next, prior []byte
	}{
		{live.Node, candidate.Node, original.Node},
		{live.Xray, candidate.Xray, original.Xray},
		{live.Hysteria, candidate.Hysteria, original.Hysteria},
	}
	for _, item := range items {
		if err := writeFileAtomic(item.path, item.next, 0o600); err != nil {
			return errors.Join(fmt.Errorf("install managed configuration: %w", err), restoreManagedFiles(items))
		}
	}
	if err := hooks.Restart(); err != nil {
		rollbackErr := restoreManagedFiles(items)
		if rollbackErr != nil {
			return errors.Join(fmt.Errorf("restart managed services: %w", err),
				fmt.Errorf("restore managed configuration: %w", rollbackErr))
		}
		return errors.Join(fmt.Errorf("restart managed services: %w", err), hooks.Restart())
	}
	return nil
}

func validateManagedCandidate(candidate ManagedConfig, originalNode []byte) error {
	for _, data := range [][]byte{candidate.Node, candidate.Xray, candidate.Hysteria} {
		if len(data) == 0 || len(data) > maxManagedConfigBytes || !json.Valid(data) {
			return errors.New("managed configuration must contain bounded JSON documents")
		}
	}
	var oldProfile, nextProfile NodeProfile
	if err := jsonUnmarshalStrict(originalNode, &oldProfile); err != nil {
		return err
	}
	if err := jsonUnmarshalStrict(candidate.Node, &nextProfile); err != nil {
		return err
	}
	if nextProfile.Version != nodeProfileVersion || nextProfile.ServerID != oldProfile.ServerID ||
		len(nextProfile.Protocols) == 0 {
		return errors.New("managed node profile has invalid identity or protocols")
	}
	return nil
}

func restoreManagedFiles(items []struct {
	path        string
	next, prior []byte
}) error {
	var failures []error
	for _, item := range items {
		if err := writeFileAtomic(item.path, item.prior, 0o600); err != nil {
			failures = append(failures, err)
		}
	}
	return errors.Join(failures...)
}

func (s *Store) saveManagedBackup(original ManagedConfig) error {
	base := filepath.Join(s.Dir, "management-backups")
	if err := os.MkdirAll(base, 0o700); err != nil {
		return err
	}
	if info, err := os.Lstat(base); err != nil || !info.IsDir() || info.Mode().Perm() != 0o700 {
		return errors.New("management backup directory is not private")
	}
	dest := filepath.Join(base, original.Revision)
	if info, err := os.Lstat(dest); err == nil {
		if !info.IsDir() || info.Mode().Perm() != 0o700 {
			return errors.New("management backup is not private")
		}
		for name, want := range map[string][]byte{
			"node.json": original.Node, "xray.json": original.Xray, "hysteria.json": original.Hysteria,
		} {
			got, readErr := readManagedFile(filepath.Join(dest, name))
			if readErr != nil || !bytes.Equal(got, want) {
				return errors.New("existing management backup does not match current revision")
			}
		}
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	temp, err := os.MkdirTemp(base, ".pending-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)
	for name, data := range map[string][]byte{
		"node.json": original.Node, "xray.json": original.Xray, "hysteria.json": original.Hysteria,
	} {
		if err := os.WriteFile(filepath.Join(temp, name), data, 0o600); err != nil {
			return err
		}
	}
	return os.Rename(temp, dest)
}
