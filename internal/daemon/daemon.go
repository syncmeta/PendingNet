package daemon

import (
	"context"
	"time"

	"sbtally/internal/core"
	"sbtally/internal/source"
)

type Daemon struct {
	src           source.ConnectionsSource
	store         *core.Store
	acc           *core.Accumulator
	hub           *LiveHub
	FlushInterval time.Duration
}

func New(src source.ConnectionsSource, store *core.Store, hub *LiveHub) *Daemon {
	return &Daemon{
		src: src, store: store, acc: core.NewAccumulator(), hub: hub,
		FlushInterval: 10 * time.Second,
	}
}

func (d *Daemon) Run(ctx context.Context) error {
	ch, err := d.src.Snapshots(ctx)
	if err != nil {
		return err
	}
	ticker := time.NewTicker(d.FlushInterval)
	defer ticker.Stop()
	var prev *source.Snapshot
	for {
		select {
		case <-ctx.Done():
			d.flush()
			return ctx.Err()
		case snap, ok := <-ch:
			if !ok {
				d.flush()
				return nil
			}
			d.acc.Add(snap)
			if prev != nil {
				d.hub.Publish(computeLive(*prev, snap))
			}
			s := snap
			prev = &s
		case <-ticker.C:
			d.flush()
		}
	}
}

func (d *Daemon) flush() { _ = d.store.WriteRollups(d.acc.Pending()) }
