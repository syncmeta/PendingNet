package core

import "strconv"

func (s *Store) Apps(since, until int64, top int) ([]AppStat, error) {
	q := `SELECT app, COALESCE(SUM(upload),0), COALESCE(SUM(download),0), COALESCE(SUM(upload+download),0) AS total
	      FROM traffic WHERE bucket>=? AND bucket<? GROUP BY app ORDER BY total DESC`
	if top > 0 {
		q += " LIMIT " + strconv.Itoa(top)
	}
	rows, err := s.db.Query(q, since, until)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AppStat{}
	for rows.Next() {
		var a AppStat
		if err := rows.Scan(&a.App, &a.Upload, &a.Download, &a.Total); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

func (s *Store) Domains(since, until int64, top int) ([]DomainStat, error) {
	q := `SELECT host, COALESCE(SUM(upload),0), COALESCE(SUM(download),0), COALESCE(SUM(upload+download),0) AS total
	      FROM traffic WHERE bucket>=? AND bucket<? GROUP BY host ORDER BY total DESC`
	if top > 0 {
		q += " LIMIT " + strconv.Itoa(top)
	}
	rows, err := s.db.Query(q, since, until)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []DomainStat{}
	for rows.Next() {
		var d DomainStat
		if err := rows.Scan(&d.Host, &d.Upload, &d.Download, &d.Total); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *Store) AppDetail(app string, since, until int64) (AppDetail, error) {
	rows, err := s.db.Query(`SELECT host, COALESCE(SUM(upload),0), COALESCE(SUM(download),0), COALESCE(SUM(upload+download),0) AS total
		FROM traffic WHERE app=? AND bucket>=? AND bucket<? GROUP BY host ORDER BY total DESC`, app, since, until)
	if err != nil {
		return AppDetail{}, err
	}
	defer rows.Close()
	d := AppDetail{App: app, Domains: []DomainStat{}}
	for rows.Next() {
		var ds DomainStat
		if err := rows.Scan(&ds.Host, &ds.Upload, &ds.Download, &ds.Total); err != nil {
			return AppDetail{}, err
		}
		d.Domains = append(d.Domains, ds)
	}
	return d, rows.Err()
}

func (s *Store) Series(app string, since, until int64) ([]Point, error) {
	q := `SELECT bucket, COALESCE(SUM(upload),0), COALESCE(SUM(download),0) FROM traffic WHERE bucket>=? AND bucket<?`
	args := []any{since, until}
	if app != "" {
		q += " AND app=?"
		args = append(args, app)
	}
	q += " GROUP BY bucket ORDER BY bucket"
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Point{}
	for rows.Next() {
		var p Point
		if err := rows.Scan(&p.Bucket, &p.Upload, &p.Download); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) Summary(since, until int64) (Summary, error) {
	row := s.db.QueryRow(`SELECT COALESCE(SUM(upload),0), COALESCE(SUM(download),0),
		COUNT(DISTINCT app), COUNT(DISTINCT host) FROM traffic WHERE bucket>=? AND bucket<?`, since, until)
	sm := Summary{Since: since}
	if err := row.Scan(&sm.Upload, &sm.Download, &sm.Apps, &sm.Hosts); err != nil {
		return Summary{}, err
	}
	sm.Total = sm.Upload + sm.Download
	return sm, nil
}
