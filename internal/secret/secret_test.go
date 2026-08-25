package secret

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestStatic(t *testing.T) {
	if got := Static("abc")(); got != "abc" {
		t.Fatalf("Static = %q, want abc", got)
	}
}

func TestResolveNil(t *testing.T) {
	if got := Resolve(nil); got != "" {
		t.Fatalf("Resolve(nil) = %q, want empty", got)
	}
}

func TestFromFileMissing(t *testing.T) {
	s := FromFile(filepath.Join(t.TempDir(), "nope"))
	if got := s(); got != "" {
		t.Fatalf("missing file = %q, want empty", got)
	}
}

func TestFromFileTrims(t *testing.T) {
	path := filepath.Join(t.TempDir(), "control-secret")
	if err := os.WriteFile(path, []byte("  hunter2\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := FromFile(path)(); got != "hunter2" {
		t.Fatalf("got %q, want hunter2", got)
	}
}

// 引擎重新生成 secret 之后，采集端不重启也得跟上 —— 这条就是「不静默失灵」的
// 全部意义所在。
func TestFromFileRereadsAfterRotation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "control-secret")
	if err := os.WriteFile(path, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := FromFile(path)
	if got := s(); got != "old" {
		t.Fatalf("got %q, want old", got)
	}
	if err := os.WriteFile(path, []byte("new"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := s(); got != "new" {
		t.Fatalf("after rotation got %q, want new", got)
	}
}

func TestFromLifelineReadsFirstLine(t *testing.T) {
	src, _, err := FromLifeline(strings.NewReader("hunter2\nrest\n"))
	if err != nil {
		t.Fatal(err)
	}
	if got := src(); got != "hunter2" {
		t.Fatalf("got %q, want hunter2", got)
	}
}

func TestFromLifelineRejectsEmpty(t *testing.T) {
	if _, _, err := FromLifeline(strings.NewReader("\n")); err == nil {
		t.Fatal("空的第一行该报错")
	}
}

// 监护人一走，管子断掉，采集器就该收到收摊信号 —— 不然它会变成一个还占着统计
// 端口的孤儿。
func TestFromLifelineClosesWhenPipeCloses(t *testing.T) {
	r, w := io.Pipe()
	go func() {
		_, _ = w.Write([]byte("hunter2\n"))
	}()
	src, gone, err := FromLifeline(r)
	if err != nil {
		t.Fatal(err)
	}
	if got := src(); got != "hunter2" {
		t.Fatalf("got %q, want hunter2", got)
	}
	select {
	case <-gone:
		t.Fatal("管子还开着就报了 EOF")
	case <-time.After(50 * time.Millisecond):
	}
	_ = w.Close()
	select {
	case <-gone:
	case <-time.After(2 * time.Second):
		t.Fatal("管子断了却没有收摊")
	}
}
