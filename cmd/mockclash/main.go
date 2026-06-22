// Command mockclash serves a fake Clash API (streaming /connections plus stub
// proxy/config switch endpoints) so the daemon and dashboard can run without a
// real sing-box.
package main

import (
	"flag"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"

	"sbtally/internal/mockclash"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:9090", "listen address")
	seed := flag.Int64("seed", 1, "rng seed")
	flag.Parse()

	gen := mockclash.New(*seed)

	mux := http.NewServeMux()
	mux.HandleFunc("/connections", func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(strings.ToLower(r.Header.Get("Upgrade")), "websocket") {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(gen.SnapshotJSON())
			return
		}
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close(websocket.StatusNormalClosure, "")
		ctx := r.Context()
		if err := c.Write(ctx, websocket.MessageText, gen.SnapshotJSON()); err != nil {
			return
		}
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				gen.Tick()
				if err := c.Write(ctx, websocket.MessageText, gen.SnapshotJSON()); err != nil {
					return
				}
			}
		}
	})
	// Switch endpoints — accepted as no-ops; used by the Phase 3/4 control panel.
	mux.HandleFunc("/proxies/", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
	mux.HandleFunc("/proxies", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"proxies":{}}`))
	})
	mux.HandleFunc("/configs", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })

	log.Printf("mockclash listening on %s", *listen)
	if err := http.ListenAndServe(*listen, mux); err != nil {
		log.Fatal(err)
	}
}
