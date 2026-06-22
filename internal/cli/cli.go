package cli

import (
	"fmt"
	"strings"
	"text/tabwriter"

	"sbtally/internal/core"
)

func RenderApps(apps []core.AppStat) string {
	var b strings.Builder
	w := tabwriter.NewWriter(&b, 0, 2, 2, ' ', 0)
	fmt.Fprintln(w, "APP\tUP\tDOWN\tTOTAL")
	for _, a := range apps {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", a.App,
			core.HumanBytes(a.Upload), core.HumanBytes(a.Download), core.HumanBytes(a.Total))
	}
	w.Flush()
	return b.String()
}

func RenderDomains(ds []core.DomainStat) string {
	var b strings.Builder
	w := tabwriter.NewWriter(&b, 0, 2, 2, ' ', 0)
	fmt.Fprintln(w, "HOST\tUP\tDOWN\tTOTAL")
	for _, d := range ds {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", d.Host,
			core.HumanBytes(d.Upload), core.HumanBytes(d.Download), core.HumanBytes(d.Total))
	}
	w.Flush()
	return b.String()
}

func RenderAppDetail(d core.AppDetail) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n", d.App)
	w := tabwriter.NewWriter(&b, 0, 2, 2, ' ', 0)
	fmt.Fprintln(w, "HOST\tUP\tDOWN\tTOTAL")
	for _, ds := range d.Domains {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", ds.Host,
			core.HumanBytes(ds.Upload), core.HumanBytes(ds.Download), core.HumanBytes(ds.Total))
	}
	w.Flush()
	return b.String()
}
