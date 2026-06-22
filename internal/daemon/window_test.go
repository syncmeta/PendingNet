package daemon

import "testing"

func TestParseWindow(t *testing.T) {
	now := int64(1_000_000)
	cases := []struct {
		in        string
		wantSince int64
	}{
		{"24h", now - 86400},
		{"7d", now - 7*86400},
		{"30m", now - 1800},
		{"", now - 86400},
	}
	for _, tc := range cases {
		since, until := parseWindow(tc.in, now)
		if since != tc.wantSince || until != now {
			t.Errorf("parseWindow(%q)=%d,%d want %d,%d", tc.in, since, until, tc.wantSince, now)
		}
	}
}
