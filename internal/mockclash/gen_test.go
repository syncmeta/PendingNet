package mockclash

import (
	"encoding/json"
	"testing"
)

func TestTickGrowsCounters(t *testing.T) {
	g := New(1)
	g.Tick()
	first := g.totalBytes()
	g.Tick()
	if g.totalBytes() <= first {
		t.Fatalf("counters should grow: %d then %d", first, g.totalBytes())
	}
}

func TestSnapshotShapeDecodes(t *testing.T) {
	g := New(1)
	g.Tick()
	var payload struct {
		Connections []struct {
			ID       string `json:"id"`
			Metadata struct {
				Process string `json:"process"`
				Host    string `json:"host"`
			} `json:"metadata"`
			Upload   int64 `json:"upload"`
			Download int64 `json:"download"`
		} `json:"connections"`
	}
	if err := json.Unmarshal(g.SnapshotJSON(), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Connections) == 0 {
		t.Fatal("expected connections")
	}
	c := payload.Connections[0]
	if c.ID == "" || c.Metadata.Process == "" || c.Metadata.Host == "" || c.Download == 0 {
		t.Fatalf("bad connection shape: %+v", c)
	}
}
