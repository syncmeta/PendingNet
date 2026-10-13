package pnserver

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

type userProxyJournal struct {
	ServicesDir string `json:"services_dir"`
	Xray        []byte `json:"xray"`
	Hysteria    []byte `json:"hysteria"`
}

// The engine update lock also protects configuration replacement. A retained
// journal restores interrupted multi-file updates before any new changes.
func (s *Store) SyncUserProxyServices(servicesDir string, hooks ManagedConfigHooks) error {
	if hooks.Validate == nil || hooks.Restart == nil {
		return ErrManagedConfigUnavailable
	}
	if !filepath.IsAbs(servicesDir) {
		return errors.New("services directory must be absolute")
	}
	unlock, err := lockStateFile(filepath.Join(s.Dir, "engine-update.lock"))
	if err != nil {
		return err
	}
	defer unlock()
	live := ManagedConfigPaths{Node: s.nodePath(), Xray: filepath.Join(servicesDir, "xray.json"), Hysteria: filepath.Join(servicesDir, "hysteria.json")}
	journalPath := filepath.Join(s.Dir, "user-proxy-update.json")
	restore := func(j userProxyJournal) error {
		if j.ServicesDir != servicesDir || !json.Valid(j.Xray) || !json.Valid(j.Hysteria) {
			return errors.New("invalid user proxy recovery journal")
		}
		err := errors.Join(writeFileAtomic(live.Xray, j.Xray, 0600), writeFileAtomic(live.Hysteria, j.Hysteria, 0600))
		if err != nil {
			return err
		}
		if err = hooks.Restart(); err != nil {
			return err
		}
		return os.Remove(journalPath)
	}
	if data, err := os.ReadFile(journalPath); err == nil {
		var old userProxyJournal
		if jsonUnmarshalStrict(data, &old) != nil {
			return errors.New("invalid user proxy recovery journal")
		}
		if err = restore(old); err != nil {
			return fmt.Errorf("recover interrupted user update: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	accounts, err := s.EnsureUserProxyAccounts()
	if err != nil {
		return err
	}
	state, err := s.Load()
	if err != nil {
		return err
	}
	originalX, err := os.ReadFile(live.Xray)
	if err != nil {
		return err
	}
	originalH, err := os.ReadFile(live.Hysteria)
	if err != nil {
		return err
	}
	x, h, err := BuildUserProxyConfigs(originalX, originalH, state, accounts)
	if err != nil {
		return err
	}
	if bytes.Equal(x, originalX) && bytes.Equal(h, originalH) {
		return nil
	}
	stage, err := os.MkdirTemp(s.Dir, ".user-proxy-stage-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	staged := ManagedConfigPaths{Node: live.Node, Xray: filepath.Join(stage, "xray.json"), Hysteria: filepath.Join(stage, "hysteria.json")}
	if err = writeFileAtomic(staged.Xray, x, 0600); err != nil {
		return err
	}
	if err = writeFileAtomic(staged.Hysteria, h, 0600); err != nil {
		return err
	}
	if err = hooks.Validate(staged); err != nil {
		return fmt.Errorf("validate user proxy configuration: %w", err)
	}
	old := userProxyJournal{ServicesDir: servicesDir, Xray: originalX, Hysteria: originalH}
	if err = writePrivateJSON(journalPath, old); err != nil {
		return err
	}
	if err = writeFileAtomic(live.Xray, x, 0600); err == nil {
		err = writeFileAtomic(live.Hysteria, h, 0600)
	}
	if err == nil {
		err = hooks.Restart()
	}
	if err != nil {
		return errors.Join(fmt.Errorf("apply user proxy configuration: %w", err), restore(old))
	}
	return os.Remove(journalPath)
}

func (s *Store) PairingUserID(token string) (string, error) {
	state, err := s.Load()
	if err != nil {
		return "", err
	}
	want := hashToken(token)
	for _, grant := range state.Pairings {
		if secureEqual(grant.TokenSHA256, want) {
			return grant.UserID, nil
		}
	}
	return "", ErrInvalidPairing
}

// Serialize explicit service operations with configuration and binary updates.
func (s *Store) WithEngineOperationLock(operation func() error) error {
	unlock, err := lockStateFile(filepath.Join(s.Dir, "engine-update.lock"))
	if err != nil {
		return err
	}
	defer unlock()
	return operation()
}
