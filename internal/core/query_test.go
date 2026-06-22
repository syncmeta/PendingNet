package core

import (
	"path/filepath"
	"testing"
)

func seed(t *testing.T) *Store {
	t.Helper()
	s, err := OpenStore(filepath.Join(t.TempDir(), "q.db"))
	if err != nil {
		t.Fatal(err)
	}
	rs := []Rollup{
		{Bucket: 0, App: "Safari", Host: "a.com", Upload: 100, Download: 10},
		{Bucket: 0, App: "Safari", Host: "b.com", Upload: 50, Download: 5},
		{Bucket: 3600, App: "Mail", Host: "c.com", Upload: 200, Download: 20},
	}
	if err := s.WriteRollups(rs); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestApps(t *testing.T) {
	s := seed(t)
	defer s.Close()
	apps, err := s.Apps(0, 7200, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(apps) != 2 || apps[0].App != "Mail" || apps[0].Total != 220 {
		t.Fatalf("got %+v; want Mail first (220)", apps)
	}
	if apps[1].App != "Safari" || apps[1].Total != 165 {
		t.Fatalf("got %+v; want Safari second (165)", apps)
	}
}

func TestAppsSinceFilter(t *testing.T) {
	s := seed(t)
	defer s.Close()
	apps, err := s.Apps(3600, 7200, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(apps) != 1 || apps[0].App != "Mail" {
		t.Fatalf("got %+v want only Mail", apps)
	}
}

func TestAppDetail(t *testing.T) {
	s := seed(t)
	defer s.Close()
	d, err := s.AppDetail("Safari", 0, 7200)
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Domains) != 2 || d.Domains[0].Host != "a.com" {
		t.Fatalf("got %+v want a.com first", d.Domains)
	}
}

func TestSummary(t *testing.T) {
	s := seed(t)
	defer s.Close()
	sm, err := s.Summary(0, 7200)
	if err != nil {
		t.Fatal(err)
	}
	if sm.Total != 385 || sm.Apps != 2 || sm.Hosts != 3 {
		t.Fatalf("got %+v want total 385 apps 2 hosts 3", sm)
	}
}

func TestSeries(t *testing.T) {
	s := seed(t)
	defer s.Close()
	pts, err := s.Series("", 0, 7200)
	if err != nil {
		t.Fatal(err)
	}
	if len(pts) != 2 || pts[0].Bucket != 0 || pts[1].Bucket != 3600 {
		t.Fatalf("got %+v want two buckets ordered", pts)
	}
}
