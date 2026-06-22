package source

import "context"

// Connection is one active connection as reported by the Clash API.
type Connection struct {
	ID          string
	Process     string // metadata.process     (may be empty)
	ProcessPath string // metadata.processPath  (may be empty)
	Host        string // metadata.host (sniffed domain; may be empty)
	DestIP      string
	DestPort    string
	Network     string
	Chains      []string
	Rule        string
	Upload      int64 // cumulative bytes for this connection
	Download    int64
}

// Snapshot is a full set of active connections at a point in time.
type Snapshot struct {
	At          int64 // unix seconds
	Connections []Connection
}

// ConnectionsSource is the swappable data tap.
type ConnectionsSource interface {
	Snapshots(ctx context.Context) (<-chan Snapshot, error)
}
