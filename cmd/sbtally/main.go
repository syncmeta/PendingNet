package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"sbtally/internal/clashapi"
	"sbtally/internal/cli"
	"sbtally/internal/core"
	"sbtally/internal/daemon"
	"sbtally/internal/sbconfig"
	"sbtally/internal/secret"
	"sbtally/internal/source"
)

func defaultDBPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "sbtally", "sbtally.db")
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: sbtally <daemon|apps|domains|app|config> [flags]")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "daemon":
		runDaemon(os.Args[2:])
	case "apps":
		runQuery(os.Args[2:], "apps")
	case "domains":
		runQuery(os.Args[2:], "domains")
	case "app":
		runAppDetail(os.Args[2:])
	case "config":
		runConfig(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", os.Args[1])
		os.Exit(2)
	}
}

func runDaemon(args []string) {
	fs := flag.NewFlagSet("daemon", flag.ExitOnError)
	clashAPI := fs.String("clash-api", "127.0.0.1:9090", "Clash API host:port")
	listen := fs.String("listen", "127.0.0.1:7777", "stats HTTP listen addr")
	dbPath := fs.String("db", defaultDBPath(), "SQLite path")
	flush := fs.Duration("flush", 10*time.Second, "DB flush interval")
	rulesetDir := fs.String("ruleset-dir", "/usr/local/etc/sbtally", "dir containing the sing-box rule-set files to auto-update; empty disables rule-set management")
	secretFile := fs.String("secret-file", "", "file holding the Clash API secret; re-read on every use (overrides SBTALLY_SECRET)")
	_ = fs.Parse(args)

	if err := os.MkdirAll(filepath.Dir(*dbPath), 0o755); err != nil {
		fatal(err)
	}
	st, err := core.OpenStore(*dbPath)
	if err != nil {
		fatal(err)
	}
	defer st.Close()

	// 现读优先于启动时读死：引擎重新生成 secret 之后，采集端下一次重连就自己
	// 恢复，不需要有人来重启它。SBTALLY_SECRET 保留给老的 launchd 单元。
	secretSource := secret.Static(os.Getenv("SBTALLY_SECRET"))
	if *secretFile != "" {
		secretSource = secret.FromFile(*secretFile)
	}
	hub := daemon.NewLiveHub()
	src := source.NewClashSource(*clashAPI, secretSource)
	d := daemon.New(src, st, hub)
	d.FlushInterval = *flush

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	mux := daemon.NewServer(st, hub, func() int64 { return time.Now().Unix() })
	daemon.RegisterControl(mux, clashapi.New(*clashAPI, secretSource))
	// 空 ruleset-dir = 这份规则集由别人管（App 自带的下载器就是），采集端别去
	// 碰它：两个写同一个目录只会互相踩。
	if *rulesetDir != "" {
		rsu := daemon.NewRuleSetUpdater(*rulesetDir, "")
		daemon.RegisterRuleSets(mux, rsu)
		go rsu.RunEvery(ctx, 24*time.Hour)
	}

	// 先自己 Listen 再交给 http.Server：从前这里是
	// `go func() { _ = srv.ListenAndServe() }()`，端口被别人占了错误直接进垃圾桶，
	// 进程照样活着、一个字节都不服务 —— 统计页只会说「尚未启用」，没有任何地方
	// 说得出是端口被占了。现在占了就是启动失败，说清是哪个端口。
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		fatal(fmt.Errorf("统计接口监听 %s 失败（端口多半被其它程序占了）：%w", *listen, err))
	}
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(ln) }()
	defer srv.Close()

	fmt.Printf("sbtally daemon: clash=%s listen=%s db=%s\n", *clashAPI, *listen, *dbPath)
	if err := d.Run(ctx); err != nil && err != context.Canceled {
		fatal(err)
	}
}

func openReadStore(args []string) (*core.Store, string, int) {
	fs := flag.NewFlagSet("q", flag.ExitOnError)
	since := fs.String("since", "24h", "window, e.g. 24h/7d/30m")
	top := fs.Int("top", 20, "limit")
	dbPath := fs.String("db", defaultDBPath(), "SQLite path")
	_ = fs.Parse(args)
	st, err := core.OpenStore(*dbPath)
	if err != nil {
		fatal(err)
	}
	return st, *since, *top
}

func windowFrom(since string) (int64, int64) {
	now := time.Now().Unix()
	if since == "" {
		return now - 86400, now
	}
	unit := since[len(since)-1]
	n, err := strconv.ParseInt(since[:len(since)-1], 10, 64)
	if err != nil {
		return now - 86400, now
	}
	switch unit {
	case 'd':
		return now - n*86400, now
	case 'h':
		return now - n*3600, now
	case 'm':
		return now - n*60, now
	}
	return now - 86400, now
}

