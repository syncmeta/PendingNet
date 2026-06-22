package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"sbtally/internal/cli"
	"sbtally/internal/core"
	"sbtally/internal/daemon"
	"sbtally/internal/source"
)

func defaultDBPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "sbtally", "sbtally.db")
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: sbtally <daemon|apps|domains|app> [flags]")
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
	_ = fs.Parse(args)

	if err := os.MkdirAll(filepath.Dir(*dbPath), 0o755); err != nil {
		fatal(err)
	}
	st, err := core.OpenStore(*dbPath)
	if err != nil {
		fatal(err)
	}
	defer st.Close()

	hub := daemon.NewLiveHub()
	src := source.NewClashSource(*clashAPI, os.Getenv("SBTALLY_SECRET"))
	d := daemon.New(src, st, hub)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	srv := &http.Server{Addr: *listen, Handler: daemon.NewServer(st, hub, func() int64 { return time.Now().Unix() })}
	go func() { _ = srv.ListenAndServe() }()
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

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
