package cli

import (
	"strings"
	"testing"

	"sbtally/internal/core"
)

func TestRenderAppsTable(t *testing.T) {
	apps := []core.AppStat{
		{App: "Safari", Upload: 1048576, Download: 2097152, Total: 3145728},
		{App: "Mail", Upload: 1024, Download: 0, Total: 1024},
	}
	out := RenderApps(apps)
	if !strings.Contains(out, "Safari") || !strings.Contains(out, "3.0 MiB") {
		t.Fatalf("missing Safari/total:\n%s", out)
	}
	if strings.Index(out, "Safari") > strings.Index(out, "Mail") {
		t.Fatalf("order wrong:\n%s", out)
	}
}
