package pnserver

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strconv"
)

type ProxyPorts struct {
	Reality   int
	Hysteria2 int
}

// ManagedConfigPorts accepts both shared and per-user authentication. It checks
// the supported listener layout and its agreement with the published node.
func ManagedConfigPorts(config ManagedConfig) (ProxyPorts, error) {
	var profile NodeProfile
	if jsonUnmarshalStrict(config.Node, &profile) != nil || profile.Version != nodeProfileVersion || len(profile.Protocols) != 2 {
		return ProxyPorts{}, errors.New("unsupported node profile")
	}
	ports := ProxyPorts{}
	for _, p := range profile.Protocols {
		switch {
		case p.Type == "vless-reality" && p.VLESSReality != nil && p.Hysteria2 == nil && ports.Reality == 0:
			ports.Reality = p.VLESSReality.ServerPort
		case p.Type == "hysteria2" && p.Hysteria2 != nil && p.VLESSReality == nil && ports.Hysteria2 == 0:
			ports.Hysteria2 = p.Hysteria2.ServerPort
		default:
			return ProxyPorts{}, errors.New("unsupported node protocols")
		}
	}
	if err := ports.validate(); err != nil {
		return ProxyPorts{}, err
	}
	var x struct {
		Inbounds []struct {
			Port           int    `json:"port"`
			Protocol       string `json:"protocol"`
			StreamSettings struct {
				Security string `json:"security"`
				Network  string `json:"network"`
			} `json:"streamSettings"`
		} `json:"inbounds"`
	}
	var h struct {
		Listen string `json:"listen"`
	}
	if json.Unmarshal(config.Xray, &x) != nil || len(x.Inbounds) != 1 || x.Inbounds[0].Protocol != "vless" ||
		x.Inbounds[0].StreamSettings.Security != "reality" || x.Inbounds[0].StreamSettings.Network != "tcp" || x.Inbounds[0].Port != ports.Reality {
		return ProxyPorts{}, errors.New("unsupported or mismatched Reality listener")
	}
	if json.Unmarshal(config.Hysteria, &h) != nil {
		return ProxyPorts{}, errors.New("invalid Hysteria2 configuration")
	}
	host, port, err := net.SplitHostPort(h.Listen)
	if err != nil || (host != "" && host != "0.0.0.0" && host != "::") || port != strconv.Itoa(ports.Hysteria2) {
		return ProxyPorts{}, errors.New("unsupported or mismatched Hysteria2 listener")
	}
	return ports, nil
}

func (p ProxyPorts) validate() error {
	if p.Reality < 1 || p.Reality > 65535 || p.Hysteria2 < 1 || p.Hysteria2 > 65535 {
		return errors.New("端口必须介于 1 和 65535 之间")
	}
	return nil
}

// ChangePorts only edits listener ports and node metadata. Unlike provisioning,
// it never regenerates credentials or rebuilds authentication configuration.
// The engine lock serializes this operation with user sync and engine updates.
func (s *Store) ChangePorts(servicesDir, revision string, ports ProxyPorts, hooks ManagedConfigHooks) error {
	if err := ports.validate(); err != nil {
		return err
	}
	return s.WithEngineOperationLock(func() error {
		if _, err := os.Lstat(filepath.Join(s.Dir, "user-proxy-update.json")); err == nil {
			return errors.New("存在未完成的用户配置更新，请先运行 pendingnet-server sync-users 恢复")
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		original, err := s.ReadManagedConfig(servicesDir)
		if err != nil {
			return err
		}
		if original.Revision != revision {
			return ErrManagedConfigConflict
		}
		oldPorts, err := ManagedConfigPorts(original)
		if err != nil {
			return err
		}
		if ports == oldPorts {
			return nil
		}
		candidate := original
		var profile NodeProfile
		if err := jsonUnmarshalStrict(original.Node, &profile); err != nil {
			return err
		}
		for i := range profile.Protocols {
			if n := profile.Protocols[i].VLESSReality; n != nil {
				n.ServerPort = ports.Reality
			}
			if n := profile.Protocols[i].Hysteria2; n != nil {
				n.ServerPort = ports.Hysteria2
			}
		}
		profile.UpdatedAt = s.now()
		candidate.Node, err = json.MarshalIndent(profile, "", "  ")
		if err != nil {
			return err
		}
		// RawMessage preserves unrelated fields, credentials and numeric values.
		var x, h map[string]json.RawMessage
		if err = json.Unmarshal(original.Xray, &x); err != nil {
			return err
		}
		if err = json.Unmarshal(original.Hysteria, &h); err != nil {
			return err
		}
		var inbounds []map[string]json.RawMessage
		if err = json.Unmarshal(x["inbounds"], &inbounds); err != nil {
			return err
		}
		inbounds[0]["port"], _ = json.Marshal(ports.Reality)
		x["inbounds"], err = json.Marshal(inbounds)
		if err != nil {
			return err
		}
		var listen string
		if err = json.Unmarshal(h["listen"], &listen); err != nil {
			return err
		}
		host, _, _ := net.SplitHostPort(listen)
		h["listen"], _ = json.Marshal(net.JoinHostPort(host, strconv.Itoa(ports.Hysteria2)))
		candidate.Xray, err = json.MarshalIndent(x, "", "  ")
		if err != nil {
			return err
		}
		candidate.Hysteria, err = json.MarshalIndent(h, "", "  ")
		if err != nil {
			return err
		}
		// The candidate is derived solely from the current snapshot, so auth
		// stays untouched, including userpass layouts unsupported by the editor.
		return s.applyManagedConfig(servicesDir, candidate, hooks, func(c ManagedConfig, _ string) error {
			_, err := ManagedConfigPorts(c)
			return err
		})
	})
}
