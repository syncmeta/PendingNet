package daemon

import (
	"strconv"
	"strings"
)

// parseWindow turns "24h"/"7d"/"30m" into (since, until=now). Empty -> 24h.
func parseWindow(s string, now int64) (since, until int64) {
	until = now
	if s == "" {
		return now - 86400, until
	}
	unit := s[len(s)-1]
	n, err := strconv.ParseInt(strings.TrimSpace(s[:len(s)-1]), 10, 64)
	if err != nil {
		return now - 86400, until
	}
	var secs int64
	switch unit {
	case 'd':
		secs = n * 86400
	case 'h':
		secs = n * 3600
	case 'm':
		secs = n * 60
	default:
		secs = 86400
	}
	return now - secs, until
}
