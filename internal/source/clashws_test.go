package source

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestClashSourceReceivesSnapshots(t *testing.T) {
	gotAuth := make(chan string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth <- r.Header.Get("Authorization")
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close(websocket.StatusNormalClosure, "")
		_ = c.Write(r.Context(), websocket.MessageText, []byte(
			`{"connections":[{"id":"c1","metadata":{"process":"Safari","host":"a.com"},"upload":5,"download":1}]}`))
		<-r.Context().Done()
	}))
	defer srv.Close()

	addr := strings.TrimPrefix(srv.URL, "http://")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cs := NewClashSource(addr, "sek")
	ch, err := cs.Snapshots(ctx)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case snap := <-ch:
		if len(snap.Connections) != 1 || snap.Connections[0].Process != "Safari" {
			t.Fatalf("bad snapshot: %+v", snap)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for snapshot")
	}
	if a := <-gotAuth; a != "Bearer sek" {
		t.Fatalf("auth header = %q want Bearer sek", a)
	}
}
