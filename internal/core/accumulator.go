package core

import "sbtally/internal/source"

// Rollup is accumulated traffic for one (hour, app, host) bucket.
type Rollup struct {
	Bucket   int64
	App      string
	Host     string
	Upload   int64
	Download int64
}

type counters struct{ up, down int64 }

type bucketKey struct {
	bucket int64
	app    string
	host   string
}

// Accumulator turns cumulative per-connection counters into per-(hour,app,host) deltas.
type Accumulator struct {
	last    map[string]counters
	pending map[bucketKey]counters
}

func NewAccumulator() *Accumulator {
	return &Accumulator{
		last:    make(map[string]counters),
		pending: make(map[bucketKey]counters),
	}
}

func hourFloor(ts int64) int64 { return ts - ((ts%3600)+3600)%3600 }

// Add folds one snapshot into pending deltas.
func (a *Accumulator) Add(s source.Snapshot) {
	bucket := hourFloor(s.At)
	seen := make(map[string]struct{}, len(s.Connections))
	for _, c := range s.Connections {
		seen[c.ID] = struct{}{}
		prev := a.last[c.ID]
		du := c.Upload - prev.up
		dd := c.Download - prev.down
		if du < 0 {
			du = 0
		}
		if dd < 0 {
			dd = 0
		}
		if du != 0 || dd != 0 {
			k := bucketKey{bucket, AppKey(c), HostKey(c)}
			p := a.pending[k]
			p.up += du
			p.down += dd
			a.pending[k] = p
		}
		a.last[c.ID] = counters{c.Upload, c.Download}
	}
	for id := range a.last {
		if _, ok := seen[id]; !ok {
			delete(a.last, id)
		}
	}
}

// Pending returns and clears accumulated deltas for flushing to the store.
func (a *Accumulator) Pending() []Rollup {
	out := make([]Rollup, 0, len(a.pending))
	for k, v := range a.pending {
		out = append(out, Rollup{Bucket: k.bucket, App: k.app, Host: k.host, Upload: v.up, Download: v.down})
	}
	a.pending = make(map[bucketKey]counters)
	return out
}
