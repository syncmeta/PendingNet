package core

import (
	"database/sql"

	_ "modernc.org/sqlite"
)

type Store struct{ db *sql.DB }

func OpenStore(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	for _, p := range []string{"PRAGMA journal_mode=WAL", "PRAGMA busy_timeout=5000"} {
		if _, err := db.Exec(p); err != nil {
			db.Close()
			return nil, err
		}
	}
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS traffic (
		bucket INTEGER NOT NULL, app TEXT NOT NULL, host TEXT NOT NULL,
		upload INTEGER NOT NULL, download INTEGER NOT NULL,
		PRIMARY KEY (bucket, app, host))`); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

// WriteRollups UPSERT-accumulates rollups in one transaction.
func (s *Store) WriteRollups(rs []Rollup) error {
	if len(rs) == 0 {
		return nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	stmt, err := tx.Prepare(`INSERT INTO traffic (bucket,app,host,upload,download) VALUES (?,?,?,?,?)
		ON CONFLICT(bucket,app,host) DO UPDATE SET
		  upload=upload+excluded.upload, download=download+excluded.download`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, r := range rs {
		if _, err := stmt.Exec(r.Bucket, r.App, r.Host, r.Upload, r.Download); err != nil {
			return err
		}
	}
	return tx.Commit()
}
