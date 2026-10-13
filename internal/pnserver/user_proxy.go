package pnserver

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

const XrayStatsAddress = "127.0.0.1:17446"
const HysteriaStatsAddress = "127.0.0.1:17445"

type UserProxyAccount struct {
	UUID     string `json:"uuid"`
	Password string `json:"password"`
}
type UserProxyAccounts struct {
	Version     int                         `json:"version"`
	StatsSecret string                      `json:"stats_secret"`
	Users       map[string]UserProxyAccount `json:"users"`
}

// Hysteria usernames are case-insensitive. Hex preserves a unique, stable
// mapping even though PendingNet user IDs contain mixed-case base64 characters.
func UserHysteriaName(userID string) string { return hex.EncodeToString([]byte(userID)) }

func (s *Store) EnsureUserProxyAccounts() (UserProxyAccounts, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	unlock, err := lockStateFile(filepath.Join(s.Dir, "state.lock"))
	if err != nil {
		return UserProxyAccounts{}, err
	}
	defer unlock()
	state, err := s.loadState()
	if err != nil {
		return UserProxyAccounts{}, err
	}
	path := filepath.Join(s.Dir, "user-proxy.json")
	data, err := os.ReadFile(path)
	accounts := UserProxyAccounts{Version: 1, Users: map[string]UserProxyAccount{}}
	changed := errors.Is(err, os.ErrNotExist)
	if err == nil {
		if err = jsonUnmarshalStrict(data, &accounts); err != nil {
			return accounts, err
		}
		if accounts.Version != 1 || accounts.Users == nil || accounts.StatsSecret == "" {
			return accounts, errors.New("invalid user proxy accounts")
		}
	} else if !changed {
		return accounts, err
	}
	if accounts.StatsSecret == "" {
		accounts.StatsSecret, err = randomValue(s.randReader(), "", 32)
		if err != nil {
			return accounts, err
		}
	}
	for _, u := range state.Users {
		if _, ok := accounts.Users[u.ID]; ok {
			continue
		}
		uuid, err := randomUUID(s.randReader())
		if err != nil {
			return accounts, err
		}
		password, err := randomValue(s.randReader(), "", 32)
		if err != nil {
			return accounts, err
		}
		accounts.Users[u.ID] = UserProxyAccount{UUID: uuid, Password: password}
		changed = true
	}
	if changed {
		if err := writePrivateJSON(path, accounts); err != nil {
			return accounts, err
		}
	}
	return accounts, nil
}

func (s *Store) UserTrafficEnabled() bool {
	_, err := os.Stat(filepath.Join(s.Dir, "user-proxy.json"))
	return err == nil
}

func (s *Store) UserNodeProfile(userID string) (NodeProfile, error) {
	state, err := s.Load()
	if err != nil {
		return NodeProfile{}, err
	}
	i := indexUser(state.Users, userID)
	if i < 0 || state.Users[i].RevokedAt != nil {
		return NodeProfile{}, ErrUnauthorized
	}
	accounts, err := s.EnsureUserProxyAccounts()
	if err != nil {
		return NodeProfile{}, err
	}
	key, ok := accounts.Users[userID]
	if !ok {
		return NodeProfile{}, ErrUserNotFound
	}
	profile, err := s.LoadNodeProfile()
	if err != nil {
		return NodeProfile{}, err
	}
	for i := range profile.Protocols {
		if n := profile.Protocols[i].VLESSReality; n != nil {
			n.UUID = key.UUID
		}
		if n := profile.Protocols[i].Hysteria2; n != nil {
			n.Password = UserHysteriaName(userID) + ":" + key.Password
		}
	}
	return profile, nil
}

// Existing Reality identity, TLS certificates, obfuscation and listener ports
// survive migration. Every old shared authentication credential is removed.
func BuildUserProxyConfigs(xray, hysteria json.RawMessage, state State, accounts UserProxyAccounts) ([]byte, []byte, error) {
	var x, h map[string]any
	if json.Unmarshal(xray, &x) != nil || json.Unmarshal(hysteria, &h) != nil {
		return nil, nil, errors.New("invalid engine configuration")
	}
	clients := []any{}
	passwords := map[string]string{}
	for _, u := range state.Users {
		if u.RevokedAt != nil {
			continue
		}
		key, ok := accounts.Users[u.ID]
		if !ok || key.UUID == "" || key.Password == "" {
			return nil, nil, errors.New("user proxy key missing")
		}
		clients = append(clients, map[string]any{"id": key.UUID, "email": u.ID, "level": 0, "flow": "xtls-rprx-vision"})
		passwords[UserHysteriaName(u.ID)] = key.Password
	}
	inbounds, ok := x["inbounds"].([]any)
	if !ok {
		return nil, nil, errors.New("Xray inbounds missing")
	}
	found := false
	for _, raw := range inbounds {
		inbound, ok := raw.(map[string]any)
		if !ok || inbound["protocol"] != "vless" {
			continue
		}
		settings, ok := inbound["settings"].(map[string]any)
		if !ok {
			return nil, nil, errors.New("VLESS settings missing")
		}
		settings["clients"] = clients
		found = true
	}
	if !found {
		return nil, nil, errors.New("Reality inbound missing")
	}
	x["api"] = map[string]any{"tag": "pendingnet-stats", "listen": XrayStatsAddress, "services": []string{"StatsService"}}
	x["stats"] = map[string]any{}
	policy, _ := x["policy"].(map[string]any)
	if policy == nil {
		policy = map[string]any{}
	}
	levels, _ := policy["levels"].(map[string]any)
	if levels == nil {
		levels = map[string]any{}
	}
	level, _ := levels["0"].(map[string]any)
	if level == nil {
		level = map[string]any{}
	}
	level["statsUserUplink"] = true
	level["statsUserDownlink"] = true
	levels["0"] = level
	policy["levels"] = levels
	x["policy"] = policy
	if len(passwords) == 0 {
		// Hysteria rejects an empty userpass map. This unreachable account has
		// no pairing or exported profile and never preserves an old credential.
		disabled := sha256.Sum256([]byte(accounts.StatsSecret + "/no-active-users"))
		passwords["pendingnet-disabled"] = hex.EncodeToString(disabled[:])
	}
	h["auth"] = map[string]any{"type": "userpass", "userpass": passwords}
	h["trafficStats"] = map[string]any{"listen": HysteriaStatsAddress, "secret": accounts.StatsSecret}
	xb, err := json.MarshalIndent(x, "", "  ")
	if err != nil {
		return nil, nil, err
	}
	hb, err := json.MarshalIndent(h, "", "  ")
	return xb, hb, err
}
