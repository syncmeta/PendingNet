package pnserver

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

const maxManagedConfigBytes = 1 << 20

var ErrManagedConfigNotFound = errors.New("managed configuration is not provisioned")

// ManagedConfig is the data-plane configuration an administrator may inspect.
// Control-plane identity, TLS private key, users and token hashes are excluded.
// Node and engine documents can still contain client/server secrets, so this
// value must only be returned to an authenticated administrator over pinned TLS.
type ManagedConfig struct {
	Revision string          `json:"revision"`
	Node     json.RawMessage `json:"node"`
	Xray     json.RawMessage `json:"xray"`
	Hysteria json.RawMessage `json:"hysteria"`
}

func (s *Store) ReadManagedConfig(servicesDir string) (ManagedConfig, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.readManagedConfigLocked(servicesDir)
}

func (s *Store) readManagedConfigLocked(servicesDir string) (ManagedConfig, error) {
	if servicesDir == "" {
		servicesDir = DefaultServicesDir
	}
	if !filepath.IsAbs(servicesDir) {
		return ManagedConfig{}, errors.New("services directory must be absolute")
	}
	state, err := s.loadState()
	if err != nil {
		return ManagedConfig{}, err
	}
	node, err := readManagedFile(s.nodePath())
	if err != nil {
		return ManagedConfig{}, err
	}
	xray, err := readManagedFile(filepath.Join(servicesDir, "xray.json"))
	if err != nil {
		return ManagedConfig{}, err
	}
	hysteria, err := readManagedFile(filepath.Join(servicesDir, "hysteria.json"))
	if err != nil {
		return ManagedConfig{}, err
	}
	var profile NodeProfile
	if err := jsonUnmarshalStrict(node, &profile); err != nil ||
		profile.Version != nodeProfileVersion || profile.ServerID != state.ServerID || len(profile.Protocols) == 0 {
		return ManagedConfig{}, errors.New("managed node profile is invalid")
	}
	if !json.Valid(xray) || !json.Valid(hysteria) {
		return ManagedConfig{}, errors.New("managed engine configuration is invalid JSON")
	}
	hash := sha256.New()
	for _, part := range []struct {
		name string
		data []byte
	}{
		{"node", node}, {"xray", xray}, {"hysteria", hysteria},
	} {
		_, _ = fmt.Fprintf(hash, "%s:%d:", part.name, len(part.data))
		_, _ = hash.Write(part.data)
	}
	return ManagedConfig{
		Revision: hex.EncodeToString(hash.Sum(nil)),
		Node:     json.RawMessage(node), Xray: json.RawMessage(xray), Hysteria: json.RawMessage(hysteria),
	}, nil
}

func readManagedFile(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrManagedConfigNotFound
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > maxManagedConfigBytes {
		return nil, errors.New("managed configuration file is not a bounded regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	b, err := io.ReadAll(io.LimitReader(file, maxManagedConfigBytes+1))
	if err != nil {
		return nil, err
	}
	if len(b) > maxManagedConfigBytes {
		return nil, errors.New("managed configuration file is too large")
	}
	return b, nil
}
