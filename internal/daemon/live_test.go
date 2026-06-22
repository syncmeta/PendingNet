package daemon

import (
	"testing"

	"sbtally/internal/source"
)

func TestComputeLiveRates(t *testing.T) {
	prev := source.Snapshot{At: 0, Connections: []source.Connection{
		{ID: "c1", Process: "Safari", Host: "a.com", Upload: 100, Download: 10},
	}}
	cur := source.Snapshot{At: 2, Connections: []source.Connection{
		{ID: "c1", Process: "Safari", Host: "a.com", Upload: 300, Download: 30},
	}}
	groups := computeLive(prev, cur)
	if len(groups) != 1 {
		t.Fatalf("want 1 group, got %d", len(groups))
	}
	g := groups[0]
	if g.App != "Safari" || g.UpRate != 100 || g.DownRate != 10 || g.Conns != 1 || g.TopHost != "a.com" {
		t.Fatalf("bad group: %+v", g)
	}
}

func TestComputeLiveNewConnectionCountsFromZero(t *testing.T) {
	prev := source.Snapshot{At: 0}
	cur := source.Snapshot{At: 1, Connections: []source.Connection{
		{ID: "n", Process: "X", Host: "h", Upload: 50, Download: 5},
	}}
	g := computeLive(prev, cur)
	if len(g) != 1 || g[0].UpRate != 50 {
		t.Fatalf("bad: %+v", g)
	}
}
