package main

import (
	"bytes"
	"net"
	"os"
	"path/filepath"
	"sbtally/internal/pnserver"
	"strconv"
	"strings"
	"testing"
	"time"
)

func portsCLIFixture(t *testing.T) *pnserver.Store {
	t.Helper()
	s := pnserver.NewStore(t.TempDir())
	if _, err := s.Initialize("Test VPS", "https://203.0.113.1:7443"); err != nil {
		t.Fatal(err)
	}
	services := filepath.Join(s.Dir, "services")
	if err := os.MkdirAll(services, 0700); err != nil {
		t.Fatal(err)
	}
	a, err := pnserver.BuildProvisionArtifacts(pnserver.ProvisionOptions{ServerIP: "203.0.113.1", RealitySNI: "www.example.com", ServicesDir: services}, nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := s.SaveNodeProfile(a.NodeProfile); err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string][]byte{"xray.json": a.XrayConfig, "hysteria.json": a.Hysteria2Config} {
		if err := os.WriteFile(filepath.Join(services, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	return s
}

func TestPortsMenuAndCommand(t *testing.T) {
	for _, scenario := range []struct {
		name, input string
		args        []string
		want        pnserver.ProxyPorts
		calls       int
		invalid     bool
	}{
		{"menu-change", "15\n8443\n9443\nyes\n0\n", nil, pnserver.ProxyPorts{Reality: 8443, Hysteria2: 9443}, 1, false},
		{"menu-keep-hy2", "15\n8443\n\nyes\n0\n", nil, pnserver.ProxyPorts{Reality: 8443, Hysteria2: 443}, 1, false},
		{"menu-keep-both", "15\n\n\n0\n", nil, pnserver.ProxyPorts{Reality: 443, Hysteria2: 443}, 0, false},
		{"menu-cancel", "15\n8443\n9443\nno\n0\n", nil, pnserver.ProxyPorts{Reality: 443, Hysteria2: 443}, 0, false},
		{"menu-eof", "15\n8443\n9443\n", nil, pnserver.ProxyPorts{Reality: 443, Hysteria2: 443}, 0, false},
		{"menu-invalid", "15\n0\n9443\n0\n", nil, pnserver.ProxyPorts{Reality: 443, Hysteria2: 443}, 0, true},
		{"cli-read", "", []string{}, pnserver.ProxyPorts{Reality: 443, Hysteria2: 443}, 0, false},
		{"cli-change", "", []string{"--hysteria2", "9443"}, pnserver.ProxyPorts{Reality: 443, Hysteria2: 9443}, 1, false},
		{"cli-invalid", "", []string{"--reality", "65536"}, pnserver.ProxyPorts{Reality: 443, Hysteria2: 443}, 0, true},
		{"cli-empty", "", []string{"--reality", ""}, pnserver.ProxyPorts{Reality: 443, Hysteria2: 443}, 0, true},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			s := portsCLIFixture(t)
			before, _, _ := readProxyPorts(s.Dir)
			original := changePortsForCLI
			defer func() { changePortsForCLI = original }()
			calls := 0
			changePortsForCLI = func(store *pnserver.Store, revision string, old, next pnserver.ProxyPorts) error {
				calls++
				if store.Dir != s.Dir || next != scenario.want {
					t.Fatal("wrong target")
				}
				return store.ChangePorts(filepath.Join(store.Dir, "services"), revision, next, pnserver.ManagedConfigHooks{
					Validate: func(pnserver.ManagedConfigPaths) error { return nil }, Restart: func() error { return nil },
				})
			}
			var out, errs bytes.Buffer
			if scenario.input != "" {
				if err := runMenu(strings.NewReader(scenario.input), &out, &errs, s.Dir); err != nil {
					t.Fatal(err)
				}
				if !strings.Contains(out.String(), "15. 更改端口") {
					t.Fatal("menu option missing")
				}
				if scenario.invalid && !strings.Contains(errs.String(), "端口") {
					t.Fatal("invalid port not reported")
				}
			} else {
				err := run(append([]string{"ports", "--state-dir", s.Dir}, scenario.args...), &out, &errs)
				if scenario.invalid != (err != nil) {
					t.Fatalf("unexpected CLI result: %v", err)
				}
			}
			if calls != scenario.calls {
				t.Fatalf("changed %d times, expected %d", calls, scenario.calls)
			}
			after, ports, err := readProxyPorts(s.Dir)
			if err != nil || ports != scenario.want {
				t.Fatalf("unexpected ports: %+v (%v)", ports, err)
			}
			if calls == 0 && after.Revision != before.Revision {
				t.Fatal("cancel/noop altered files")
			}
			if strings.Contains(out.String(), "privateKey") || strings.Contains(out.String(), "password") {
				t.Fatal("output contains credentials")
			}
		})
	}
}

func TestPortAvailabilityRejectsOccupiedAndReservedPorts(t *testing.T) {
	s := portsCLIFixture(t)
	old := pnserver.ProxyPorts{Reality: 443, Hysteria2: 443}
	tcp, err := net.Listen("tcp", ":0")
	if err != nil {
		t.Fatal(err)
	}
	defer tcp.Close()
	udp, err := net.ListenPacket("udp", ":0")
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	for _, next := range []pnserver.ProxyPorts{
		{Reality: tcp.Addr().(*net.TCPAddr).Port, Hysteria2: 443},
		{Reality: 443, Hysteria2: udp.LocalAddr().(*net.UDPAddr).Port},
		{Reality: 7443, Hysteria2: 443},
	} {
		if err := checkProxyPortAvailability(s, old, next); err == nil {
			t.Fatalf("accepted occupied or reserved port: %+v", next)
		}
	}
	if _, err := s.EnsureUserProxyAccounts(); err != nil {
		t.Fatal(err)
	}
	if err := checkProxyPortAvailability(s, old, pnserver.ProxyPorts{Reality: 17446, Hysteria2: 443}); err == nil {
		t.Fatal("accepted stats port")
	}
	if err := checkProxyPortAvailability(s, old, old); err != nil {
		t.Fatal("unchanged ports should not be probed")
	}
}

func TestProxyHealthChecksUseCurrentPortsAndOptionalStats(t *testing.T) {
	s := portsCLIFixture(t)
	p, err := s.LoadNodeProfile()
	if err != nil {
		t.Fatal(err)
	}
	for _, port := range []int{8443, 443} {
		p.Protocols[0].VLESSReality.ServerPort = port
		p.Protocols[1].Hysteria2.ServerPort = port
		listeners, err := proxyListeners(p, false)
		if err != nil {
			t.Fatal(err)
		}
		if listeners[serviceUnits["reality"]]["tcp"] != strconv.Itoa(port) || listeners[serviceUnits["hysteria"]]["udp"] != strconv.Itoa(port) {
			t.Fatal("stale listener health check")
		}
		if len(listeners[serviceUnits["reality"]]) != 1 {
			t.Fatal("legacy server requires stats")
		}
	}
	listeners, err := proxyListeners(p, true)
	if err != nil || listeners[serviceUnits["reality"]]["stats"] != "17446" || listeners[serviceUnits["hysteria"]]["stats"] != "17445" {
		t.Fatal("stats listener missing")
	}
}
