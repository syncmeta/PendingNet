// Package mockclash generates synthetic Clash-API /connections data so the
// daemon and dashboard can be exercised end-to-end without a real sing-box.
package mockclash

import (
	"encoding/json"
	"math/rand"
	"strconv"
)

type fakeConn struct {
	id       string
	process  string
	host     string
	destIP   string
	up, down int64
}

// Generator holds a fixed set of fake app connections whose byte counters grow
// on each Tick, mimicking a live sing-box Clash API feed.
type Generator struct {
	conns []*fakeConn
	rng   *rand.Rand
}

func New(seed int64) *Generator {
	specs := []struct{ proc, host, ip string }{
		{"Safari", "www.google.com", "142.250.72.196"},
		{"Telegram", "api.telegram.org", "149.154.167.51"},
		{"Spotify", "audio-fa.scdn.co", "35.186.224.47"},
		{"Code Helper", "api.github.com", "140.82.121.6"},
		{"Mail", "p25-imap.mail.icloud.com", "17.42.251.43"},
		{"com.apple.WebKit", "www.cloudflare.com", "104.16.132.229"},
	}
	g := &Generator{rng: rand.New(rand.NewSource(seed))}
	for i, s := range specs {
		g.conns = append(g.conns, &fakeConn{
			id: strconv.Itoa(i), process: s.proc, host: s.host, destIP: s.ip,
		})
	}
	return g
}

// Tick advances each connection's cumulative counters.
func (g *Generator) Tick() {
	for _, c := range g.conns {
		c.down += int64(g.rng.Intn(60_000) + 1_000)
		c.up += int64(g.rng.Intn(8_000) + 200)
	}
}

// SnapshotJSON renders the current state as a Clash-API /connections payload.
func (g *Generator) SnapshotJSON() []byte {
	type meta struct {
		Network         string `json:"network"`
		DestinationIP   string `json:"destinationIP"`
		DestinationPort string `json:"destinationPort"`
		Host            string `json:"host"`
		Process         string `json:"process"`
		ProcessPath     string `json:"processPath"`
	}
	type conn struct {
		ID       string   `json:"id"`
		Metadata meta     `json:"metadata"`
		Upload   int64    `json:"upload"`
		Download int64    `json:"download"`
		Chains   []string `json:"chains"`
		Rule     string   `json:"rule"`
	}
	type payload struct {
		Connections []conn `json:"connections"`
	}
	p := payload{Connections: make([]conn, 0, len(g.conns))}
	for _, c := range g.conns {
		p.Connections = append(p.Connections, conn{
			ID: c.id,
			Metadata: meta{
				Network: "tcp", DestinationIP: c.destIP, DestinationPort: "443",
				Host: c.host, Process: c.process, ProcessPath: "/Applications/" + c.process,
			},
			Upload: c.up, Download: c.down, Chains: []string{"proxy"}, Rule: "Match",
		})
	}
	b, _ := json.Marshal(p)
	return b
}

func (g *Generator) totalBytes() int64 {
	var t int64
	for _, c := range g.conns {
		t += c.up + c.down
	}
	return t
}
