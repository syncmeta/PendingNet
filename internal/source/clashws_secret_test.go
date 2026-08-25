package source

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"sbtally/internal/secret"
)

// 引擎重新生成 control-secret 之后，采集端不重启也得自己恢复。这是「不静默
// 失灵」那条要求的整条链路：文件里的旧密钥被拒 → 文件被换掉 → 下一次重连
// 用的是新的那份。
func TestClashSourceRecoversAfterSecretRotation(t *testing.T) {
	const wanted = "the-new-one"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+wanted {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
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

	path := filepath.Join(t.TempDir(), "control-secret")
	if err := os.WriteFile(path, []byte("the-stale-one"), 0o600); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cs := NewClashSource(strings.TrimPrefix(srv.URL, "http://"), secret.FromFile(path))
	ch, err := cs.Snapshots(ctx)
	if err != nil {
		t.Fatal(err)
	}

	// 旧密钥期间一条都不该收到。
	select {
	case snap := <-ch:
		t.Fatalf("过期密钥居然收到了快照：%+v", snap)
	case <-time.After(300 * time.Millisecond):
	}

	if err := os.WriteFile(path, []byte(wanted+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	// 重连有退避，给足几秒。
	select {
	case snap := <-ch:
		if len(snap.Connections) != 1 || snap.Connections[0].Process != "Safari" {
			t.Fatalf("bad snapshot: %+v", snap)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("换了密钥之后没能自己恢复")
	}
}
