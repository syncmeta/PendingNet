package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// defaultGeositeBase/defaultGeoipBase are the upstream hosts for the four
// SagerNet-published rule-sets. geosite-gfw has no SagerNet equivalent and is
// fetched from MetaCubeX (see ruleSetSpecs).
const (
	defaultGeositeBase = "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
	defaultGeoipBase   = "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set"
	defaultGFWURL      = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/gfw.srs"

	defaultProxyAddr = "http://127.0.0.1:2080"
)

// ruleSetSpec describes one managed rule-set file: its tag (as referenced by
// sing-box route.rule_set), its local file name, and how to build its
// download URL from the (possibly overridden) base URLs.
type ruleSetSpec struct {
	tag        string
	file       string
	remoteName string // file name on the remote host; "" means use the fixed GFW URL
	useGeoip   bool
}

var ruleSetSpecs = []ruleSetSpec{
	{tag: "geosite-cn", file: "geosite-cn.srs", remoteName: "geosite-cn.srs"},
	{tag: "geoip-cn", file: "geoip-cn.srs", remoteName: "geoip-cn.srs", useGeoip: true},
	{tag: "geosite-noncn", file: "geosite-geolocation-noncn.srs", remoteName: "geosite-geolocation-!cn.srs"},
	{tag: "geosite-ads", file: "geosite-category-ads-all.srs", remoteName: "geosite-category-ads-all.srs"},
	{tag: "geosite-gfw", file: "geosite-gfw.srs"}, // remoteName empty: fixed GFW URL below
}

// RuleSetStatus reports the on-disk state of one managed rule-set file.
type RuleSetStatus struct {
	Tag     string
	File    string
	ModTime time.Time
}

// RuleSetUpdater downloads the sing-box rule-set files (geosite/geoip .srs)
// used by the generated configs and atomically replaces them on disk. A
// failed download never touches the existing file, so the daemon and
// sing-box keep working fully offline if GitHub is unreachable.
type RuleSetUpdater struct {
	Dir       string
	ProxyAddr string // default "http://127.0.0.1:2080"; used only when Client is nil
	Client    *http.Client

	// geositeBase/geoipBase let tests point the two SagerNet-hosted families
	// at an httptest server. The GFW file's URL is fixed (different host) and
	// is not overridden by these fields, except when both are set to the same
	// test server URL, in which case GFW is redirected there too so tests can
	// exercise all five files against one fake source.
	geositeBase string
	geoipBase   string

	mu       sync.Mutex
	statuses map[string]time.Time // file -> mod time of last successful update
}

// NewRuleSetUpdater builds an updater rooted at dir. proxyAddr overrides the
// default local mixed-inbound proxy ("http://127.0.0.1:2080") used to reach
// GitHub; pass "" to use the default. The proxy is only applied when no
// Client is injected (tests inject their own httptest.Server client and
// bypass proxying entirely).
func NewRuleSetUpdater(dir, proxyAddr string) *RuleSetUpdater {
	if proxyAddr == "" {
		proxyAddr = defaultProxyAddr
	}
	return &RuleSetUpdater{
		Dir:         dir,
		ProxyAddr:   proxyAddr,
		geositeBase: defaultGeositeBase,
		geoipBase:   defaultGeoipBase,
		statuses:    make(map[string]time.Time),
	}
}

func (u *RuleSetUpdater) client() (*http.Client, error) {
	if u.Client != nil {
		return u.Client, nil
	}
	transport := &http.Transport{}
	if u.ProxyAddr != "" {
		pu, err := url.Parse(u.ProxyAddr)
		if err != nil {
			return nil, fmt.Errorf("invalid proxy addr %q: %w", u.ProxyAddr, err)
		}
		transport.Proxy = http.ProxyURL(pu)
	}
	return &http.Client{Transport: transport, Timeout: 60 * time.Second}, nil
}

func (u *RuleSetUpdater) urlFor(spec ruleSetSpec) string {
	if spec.remoteName == "" {
		// GFW file: fixed MetaCubeX URL in production. Tests that set both
		// base URLs to the same fake server want GFW redirected there too.
		if u.geositeBase != "" && u.geositeBase != defaultGeositeBase {
			return u.geositeBase + "/" + spec.file
		}
		return defaultGFWURL
	}
	base := u.geositeBase
	if spec.useGeoip {
		base = u.geoipBase
	}
	return base + "/" + spec.remoteName
}

