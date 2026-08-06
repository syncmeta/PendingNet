package pnserver

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"strconv"
	"strings"
	"time"
)

const (
	DefaultXrayBinary     = "/usr/local/bin/xray"
	DefaultHysteriaBinary = "/usr/local/bin/hysteria"
	DefaultServicesDir    = "/etc/pendingnet/services"
)

type ProvisionOptions struct {
	ServerIP       string
	RealitySNI     string
	XrayPort       int
	Hysteria2Port  int
	XrayBinary     string
	HysteriaBinary string
	ServicesDir    string
}

type ProvisionArtifacts struct {
	NodeProfile         NodeProfile
	XrayConfig          []byte
	Hysteria2Config     []byte
	Hysteria2CertPEM    []byte
	Hysteria2KeyPEM     []byte
	XraySystemdUnit     string
	HysteriaSystemdUnit string
}

// BuildProvisionArtifacts creates a fresh, policy-free Reality/Hysteria2
// server identity. It performs no filesystem or network mutations, which
// keeps provisioning configuration fully testable before it is applied.
func BuildProvisionArtifacts(opts ProvisionOptions, reader io.Reader, now time.Time) (ProvisionArtifacts, error) {
	opts = provisionDefaults(opts)
	if err := validateProvisionOptions(opts); err != nil {
		return ProvisionArtifacts{}, err
	}
	if reader == nil {
		reader = rand.Reader
	}

	realityPrivate, err := ecdh.X25519().GenerateKey(reader)
	if err != nil {
		return ProvisionArtifacts{}, fmt.Errorf("generate Reality key: %w", err)
	}
	realityPrivateText := base64.RawURLEncoding.EncodeToString(realityPrivate.Bytes())
	realityPublicText := base64.RawURLEncoding.EncodeToString(realityPrivate.PublicKey().Bytes())
	uuid, err := randomUUID(reader)
	if err != nil {
		return ProvisionArtifacts{}, err
	}
	shortIDBytes := make([]byte, 8)
	if _, err := io.ReadFull(reader, shortIDBytes); err != nil {
		return ProvisionArtifacts{}, err
	}
	shortID := hex.EncodeToString(shortIDBytes)
	hy2Password, err := randomHex(reader, 24)
	if err != nil {
		return ProvisionArtifacts{}, err
	}
	obfsPassword, err := randomHex(reader, 16)
	if err != nil {
		return ProvisionArtifacts{}, err
	}
	certPEM, keyPEM, certPin, err := generateHysteriaCertificate(reader, net.ParseIP(opts.ServerIP), now)
	if err != nil {
		return ProvisionArtifacts{}, err
	}

	xrayConfig, err := json.MarshalIndent(map[string]any{
		"log": map[string]any{"loglevel": "warning"},
		"inbounds": []any{map[string]any{
			"listen": "0.0.0.0", "port": opts.XrayPort, "protocol": "vless",
			"settings": map[string]any{
				"clients":    []any{map[string]any{"id": uuid, "flow": "xtls-rprx-vision"}},
				"decryption": "none",
			},
			"streamSettings": map[string]any{
				"network": "tcp", "security": "reality",
				"realitySettings": map[string]any{
					"show": false, "target": opts.RealitySNI + ":443", "xver": 0,
					"serverNames": []string{opts.RealitySNI}, "privateKey": realityPrivateText,
					"shortIds": []string{shortID},
				},
			},
			"sniffing": map[string]any{"enabled": true, "destOverride": []string{"http", "tls", "quic"}},
		}},
		"outbounds": []any{
			map[string]any{"tag": "direct", "protocol": "freedom"},
			map[string]any{"tag": "blocked", "protocol": "blackhole"},
		},
		"routing": map[string]any{
			"domainStrategy": "IPIfNonMatch",
			"rules":          []any{map[string]any{"type": "field", "protocol": []string{"bittorrent"}, "outboundTag": "blocked"}},
		},
	}, "", "  ")
	if err != nil {
		return ProvisionArtifacts{}, err
	}

	certPath := opts.ServicesDir + "/hysteria.crt"
	keyPath := opts.ServicesDir + "/hysteria.key"
	hy2Config, err := json.MarshalIndent(map[string]any{
		"listen": ":" + strconv.Itoa(opts.Hysteria2Port),
		"tls":    map[string]any{"cert": certPath, "key": keyPath, "sniGuard": "disable"},
		"obfs":   map[string]any{"type": "salamander", "salamander": map[string]any{"password": obfsPassword}},
		"auth":   map[string]any{"type": "password", "password": hy2Password},
		"masquerade": map[string]any{
			"type": "proxy", "proxy": map[string]any{"url": "https://www.cloudflare.com/", "rewriteHost": true},
		},
	}, "", "  ")
	if err != nil {
		return ProvisionArtifacts{}, err
	}

	profile := NodeProfile{Protocols: []NodeProtocol{
		{
			ID: "reality", Type: "vless-reality", DisplayName: "Reality",
			VLESSReality: &VLESSReality{
				Server: opts.ServerIP, ServerPort: opts.XrayPort, UUID: uuid,
				Flow: "xtls-rprx-vision", ServerName: opts.RealitySNI,
				PublicKey: realityPublicText, ShortID: shortID,
			},
		},
		{
			ID: "hy2", Type: "hysteria2", DisplayName: "Hysteria2",
			Hysteria2: &Hysteria2Node{
				Server: opts.ServerIP, ServerPort: opts.Hysteria2Port,
				Password: hy2Password, ObfsType: "salamander", ObfsPassword: obfsPassword,
				ServerName: opts.ServerIP, CertificatePublicKeySHA256: certPin,
			},
		},
	}}

	return ProvisionArtifacts{
		NodeProfile: profile, XrayConfig: append(xrayConfig, '\n'), Hysteria2Config: append(hy2Config, '\n'),
		Hysteria2CertPEM: certPEM, Hysteria2KeyPEM: keyPEM,
		XraySystemdUnit:     dataPlaneUnit("PendingNet Reality service", opts.XrayBinary+" run -config "+opts.ServicesDir+"/xray.json", opts.ServicesDir),
		HysteriaSystemdUnit: dataPlaneUnit("PendingNet Hysteria2 service", opts.HysteriaBinary+" server --config "+opts.ServicesDir+"/hysteria.json", opts.ServicesDir),
	}, nil
}

