package pnserver

import (
	"crypto/rand"
	"io"
	"sync"
	"testing"
	"time"
)

type pausedRandom struct {
	once    sync.Once
	entered chan struct{}
	release chan struct{}
}

func (r *pausedRandom) Read(p []byte) (int, error) {
	r.once.Do(func() { close(r.entered); <-r.release })
	return io.ReadFull(rand.Reader, p)
}

func TestSeparateStoresSerializeStateChanges(t *testing.T) {
	dir := t.TempDir()
	first := NewStore(dir)
	if _, err := first.Initialize("VPS", "https://203.0.113.1:7443"); err != nil {
		t.Fatal(err)
	}
	pause := &pausedRandom{entered: make(chan struct{}), release: make(chan struct{})}
	first.Rand = pause
	a := make(chan error, 1)
	go func() { _, err := first.CreatePairing(time.Hour); a <- err }()
	<-pause.entered
	second := NewStore(dir)
	b := make(chan error, 1)
	go func() { _, err := second.CreateAdminPairing(time.Hour); b <- err }()
	premature := false
	select {
	case <-b:
		premature = true
	case <-time.After(100 * time.Millisecond):
	}
	close(pause.release)
	if err := <-a; err != nil {
		t.Fatal(err)
	}
	if !premature {
		if err := <-b; err != nil {
			t.Fatal(err)
		}
	}
	if premature {
		t.Fatal("second writer completed while first writer held a state transaction")
	}
	state, err := first.Load()
	if err != nil || len(state.Pairings) != 2 {
		t.Fatalf("lost a grant: %v", err)
	}
}
