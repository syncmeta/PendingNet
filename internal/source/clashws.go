package source

import (
	"context"
	"net/http"
	"time"

	"github.com/coder/websocket"
)

type ClashSource struct {
	addr   string // host:port
	secret string
}

func NewClashSource(addr, secret string) *ClashSource {
	return &ClashSource{addr: addr, secret: secret}
}

func (cs *ClashSource) Snapshots(ctx context.Context) (<-chan Snapshot, error) {
	ch := make(chan Snapshot)
	go func() {
		defer close(ch)
		backoff := time.Second
		for ctx.Err() == nil {
			err := cs.stream(ctx, ch)
			if ctx.Err() != nil {
				return
			}
			if err != nil {
				time.Sleep(backoff)
				if backoff < 30*time.Second {
					backoff *= 2
				}
				continue
			}
			backoff = time.Second
		}
	}()
	return ch, nil
}

func (cs *ClashSource) stream(ctx context.Context, ch chan<- Snapshot) error {
	u := "ws://" + cs.addr + "/connections"
	opts := &websocket.DialOptions{}
	if cs.secret != "" {
		opts.HTTPHeader = http.Header{"Authorization": {"Bearer " + cs.secret}}
	}
	c, _, err := websocket.Dial(ctx, u, opts)
	if err != nil {
		return err
	}
	defer c.Close(websocket.StatusNormalClosure, "")
	c.SetReadLimit(8 << 20) // connection lists can be large
	for {
		_, data, err := c.Read(ctx)
		if err != nil {
			return err
		}
		snap, err := decodeSnapshot(data, time.Now().Unix())
		if err != nil {
			continue // skip malformed frame
		}
		select {
		case ch <- snap:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}