func provisionDefaults(opts ProvisionOptions) ProvisionOptions {
	if opts.XrayPort == 0 {
		opts.XrayPort = 443
	}
	if opts.Hysteria2Port == 0 {
		opts.Hysteria2Port = 443
	}
	if opts.XrayBinary == "" {
		opts.XrayBinary = DefaultXrayBinary
	}
	if opts.HysteriaBinary == "" {
		opts.HysteriaBinary = DefaultHysteriaBinary
	}
	if opts.ServicesDir == "" {
		opts.ServicesDir = DefaultServicesDir
	}
	return opts
}

func validateProvisionOptions(opts ProvisionOptions) error {
	if net.ParseIP(opts.ServerIP) == nil {
		return errors.New("server IP must be a literal IPv4 or IPv6 address")
	}
	if strings.TrimSpace(opts.RealitySNI) == "" || strings.ContainsAny(opts.RealitySNI, " /:\t\r\n") {
		return errors.New("Reality SNI must be a hostname")
	}
	if _, err := parsePort(strconv.Itoa(opts.XrayPort)); err != nil {
		return fmt.Errorf("Xray port: %w", err)
	}
	if _, err := parsePort(strconv.Itoa(opts.Hysteria2Port)); err != nil {
		return fmt.Errorf("Hysteria2 port: %w", err)
	}
	for _, path := range []string{opts.XrayBinary, opts.HysteriaBinary, opts.ServicesDir} {
		if !strings.HasPrefix(path, "/") || strings.ContainsAny(path, " \t\r\n\"%\\") {
			return errors.New("provision paths must be safe absolute paths")
		}
	}
	return nil
}

func randomUUID(reader io.Reader) (string, error) {
	b := make([]byte, 16)
	if _, err := io.ReadFull(reader, b); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", b[:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}

func randomHex(reader io.Reader, size int) (string, error) {
	b := make([]byte, size)
	if _, err := io.ReadFull(reader, b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func generateHysteriaCertificate(reader io.Reader, ip net.IP, now time.Time) ([]byte, []byte, string, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), reader)
	if err != nil {
		return nil, nil, "", err
	}
	serialLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(reader, serialLimit)
	if err != nil {
		return nil, nil, "", err
	}
	template := x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: ip.String()},
		NotBefore: now.Add(-5 * time.Minute), NotAfter: now.AddDate(10, 0, 0),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses: []net.IP{ip},
	}
	der, err := x509.CreateCertificate(reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, "", err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, nil, "", err
	}
	publicDER, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		return nil, nil, "", err
	}
	pin := sha256.Sum256(publicDER)
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}),
		base64.StdEncoding.EncodeToString(pin[:]), nil
}

func dataPlaneUnit(description, execStart, servicesDir string) string {
	return fmt.Sprintf(`[Unit]
Description=%s
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%s
Restart=on-failure
RestartSec=3
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=%s
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
`, description, execStart, servicesDir)
}
