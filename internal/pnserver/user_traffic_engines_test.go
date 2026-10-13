package pnserver

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestTwoUsersWithLockedRealEngines(t *testing.T) {
	xray, hy, box := os.Getenv("PENDINGNET_TEST_XRAY"), os.Getenv("PENDINGNET_TEST_HYSTERIA"), os.Getenv("PENDINGNET_TEST_SINGBOX")
	if xray == "" || hy == "" || box == "" {
		t.Skip("set all three locked engine fixture binaries")
	}
	dir := t.TempDir()
	services := filepath.Join(dir, "services")
	_ = os.MkdirAll(services, 0700)
	tcpPort := func() int {
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer l.Close()
		return l.Addr().(*net.TCPAddr).Port
	}
	udpPort := func() int {
		l, err := net.ListenPacket("udp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer l.Close()
		return l.LocalAddr().(*net.UDPAddr).Port
	}
	camouflage := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("camouflage")) }))
	camouflage.TLS = &tls.Config{MinVersion: tls.VersionTLS13}
	camouflage.EnableHTTP2 = true
	camouflage.StartTLS()
	defer camouflage.Close()
	echo := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		_, _ = io.WriteString(w, strings.Repeat("data", 16384))
	}))
	defer echo.Close()
	art, err := BuildProvisionArtifacts(ProvisionOptions{ServerIP: "127.0.0.1", RealitySNI: "example.com", XrayPort: tcpPort(), Hysteria2Port: udpPort(), ServicesDir: services}, nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(filepath.Join(services, "hysteria.crt"), art.Hysteria2CertPEM, 0600)
	_ = os.WriteFile(filepath.Join(services, "hysteria.key"), art.Hysteria2KeyPEM, 0600)
	store := NewStore(dir)
	_, _ = store.Initialize("Fixture", "https://127.0.0.1:7443")
	_ = store.SaveNodeProfile(art.NodeProfile)
	_, _ = store.CreatePairing(time.Hour)
	_, _ = store.CreatePairing(time.Hour)
	state, _ := store.Load()
	accounts, err := store.EnsureUserProxyAccounts()
	if err != nil {
		t.Fatal(err)
	}
	xb, hb, err := BuildUserProxyConfigs(art.XrayConfig, art.Hysteria2Config, state, accounts)
	if err != nil {
		t.Fatal(err)
	}
	xrAddr, hyAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(tcpPort())), net.JoinHostPort("127.0.0.1", strconv.Itoa(tcpPort()))
	var xc, hc map[string]any
	_ = json.Unmarshal(xb, &xc)
	_ = json.Unmarshal(hb, &hc)
	xc["api"].(map[string]any)["listen"] = xrAddr
	xi := xc["inbounds"].([]any)[0].(map[string]any)
	xi["listen"] = "127.0.0.1"
	xi["streamSettings"].(map[string]any)["realitySettings"].(map[string]any)["target"] = camouflage.Listener.Addr().String()
	hc["listen"] = net.JoinHostPort("127.0.0.1", strconv.Itoa(art.NodeProfile.Protocols[1].Hysteria2.ServerPort))
	hc["trafficStats"].(map[string]any)["listen"] = hyAddr
	hc["masquerade"] = map[string]any{"type": "proxy", "proxy": map[string]any{"url": echo.URL, "rewriteHost": true}}
	xb, _ = json.Marshal(xc)
	hb, _ = json.Marshal(hc)
	xPath, hPath := filepath.Join(services, "xray.json"), filepath.Join(services, "hysteria.json")
	_ = os.WriteFile(xPath, xb, 0600)
	_ = os.WriteFile(hPath, hb, 0600)
	if out, err := exec.Command(xray, "run", "-test", "-config", xPath).CombinedOutput(); err != nil {
		t.Fatalf("locked Xray validation: %v %s", err, out)
	}
	start := func(binary string, args ...string) func() {
		log, err := os.CreateTemp(dir, "engine-log-")
		if err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command(binary, args...)
		cmd.Stdout = log
		cmd.Stderr = log
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		stopped := false
		stop := func() {
			if !stopped {
				stopped = true
				_ = cmd.Process.Kill()
				_ = cmd.Wait()
				_ = log.Close()
			}
		}
		t.Cleanup(stop)
		return stop
	}
	stopXray := start(xray, "run", "-config", xPath)
	stopHy := start(hy, "server", "--config", hPath)
	waitTCP := func(address string) {
		deadline := time.Now().Add(8 * time.Second)
		for time.Now().Before(deadline) {
			c, err := net.DialTimeout("tcp", address, 100*time.Millisecond)
			if err == nil {
				c.Close()
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
		t.Fatalf("fixture listener %s never started", address)
	}
	waitTCP(xrAddr)
	waitTCP(hyAddr)
	transfer := func(profile NodeProfile, protocol string) error {
		var outbound map[string]any
		for _, p := range profile.Protocols {
			if p.Type != protocol {
				continue
			}
			if n := p.VLESSReality; n != nil {
				outbound = map[string]any{"type": "vless", "tag": "proxy", "server": n.Server, "server_port": n.ServerPort, "uuid": n.UUID, "flow": n.Flow, "tls": map[string]any{"enabled": true, "server_name": n.ServerName, "utls": map[string]any{"enabled": true, "fingerprint": "chrome"}, "reality": map[string]any{"enabled": true, "public_key": n.PublicKey, "short_id": n.ShortID}}}
			}
			if n := p.Hysteria2; n != nil {
				outbound = map[string]any{"type": "hysteria2", "tag": "proxy", "server": n.Server, "server_port": n.ServerPort, "password": n.Password, "obfs": map[string]any{"type": n.ObfsType, "password": n.ObfsPassword}, "tls": map[string]any{"enabled": true, "server_name": n.ServerName, "insecure": true, "certificate_public_key_sha256": []string{n.CertificatePublicKeySHA256}}}
			}
		}
		port := tcpPort()
		config := map[string]any{"log": map[string]any{"level": "error"}, "inbounds": []any{map[string]any{"type": "mixed", "listen": "127.0.0.1", "listen_port": port}}, "outbounds": []any{outbound}, "route": map[string]any{"final": "proxy"}}
		data, _ := json.Marshal(config)
		path := filepath.Join(dir, "client.json")
		_ = os.WriteFile(path, data, 0600)
		stopClient := start(box, "run", "-c", path)
		waitTCP(net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
		proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port))
		client := &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{Proxy: http.ProxyURL(proxy)}}
		resp, err := client.Post(echo.URL, "application/octet-stream", strings.NewReader(strings.Repeat("upload", 4096)))
		if err != nil {
			stopClient()
			client.CloseIdleConnections()
			return err
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		client.CloseIdleConnections()
		stopClient()
		if resp.StatusCode != 200 || len(body) != 65536 {
			return fmt.Errorf("proxy response status=%d size=%d", resp.StatusCode, len(body))
		}
		return nil
	}
	profiles := map[string]NodeProfile{}
	for _, u := range state.Users {
		profiles[u.ID], err = store.UserNodeProfile(u.ID)
		if err != nil {
			t.Fatal(err)
		}
	}
	for _, protocol := range []string{"vless-reality", "hysteria2"} {
		for _, u := range state.Users {
			if err = transfer(profiles[u.ID], protocol); err != nil {
				t.Fatalf("%s user transfer failed: %v", protocol, err)
			}
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	data, err := exec.CommandContext(ctx, xray, "api", "statsquery", "--server="+xrAddr, "--pattern=user>>>", "--reset=false").Output()
	if err != nil {
		t.Fatal(err)
	}
	var stats struct {
		Stat []struct {
			Name  string      `json:"name"`
			Value json.Number `json:"value"`
		} `json:"stat"`
	}
	if json.Unmarshal(data, &stats) != nil {
		t.Fatal("invalid real Xray counters")
	}
	counts := map[string]TrafficCounters{}
	for _, v := range stats.Stat {
		parts := strings.Split(v.Name, ">>>")
		if len(parts) != 4 {
			continue
		}
		n, _ := v.Value.Int64()
		c := counts[parts[1]]
		if parts[3] == "uplink" {
			c.Upload = n
		} else if parts[3] == "downlink" {
			c.Download = n
		}
		counts[parts[1]] = c
	}
	for _, u := range state.Users {
		if counts[u.ID].Upload <= 0 || counts[u.ID].Download < 65536 {
			t.Fatal("Xray missed individual user traffic")
		}
	}
	if err := store.RecordUserTraffic("xray", "fixture-xray", counts); err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest(http.MethodGet, "http://"+hyAddr+"/traffic", nil)
	req.Header.Set("Authorization", accounts.StatsSecret)
	httpClient := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{Proxy: nil}}
	resp, err := httpClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var hyStats map[string]struct {
		Tx int64 `json:"tx"`
		Rx int64 `json:"rx"`
	}
	if json.NewDecoder(resp.Body).Decode(&hyStats) != nil {
		t.Fatal("invalid real Hysteria2 counters")
	}
	counts = map[string]TrafficCounters{}
	for _, u := range state.Users {
		v := hyStats[UserHysteriaName(u.ID)]
		if v.Tx <= 0 || v.Rx < 65536 {
			t.Fatalf("Hysteria2 missed user traffic: tx=%d rx=%d", v.Tx, v.Rx)
		}
		counts[u.ID] = TrafficCounters{Upload: v.Tx, Download: v.Rx}
	}
	if err := store.RecordUserTraffic("hysteria2", "fixture-hysteria", counts); err != nil {
		t.Fatal(err)
	}
	totals, err := NewStore(dir).UserTraffic()
	if err != nil {
		t.Fatal(err)
	}
	for _, u := range state.Users {
		if totals[u.ID].Download < 131072 {
			t.Fatal("combined counters did not persist")
		}
	}
	if err := store.RenameUser(state.Users[1].ID, "Renamed user"); err != nil {
		t.Fatal(err)
	}
	if err := store.RevokeUser(state.Users[0].ID); err != nil {
		t.Fatal(err)
	}
	changed, _ := store.Load()
	nx, nh, err := BuildUserProxyConfigs(xb, hb, changed, accounts)
	if err != nil {
		t.Fatal(err)
	}
	var nxc, nhc map[string]any
	_ = json.Unmarshal(nx, &nxc)
	_ = json.Unmarshal(nh, &nhc)
	nxc["api"].(map[string]any)["listen"] = xrAddr
	nhc["trafficStats"].(map[string]any)["listen"] = hyAddr
	nx, _ = json.Marshal(nxc)
	nh, _ = json.Marshal(nhc)
	stopXray()
	stopHy()
	_ = os.WriteFile(xPath, nx, 0600)
	_ = os.WriteFile(hPath, nh, 0600)
	start(xray, "run", "-config", xPath)
	start(hy, "server", "--config", hPath)
	waitTCP(xrAddr)
	waitTCP(hyAddr)
	for _, protocol := range []string{"vless-reality", "hysteria2"} {
		if err := transfer(profiles[state.Users[0].ID], protocol); err == nil {
			t.Fatalf("revoked %s credential still works", protocol)
		}
		if err := transfer(profiles[state.Users[1].ID], protocol); err != nil {
			t.Fatalf("retained %s user stopped working: %v", protocol, err)
		}
	}
	t.Log("Two users transferred data independently through locked Xray and Hysteria2; cumulative bytes persisted; revoked credentials rejected by both engines while renamed user retained access")
}