func runQuery(args []string, which string) {
	st, since, top := openReadStore(args)
	defer st.Close()
	s, u := windowFrom(since)
	if which == "apps" {
		v, err := st.Apps(s, u, top)
		if err != nil {
			fatal(err)
		}
		fmt.Print(cli.RenderApps(v))
	} else {
		v, err := st.Domains(s, u, top)
		if err != nil {
			fatal(err)
		}
		fmt.Print(cli.RenderDomains(v))
	}
}

func runAppDetail(args []string) {
	if len(args) == 0 {
		fatal(fmt.Errorf("usage: sbtally app <name> [flags]"))
	}
	name := args[0]
	st, since, _ := openReadStore(args[1:])
	defer st.Close()
	s, u := windowFrom(since)
	v, err := st.AppDetail(name, s, u)
	if err != nil {
		fatal(err)
	}
	fmt.Print(cli.RenderAppDetail(v))
}

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(s string) error { *m = append(*m, s); return nil }

func runConfig(args []string) {
	if len(args) == 0 {
		fatal(fmt.Errorf("usage: sbtally config <import <file> | generate --vps name=path ...>"))
	}
	switch args[0] {
	case "import":
		if len(args) < 2 {
			fatal(fmt.Errorf("usage: sbtally config import <file>"))
		}
		s, err := cli.ImportSummary(args[1])
		if err != nil {
			fatal(err)
		}
		fmt.Print(s)
	case "generate":
		runConfigGenerate(args[1:])
	default:
		fatal(fmt.Errorf("unknown config subcommand %q", args[0]))
	}
}

func runConfigGenerate(args []string) {
	fs := flag.NewFlagSet("config generate", flag.ExitOnError)
	var vps multiFlag
	fs.Var(&vps, "vps", "VPS as name=path to an existing sing-box config (repeatable)")
	clashAddr := fs.String("clash-addr", "127.0.0.1:9090", "clash_api external_controller")
	clashSecret := fs.String("clash-secret", "", "clash_api secret")
	mixedPort := fs.Int("mixed-port", 2080, "mixed inbound port")
	tunStack := fs.String("tun-stack", "system", "tun stack (system|gvisor)")
	noTun := fs.Bool("no-tun", false, "omit the tun inbound")
	logLevel := fs.String("log-level", "warn", "sing-box log level (warn|info|debug)")
	out := fs.String("out", "", "output file (default stdout)")
	rulesetDir := fs.String("ruleset-dir", "", "emit local rule-sets from this dir")
	outDir := fs.String("out-dir", "", "write master-tun.json and master-notun.json here")
	_ = fs.Parse(args)

	opts := sbconfig.Options{
		ClashAPIAddr: *clashAddr,
		ClashSecret:  *clashSecret,
		MixedPort:    *mixedPort,
		TunStack:     *tunStack,
		EnableTun:    !*noTun,
		LogLevel:     *logLevel,
		RuleSetDir:   *rulesetDir,
	}

	// If out-dir is provided, generate both variants
	if *outDir != "" {
		// Generate with TUN enabled
		optsTun := opts
		optsTun.EnableTun = true
		cfg, err := cli.GenerateConfig(vps, optsTun)
		if err != nil {
			fatal(err)
		}
		tunPath := filepath.Join(*outDir, "master-tun.json")
		if err := os.WriteFile(tunPath, cfg, 0o644); err != nil {
			fatal(err)
		}
		fmt.Fprintf(os.Stderr, "wrote %s\n", tunPath)

		// Generate without TUN
		optsNoTun := opts
		optsNoTun.EnableTun = false
		cfg, err = cli.GenerateConfig(vps, optsNoTun)
		if err != nil {
			fatal(err)
		}
		notunPath := filepath.Join(*outDir, "master-notun.json")
		if err := os.WriteFile(notunPath, cfg, 0o644); err != nil {
			fatal(err)
		}
		fmt.Fprintf(os.Stderr, "wrote %s\n", notunPath)
		return
	}

	cfg, err := cli.GenerateConfig(vps, opts)
	if err != nil {
		fatal(err)
	}
	if *out != "" {
		if err := os.WriteFile(*out, cfg, 0o644); err != nil {
			fatal(err)
		}
		fmt.Fprintf(os.Stderr, "wrote %s\n", *out)
	} else {
		_, _ = os.Stdout.Write(cfg)
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
