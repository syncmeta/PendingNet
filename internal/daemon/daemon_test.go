package daemon

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"sbtally/internal/core"
	"sbtally/internal/source"
)

type fakeSource struct{ snaps []source.Snapshot }

func (f *fakeSource) Snapshots(ctx context.Context) (<-chan source.Snapshot, error) {
	ch := make(chan source.Snapshot)
	go func() {
		defer close(ch)
		for _, s := range f.snaps {
			select {
			case ch <- s:
			case <-ctx.Done():
				return
			}
		}
		<-ctx.Done()
	}()
	return ch, nil
}

func TestDaemonPersistsTraffic(t *testing.T) {
	st, err := core.OpenStore(filepath.Join(t.TempDir(), "d.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	src := &fakeSource{snaps: []source.Snapshot{
		{At: 0, Connections: []source.Connection{{ID: "c1", Process: "Safari", Host: "a.com", Upload: 100, Download: 10}}},
		{At: 1, Connections: []source.Connection{{ID: "c1", Process: "Safari", Host: "a.com", Upload: 300, Download: 40}}},
	}}
	d := New(src, st, NewLiveHub())
	d.FlushInterval = 20 * time.Millisecond

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { _ = d.Run(ctx); close(done) }()

	time.Sleep(100 * time.Millisecond)
	cancel()
	<-done

	apps, err := st.Apps(0, 3600, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(apps) != 1 || apps[0].Upload != 300 || apps[0].Download != 40 {
		t.Fatalf("got %+v want Safari 300/40", apps)
	}
}
