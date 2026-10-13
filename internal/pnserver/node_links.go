package pnserver

import (
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
)

type NodeLink struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

// BuildNodeLinks exports existing credentials; it never rotates a server key.
func BuildNodeLinks(profile NodeProfile, name string) ([]NodeLink, error) {
	links := make([]NodeLink, 0, len(profile.Protocols))
	for _, p := range profile.Protocols {
		u := url.URL{Fragment: name}
		q := url.Values{}
		switch {
		case p.Type == "vless-reality" && p.VLESSReality != nil:
			n := p.VLESSReality
			if n.Server == "" || n.ServerPort < 1 || n.ServerPort > 65535 || n.UUID == "" || n.PublicKey == "" || n.ServerName == "" || n.ShortID == "" {
				return nil, errors.New("Reality connection fields are incomplete")
			}
			u.Scheme = "vless"
			u.User = url.User(n.UUID)
			u.Host = net.JoinHostPort(n.Server, strconv.Itoa(n.ServerPort))
			q = url.Values{"security": {"reality"}, "encryption": {"none"}, "type": {"tcp"}, "flow": {n.Flow}, "sni": {n.ServerName}, "pbk": {n.PublicKey}, "sid": {n.ShortID}, "fp": {"chrome"}}
		case p.Type == "hysteria2" && p.Hysteria2 != nil:
			n := p.Hysteria2
			if n.Server == "" || n.ServerPort < 1 || n.ServerPort > 65535 || n.Password == "" {
				return nil, errors.New("Hysteria2 connection fields are incomplete")
			}
			u.Scheme = "hysteria2"
			u.User = url.User(n.Password)
			u.Host = net.JoinHostPort(n.Server, strconv.Itoa(n.ServerPort))
			q.Set("sni", n.ServerName)
			if n.ObfsType != "" {
				q.Set("obfs", n.ObfsType)
			}
			if n.ObfsPassword != "" {
				q.Set("obfs-password", n.ObfsPassword)
			}
			if n.CertificatePublicKeySHA256 != "" {
				pin, err := hex.DecodeString(n.CertificateSHA256)
				if err != nil || len(pin) != 32 {
					return nil, errors.New("Hysteria2 certificate fingerprint is unavailable; use a PendingNet pairing link")
				}
				q.Set("pinSHA256", n.CertificateSHA256)
				q.Set("insecure", "1")
				q.Set("pendingnet-spki", n.CertificatePublicKeySHA256)
			}
		default:
			return nil, fmt.Errorf("unsupported node protocol %q", p.Type)
		}
		u.RawQuery = q.Encode()
		links = append(links, NodeLink{Name: p.DisplayName, URL: u.String()})
	}
	if len(links) == 0 {
		return nil, ErrNodeProfileNotFound
	}
	return links, nil
}
