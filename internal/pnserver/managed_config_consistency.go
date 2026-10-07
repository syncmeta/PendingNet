package pnserver

import (
	"crypto/ecdh"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"path/filepath"
	"strconv"
)

// ValidateManagedConfigConsistency checks the client-facing node profile
// against the supported, PendingNet-provisioned Reality and Hysteria2 engines.
// It deliberately rejects unfamiliar inbound/auth layouts instead of
// publishing a node profile that could strand every client. This is only a
// consistency check, not an engine-native syntax test or restart health check.
func ValidateManagedConfigConsistency(config ManagedConfig, servicesDir string) error {
	if !filepath.IsAbs(servicesDir) {
		return errors.New("services directory must be absolute")
	}
	var profile NodeProfile
	if err := jsonUnmarshalStrict(config.Node, &profile); err != nil {
		return errors.New("invalid node profile")
	}
	if profile.Version != nodeProfileVersion || len(profile.Protocols) != 2 {
		return errors.New("unsupported node protocols")
	}
	var reality *VLESSReality
	var hysteria *Hysteria2Node
	for _, protocol := range profile.Protocols {
		switch protocol.Type {
		case "vless-reality":
			if reality != nil || protocol.VLESSReality == nil || protocol.Hysteria2 != nil {
				return errors.New("invalid Reality node")
			}
			reality = protocol.VLESSReality
		case "hysteria2":
			if hysteria != nil || protocol.Hysteria2 == nil || protocol.VLESSReality != nil {
				return errors.New("invalid Hysteria2 node")
			}
			hysteria = protocol.Hysteria2
		default:
			return errors.New("unsupported node protocol")
		}
	}
	if reality == nil || hysteria == nil || reality.Server == "" || reality.Server != hysteria.Server ||
		reality.ServerPort < 1 || hysteria.ServerPort < 1 || reality.ServerPort > 65535 || hysteria.ServerPort > 65535 {
		return errors.New("node endpoints are invalid")
	}
	if err := validateManagedReality(config.Xray, reality); err != nil {
		return err
	}
	return validateManagedHysteria(config.Hysteria, hysteria, servicesDir)
}

func validateManagedReality(data []byte, node *VLESSReality) error {
	var cfg struct {
		Inbounds []struct {
			Port     int    `json:"port"`
			Protocol string `json:"protocol"`
			Settings struct {
				Clients []struct {
					ID   string `json:"id"`
					Flow string `json:"flow"`
				} `json:"clients"`
			} `json:"settings"`
			StreamSettings struct {
				Network         string `json:"network"`
				Security        string `json:"security"`
				RealitySettings struct {
					PrivateKey  string   `json:"privateKey"`
					ServerNames []string `json:"serverNames"`
					ShortIDs    []string `json:"shortIds"`
				} `json:"realitySettings"`
			} `json:"streamSettings"`
		} `json:"inbounds"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil || len(cfg.Inbounds) != 1 {
		return errors.New("unsupported Reality inbound configuration")
	}
	inbound := cfg.Inbounds[0]
	if inbound.Protocol != "vless" || inbound.Port != node.ServerPort || len(inbound.Settings.Clients) != 1 ||
		inbound.StreamSettings.Network != "tcp" || inbound.StreamSettings.Security != "reality" {
		return errors.New("Reality inbound does not match node")
	}
	client := inbound.Settings.Clients[0]
	if client.ID != node.UUID || client.Flow != node.Flow ||
		!containsString(inbound.StreamSettings.RealitySettings.ServerNames, node.ServerName) ||
		!containsString(inbound.StreamSettings.RealitySettings.ShortIDs, node.ShortID) {
		return errors.New("Reality credentials do not match node")
	}
	privateBytes, err := base64.RawURLEncoding.DecodeString(inbound.StreamSettings.RealitySettings.PrivateKey)
	if err != nil {
		return errors.New("invalid Reality private key")
	}
	privateKey, err := ecdh.X25519().NewPrivateKey(privateBytes)
	if err != nil || base64.RawURLEncoding.EncodeToString(privateKey.PublicKey().Bytes()) != node.PublicKey {
		return errors.New("Reality public key does not match node")
	}
	return nil
}

func validateManagedHysteria(data []byte, node *Hysteria2Node, servicesDir string) error {
	var cfg struct {
		Listen string `json:"listen"`
		TLS    struct {
			Cert string `json:"cert"`
			Key  string `json:"key"`
		} `json:"tls"`
		Auth struct {
			Type     string `json:"type"`
			Password string `json:"password"`
		} `json:"auth"`
		Obfs struct {
			Type       string `json:"type"`
			Salamander struct {
				Password string `json:"password"`
			} `json:"salamander"`
		} `json:"obfs"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return errors.New("invalid Hysteria2 configuration")
	}
	host, portText, err := net.SplitHostPort(cfg.Listen)
	if err != nil || (host != "" && host != "0.0.0.0" && host != "::") {
		return errors.New("Hysteria2 listen address is invalid")
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port != node.ServerPort || cfg.Auth.Type != "password" || cfg.Auth.Password != node.Password ||
		cfg.Obfs.Type != node.ObfsType || cfg.Obfs.Salamander.Password != node.ObfsPassword {
		return errors.New("Hysteria2 credentials or port do not match node")
	}
	certPath, keyPath := filepath.Join(servicesDir, "hysteria.crt"), filepath.Join(servicesDir, "hysteria.key")
	if cfg.TLS.Cert != certPath || cfg.TLS.Key != keyPath {
		return errors.New("Hysteria2 certificate paths are not managed")
	}
	certPEM, err := readManagedFile(certPath)
	if err != nil {
		return fmt.Errorf("read managed certificate: %w", err)
	}
	keyPEM, err := readManagedFile(keyPath)
	if err != nil {
		return fmt.Errorf("read managed certificate key: %w", err)
	}
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return errors.New("Hysteria2 certificate and key do not match")
	}
	certificate, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil || certificate.VerifyHostname(node.ServerName) != nil {
		return errors.New("Hysteria2 certificate does not match node name")
	}
	pin := sha256.Sum256(certificate.RawSubjectPublicKeyInfo)
	if base64.StdEncoding.EncodeToString(pin[:]) != node.CertificatePublicKeySHA256 {
		return errors.New("Hysteria2 certificate pin does not match node")
	}
	return nil
}

func containsString(items []string, want string) bool {
	if want == "" {
		return false
	}
	for _, item := range items {
		if item == want {
			return true
		}
	}
	return false
}
