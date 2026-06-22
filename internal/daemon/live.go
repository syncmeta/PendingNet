package daemon

import (
	"sync"

	"sbtally/internal/core"
	"sbtally/internal/source"
)

func computeLive(prev, cur source.Snapshot) []core.LiveAppGroup {
	dt := cur.At - prev.At
	if dt <= 0 {
		dt = 1
	}
	prevMap := make(map[string]source.Connection, len(prev.Connections))
	for _, c := range prev.Connections {
		prevMap[c.ID] = c
	}
	type agg struct {
		up, down int64
		conns    int
		topHost  string
		topBytes int64
	}
	m := map[string]*agg{}
	for _, c := range cur.Connections {
		p := prevMap[c.ID]
		du := c.Upload - p.Upload
		dd := c.Download - p.Download
		if du < 0 {
			du = 0
		}
		if dd < 0 {
			dd = 0
		}
		app := core.AppKey(c)
		a := m[app]
		if a == nil {
			a = &agg{}
			m[app] = a
		}
		a.up += du
		a.down += dd
		a.conns++
		if tot := c.Upload + c.Download; tot >= a.topBytes {
			a.topBytes = tot
			a.topHost = core.HostKey(c)
		}
	}
	out := make([]core.LiveAppGroup, 0, len(m))
	for app, a := range m {
		out = append(out, core.LiveAppGroup{
			App: app, UpRate: a.up / dt, DownRate: a.down / dt,
			Conns: a.conns, TopHost: a.topHost,
		})
	}
	return out
}

// LiveHub fan-outs live groups to SSE subscribers.
type LiveHub struct {
	mu   sync.Mutex
	subs map[chan []core.LiveAppGroup]struct{}
}

func NewLiveHub() *LiveHub {
	return &LiveHub{subs: map[chan []core.LiveAppGroup]struct{}{}}
}

func (h *LiveHub) Subscribe() chan []core.LiveAppGroup {
	ch := make(chan []core.LiveAppGroup, 4)
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	h.mu.Unlock()
	return ch
}

func (h *LiveHub) Unsubscribe(ch chan []core.LiveAppGroup) {
	h.mu.Lock()
	if _, ok := h.subs[ch]; ok {
		delete(h.subs, ch)
		close(ch)
	}
	h.mu.Unlock()
}

func (h *LiveHub) Publish(groups []core.LiveAppGroup) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs {
		select {
		case ch <- groups:
		default: // drop for slow subscribers
		}
	}
}
