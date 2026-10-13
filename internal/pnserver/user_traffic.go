package pnserver

import (
	"errors"
	"math"
	"os"
	"path/filepath"
	"time"
)

type TrafficCounters struct {
	Upload   int64 `json:"upload"`
	Download int64 `json:"download"`
}
type TrafficSample struct {
	Epoch string                     `json:"epoch"`
	Users map[string]TrafficCounters `json:"users"`
}
type UserTrafficLedger struct {
	Version   int                        `json:"version"`
	UpdatedAt time.Time                  `json:"updated_at"`
	Totals    map[string]TrafficCounters `json:"totals"`
	Last      map[string]TrafficSample   `json:"last"`
}

func (s *Store) loadTrafficLedger() (UserTrafficLedger, error) {
	value := UserTrafficLedger{Version: 1, Totals: map[string]TrafficCounters{}, Last: map[string]TrafficSample{}}
	data, err := os.ReadFile(filepath.Join(s.Dir, "user-traffic.json"))
	if errors.Is(err, os.ErrNotExist) {
		return value, nil
	}
	if err != nil {
		return value, err
	}
	if err = jsonUnmarshalStrict(data, &value); err != nil {
		return value, err
	}
	if value.Version != 1 || value.Totals == nil || value.Last == nil {
		return value, errors.New("invalid traffic ledger")
	}
	return value, nil
}

// Samples are cumulative counters for a specific process incarnation. Never
// clear kernel counters: poll retries therefore cannot double count traffic.
func (s *Store) RecordUserTraffic(engine, epoch string, users map[string]TrafficCounters) error {
	if (engine != "xray" && engine != "hysteria2") || epoch == "" {
		return errors.New("invalid traffic sample identity")
	}
	for _, v := range users {
		if v.Upload < 0 || v.Download < 0 {
			return errors.New("negative traffic counter")
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	unlock, err := lockStateFile(filepath.Join(s.Dir, "state.lock"))
	if err != nil {
		return err
	}
	defer unlock()
	value, err := s.loadTrafficLedger()
	if err != nil {
		return err
	}
	last := value.Last[engine]
	for id, current := range users {
		prior := TrafficCounters{}
		if last.Epoch == epoch {
			prior = last.Users[id]
		}
		delta := current
		if current.Upload >= prior.Upload {
			delta.Upload -= prior.Upload
		}
		if current.Download >= prior.Download {
			delta.Download -= prior.Download
		}
		total := value.Totals[id]
		if total.Upload > math.MaxInt64-delta.Upload || total.Download > math.MaxInt64-delta.Download {
			return errors.New("traffic total overflow")
		}
		total.Upload += delta.Upload
		total.Download += delta.Download
		value.Totals[id] = total
	}
	// Preserve absent counters in this incarnation; a temporarily absent user
	// must not have its entire old counter charged again when it reappears.
	merged := map[string]TrafficCounters{}
	if last.Epoch == epoch {
		for id, v := range last.Users {
			merged[id] = v
		}
	}
	for id, v := range users {
		merged[id] = v
	}
	value.Last[engine] = TrafficSample{Epoch: epoch, Users: merged}
	value.UpdatedAt = s.now()
	return writePrivateJSON(filepath.Join(s.Dir, "user-traffic.json"), value)
}

func (s *Store) UserTraffic() (map[string]TrafficCounters, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, err := s.loadTrafficLedger()
	return v.Totals, err
}

// CLI and daemon sampling must not commit an older cumulative sample after a
// newer one. The sampler lock covers fetching as well as ledger persistence.
func (s *Store) WithTrafficSamplerLock(sample func() error) error {
	unlock, err := lockStateFile(filepath.Join(s.Dir, "traffic-sample.lock"))
	if err != nil {
		return err
	}
	defer unlock()
	return sample()
}
