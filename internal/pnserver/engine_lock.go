package pnserver

import (
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
)

//go:embed upstream-lock.json
var engineLockJSON []byte

type EngineAsset struct {
	URL    string `json:"url"`
	Digest string `json:"digest"`
}
type LockedEngine struct {
	Version string                 `json:"version"`
	Assets  map[string]EngineAsset `json:"assets"`
}
type EngineLock struct {
	PendingNet struct {
		Version string `json:"version"`
		Build   string `json:"build"`
	} `json:"pendingnet"`
	Schema     int          `json:"schema"`
	CapturedAt string       `json:"captured_at"`
	Xray       LockedEngine `json:"xray"`
	Hysteria2  LockedEngine `json:"hysteria2"`
	SingBox    struct {
		Version string `json:"version"`
		Commit  string `json:"commit"`
	} `json:"sing_box"`
}

func ReleaseEngineLock() (EngineLock, error) {
	var lock EngineLock
	if err := json.Unmarshal(engineLockJSON, &lock); err != nil {
		return lock, err
	}
	if lock.Schema != 1 || lock.CapturedAt == "" || lock.PendingNet.Version == "" || lock.PendingNet.Build == "" {
		return lock, fmt.Errorf("invalid release engine lock")
	}
	for _, engine := range []LockedEngine{lock.Xray, lock.Hysteria2} {
		if engine.Version == "" {
			return lock, fmt.Errorf("missing locked engine version")
		}
		for _, arch := range []string{"amd64", "arm64"} {
			asset, ok := engine.Assets[arch]
			u, err := url.Parse(asset.URL)
			if !ok || err != nil || u.Scheme != "https" || u.Host != "github.com" || u.User != nil || u.RawQuery != "" || !strings.Contains(u.Path, "/releases/download/"+engine.Version+"/") {
				return lock, fmt.Errorf("invalid locked asset for %s", arch)
			}
			algorithm, hash, ok := strings.Cut(asset.Digest, ":")
			if !ok || algorithm != "sha256" || len(hash) != 64 {
				return lock, fmt.Errorf("invalid locked digest")
			}
			if _, err := hex.DecodeString(hash); err != nil {
				return lock, err
			}
		}
	}
	if !strings.HasPrefix(lock.SingBox.Version, "v") || len(lock.SingBox.Commit) != 40 {
		return lock, fmt.Errorf("invalid sing-box source lock")
	}
	if _, err := hex.DecodeString(lock.SingBox.Commit); err != nil {
		return lock, err
	}
	return lock, nil
}
