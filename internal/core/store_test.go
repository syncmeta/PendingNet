package core

import (
	"path/filepath"
	"testing"
)

func TestStoreUpsertAccumulates(t *testing.T) {
	path := filepath.Join(t.TempDir(), "t.db")
	s, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	if err := s.WriteRollups([]Rollup{{Bucket: 0, App: "X", Host: "h", Upload: 10, Download: 1}}); err != nil {
		t.Fatal(err)
	}
	if err := s.WriteRollups([]Rollup{{Bucket: 0, App: "X", Host: "h", Upload: 5, Download: 2}}); err != nil {
		t.Fatal(err)
	}
	apps, err := s.Apps(0, 3600, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(apps) != 1 || apps[0].Upload != 15 || apps[0].Download != 3 || apps[0].Total != 18 {
		t.Fatalf("got %+v want one row 15/3/18", apps)
	}
}