// UpdateAll downloads every managed rule-set file and atomically replaces it
// on disk. It returns a map of file name -> error (nil entry means success).
// A download failure leaves the existing file untouched.
func (u *RuleSetUpdater) UpdateAll(ctx context.Context) map[string]error {
	client, err := u.client()
	results := make(map[string]error, len(ruleSetSpecs))
	if err != nil {
		for _, spec := range ruleSetSpecs {
			results[spec.file] = err
		}
		return results
	}

	for _, spec := range ruleSetSpecs {
		results[spec.file] = u.updateOne(ctx, client, spec)
	}
	return results
}

func (u *RuleSetUpdater) updateOne(ctx context.Context, client *http.Client, spec ruleSetSpec) error {
	dest := filepath.Join(u.Dir, spec.file)
	tmp := dest + ".tmp"

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.urlFor(spec), nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download %s: unexpected status %s", spec.file, resp.Status)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if len(body) == 0 {
		return fmt.Errorf("download %s: empty body", spec.file)
	}

	if err := os.WriteFile(tmp, body, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, dest); err != nil {
		os.Remove(tmp)
		return err
	}

	u.mu.Lock()
	u.statuses[spec.file] = time.Now()
	u.mu.Unlock()
	return nil
}

// Status reports the current on-disk state of every managed rule-set file.
// It prefers the in-memory record of the last successful update (accurate
// even under test file systems with coarse mtimes); if a file has never been
// updated this run, it falls back to the file's mtime on disk, if present.
func (u *RuleSetUpdater) Status() []RuleSetStatus {
	u.mu.Lock()
	defer u.mu.Unlock()

	out := make([]RuleSetStatus, 0, len(ruleSetSpecs))
	for _, spec := range ruleSetSpecs {
		mt := u.statuses[spec.file]
		if mt.IsZero() {
			if fi, err := os.Stat(filepath.Join(u.Dir, spec.file)); err == nil {
				mt = fi.ModTime()
			}
		}
		out = append(out, RuleSetStatus{Tag: spec.tag, File: spec.file, ModTime: mt})
	}
	return out
}

// RunEvery runs UpdateAll on a recurring schedule: first after a 2-minute
// delay (to let the sing-box engine finish warming up so the local proxy is
// actually reachable), then every d. It blocks until ctx is cancelled.
func (u *RuleSetUpdater) RunEvery(ctx context.Context, d time.Duration) {
	timer := time.NewTimer(2 * time.Minute)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return
	case <-timer.C:
		u.UpdateAll(ctx)
	}

	ticker := time.NewTicker(d)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			u.UpdateAll(ctx)
		}
	}
}

// RegisterRuleSets adds the rule-set status/update endpoints to mux:
//
//	GET  /api/rulesets        -> [{"tag","file","updated_at"(RFC3339)}]
//	POST /api/rulesets/update -> runs UpdateAll synchronously; {file: error-string-or-""}
func RegisterRuleSets(mux *http.ServeMux, u *RuleSetUpdater) {
	mux.HandleFunc("/api/rulesets", func(w http.ResponseWriter, r *http.Request) {
		statuses := u.Status()
		type entry struct {
			Tag       string `json:"tag"`
			File      string `json:"file"`
			UpdatedAt string `json:"updated_at"`
		}
		out := make([]entry, 0, len(statuses))
		for _, s := range statuses {
			var ts string
			if !s.ModTime.IsZero() {
				ts = s.ModTime.UTC().Format(time.RFC3339)
			}
			out = append(out, entry{Tag: s.Tag, File: s.File, UpdatedAt: ts})
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(out)
	})

	mux.HandleFunc("/api/rulesets/update", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		errs := u.UpdateAll(r.Context())
		out := make(map[string]string, len(errs))
		for file, err := range errs {
			if err != nil {
				out[file] = err.Error()
			} else {
				out[file] = ""
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(out)
	})
}
