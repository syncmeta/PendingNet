package daemon

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"sbtally/internal/core"
)

type nowFunc func() int64

// NewServer builds the read API + live SSE over the store.
func NewServer(store *core.Store, hub *LiveHub, now nowFunc) *http.ServeMux {
	mux := http.NewServeMux()

	writeJSON := func(w http.ResponseWriter, v any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(v)
	}
	win := func(r *http.Request) (int64, int64) {
		return parseWindow(r.URL.Query().Get("since"), now())
	}
	topOf := func(r *http.Request) int {
		n, _ := strconv.Atoi(r.URL.Query().Get("top"))
		return n
	}

	mux.HandleFunc("/api/summary", func(w http.ResponseWriter, r *http.Request) {
		s, u := win(r)
		v, err := store.Summary(s, u)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, v)
	})
	mux.HandleFunc("/api/apps", func(w http.ResponseWriter, r *http.Request) {
		s, u := win(r)
		v, err := store.Apps(s, u, topOf(r))
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, v)
	})
	mux.HandleFunc("/api/domains", func(w http.ResponseWriter, r *http.Request) {
		s, u := win(r)
		v, err := store.Domains(s, u, topOf(r))
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, v)
	})
	mux.HandleFunc("/api/app/", func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, "/api/app/")
		if name == "" {
			http.Error(w, "missing app", 400)
			return
		}
		s, u := win(r)
		v, err := store.AppDetail(name, s, u)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, v)
	})
	mux.HandleFunc("/api/series", func(w http.ResponseWriter, r *http.Request) {
		s, u := win(r)
		v, err := store.Series(r.URL.Query().Get("name"), s, u)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, v)
	})
	mux.HandleFunc("/api/live", func(w http.ResponseWriter, r *http.Request) {
		fl, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "no flush", 500)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		ch := hub.Subscribe()
		defer hub.Unsubscribe(ch)
		for {
			select {
			case <-r.Context().Done():
				return
			case groups, ok := <-ch:
				if !ok {
					return
				}
				b, _ := json.Marshal(groups)
				_, _ = w.Write([]byte("data: "))
				_, _ = w.Write(b)
				_, _ = w.Write([]byte("\n\n"))
				fl.Flush()
			}
		}
	})
	return mux
}
