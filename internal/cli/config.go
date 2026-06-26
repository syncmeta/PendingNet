package cli

import (
	"fmt"
	"os"
	"strings"
	"text/tabwriter"

	"sbtally/internal/sbconfig"
)

// ImportSummary lists the proxy outbounds found in an existing sing-box config.
func ImportSummary(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	obs, err := sbconfig.ExtractOutbounds(data)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	w := tabwriter.NewWriter(&b, 0, 2, 2, ' ', 0)
	fmt.Fprintln(w, "TAG\tTYPE")
	for _, o := range obs {
		fmt.Fprintf(w, "%s\t%s\n", o.Tag, o.Type)
	}
	w.Flush()
	return b.String(), nil
}

// GenerateConfig builds a master config from "name=path" VPS specs, lifting each
// file's outbounds into a VPS group, then delegating to sbconfig.Generate.
func GenerateConfig(vpsSpecs []string, opts sbconfig.Options) ([]byte, error) {
	if len(vpsSpecs) == 0 {
		return nil, fmt.Errorf("no --vps specified")
	}
	var vpsList []sbconfig.VPS
	for _, spec := range vpsSpecs {
		name, path, ok := strings.Cut(spec, "=")
		if !ok || name == "" || path == "" {
			return nil, fmt.Errorf("invalid --vps %q (want name=path)", spec)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		obs, err := sbconfig.ExtractOutbounds(data)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if len(obs) == 0 {
			return nil, fmt.Errorf("%s: no proxy outbounds found", path)
		}
		vpsList = append(vpsList, sbconfig.VPS{Name: name, Outbounds: obs})
	}
	return sbconfig.Generate(vpsList, opts)
}
