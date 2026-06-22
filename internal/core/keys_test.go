package core

import (
	"testing"

	"sbtally/internal/source"
)

func TestAppKeyFallback(t *testing.T) {
	cases := []struct {
		c    source.Connection
		want string
	}{
		{source.Connection{Process: "Safari"}, "Safari"},
		{source.Connection{ProcessPath: "/Applications/Foo.app/Contents/MacOS/Foo"}, "Foo"},
		{source.Connection{Host: "example.com"}, "example.com"},
		{source.Connection{}, "unknown"},
	}
	for _, tc := range cases {
		if got := AppKey(tc.c); got != tc.want {
			t.Errorf("AppKey(%+v)=%q want %q", tc.c, got, tc.want)
		}
	}
}

func TestHostKeyFallback(t *testing.T) {
	if got := HostKey(source.Connection{Host: "a.com", DestIP: "1.2.3.4"}); got != "a.com" {
		t.Errorf("got %q want a.com", got)
	}
	if got := HostKey(source.Connection{DestIP: "1.2.3.4"}); got != "1.2.3.4" {
		t.Errorf("got %q want 1.2.3.4", got)
	}
	if got := HostKey(source.Connection{}); got != "unknown" {
		t.Errorf("got %q want unknown", got)
	}
}
