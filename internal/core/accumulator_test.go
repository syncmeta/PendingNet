package core

import (
	"sort"
	"testing"

	"sbtally/internal/source"
)

func rollupMap(rs []Rollup) map[string]Rollup {
	m := map[string]Rollup{}
	for _, r := range rs {
		m[r.App+"|"+r.Host] = r
	}
	return m
}

func TestAccumulatorDeltasAcrossSnapshots(t *testing.T) {
	a := NewAccumulator()
	a.Add(source.Snapshot{At: 0, Connections: []source.Connection{
		{ID: "c1", Process: "Safari", Host: "a.com", Upload: 100, Download: 10},
	}})
	a.Add(source.Snapshot{At: 1, Connections: []source.Connection{
		{ID: "c1", Process: "Safari", Host: "a.com", Upload: 300, Download: 40},
	}})
	got := rollupMap(a.Pending())
	r := got["Safari|a.com"]
	if r.Upload != 300 || r.Download != 40 {
		t.Fatalf("Safari|a.com = %d/%d want 300/40", r.Upload, r.Download)
	}
	if r.Bucket != 0 {
		t.Fatalf("bucket=%d want 0", r.Bucket)
	}
}

func TestAccumulatorClosedConnectionNotDoubleCounted(t *testing.T) {
	a := NewAccumulator()
	a.Add(source.Snapshot{At: 0, Connections: []source.Connection{
		{ID: "c1", Process: "X", Host: "h", Upload: 50, Download: 5},
	}})
	_ = a.Pending()
	a.Add(source.Snapshot{At: 1, Connections: []source.Connection{
		{ID: "c2", Process: "X", Host: "h", Upload: 7, Download: 1},
	}})
	got := rollupMap(a.Pending())
	r := got["X|h"]
	if r.Upload != 7 || r.Download != 1 {
		t.Fatalf("X|h = %d/%d want 7/1", r.Upload, r.Download)
	}
	if len(a.last) != 1 {
		t.Fatalf("last has %d entries want 1", len(a.last))
	}
}

func TestAccumulatorNegativeDeltaClamped(t *testing.T) {
	a := NewAccumulator()
	a.Add(source.Snapshot{At: 0, Connections: []source.Connection{
		{ID: "c1", Process: "X", Host: "h", Upload: 500, Download: 50},
	}})
	_ = a.Pending()
	a.Add(source.Snapshot{At: 1, Connections: []source.Connection{
		{ID: "c1", Process: "X", Host: "h", Upload: 100, Download: 10},
	}})
	if rs := a.Pending(); len(rs) != 0 {
		t.Fatalf("expected no rollups, got %+v", rs)
	}
}

func TestAccumulatorHourBucketing(t *testing.T) {
	a := NewAccumulator()
	a.Add(source.Snapshot{At: 0, Connections: []source.Connection{
		{ID: "c1", Process: "X", Host: "h", Upload: 10},
	}})
	a.Add(source.Snapshot{At: 3600, Connections: []source.Connection{
		{ID: "c1", Process: "X", Host: "h", Upload: 30},
	}})
	rs := a.Pending()
	sort.Slice(rs, func(i, j int) bool { return rs[i].Bucket < rs[j].Bucket })
	if len(rs) != 2 || rs[0].Bucket != 0 || rs[0].Upload != 10 || rs[1].Bucket != 3600 || rs[1].Upload != 20 {
		t.Fatalf("unexpected rollups: %+v", rs)
	}
}

func TestAccumulatorMissingProcessFallsBackToUnknown(t *testing.T) {
	a := NewAccumulator()
	a.Add(source.Snapshot{At: 0, Connections: []source.Connection{
		{ID: "c1", DestIP: "9.9.9.9", Upload: 5, Download: 1},
	}})
	got := rollupMap(a.Pending())
	if _, ok := got["unknown|9.9.9.9"]; !ok {
		t.Fatalf("expected unknown|9.9.9.9, got %+v", got)
	}
}
