package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"

	"sbtally/internal/pnserver"
)

// Tests replace the systemd boundary; all snapshot and input handling stays real.
var changePortsForCLI = changeProxyPorts

func readProxyPorts(dir string) (pnserver.ManagedConfig, pnserver.ProxyPorts, error) {
	c, err := pnserver.NewStore(dir).ReadManagedConfig(filepath.Join(dir, "services"))
	if err != nil {
		return c, pnserver.ProxyPorts{}, err
	}
	p, err := pnserver.ManagedConfigPorts(c)
	return c, p, err
}

func runPorts(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("ports", flag.ContinueOnError)
	fs.SetOutput(stderr)
	dir := fs.String("state-dir", defaultStateDir, "private server state directory")
	reality := fs.String("reality", "", "Reality TCP port (1-65535)")
	hy2 := fs.String("hysteria2", "", "Hysteria2 UDP port (1-65535)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("ports takes flags only")
	}
	writes := false
	var inputErr error
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "reality" || f.Name == "hysteria2" {
			writes = true
			if _, err := parseProxyPort(f.Value.String()); err != nil {
				inputErr = err
			}
		}
	})
	if inputErr != nil {
		return inputErr
	}
	c, old, err := readProxyPorts(*dir)
	if err != nil {
		return err
	}
	if !writes {
		printProxyPorts(stdout, old)
		return nil
	}
	next, err := parseProxyPorts(old, *reality, *hy2)
	if err != nil {
		return err
	}
	return applyProxyPorts(*dir, c.Revision, old, next, stdout, stderr)
}

func parseProxyPort(text string) (int, error) {
	p, err := strconv.Atoi(strings.TrimSpace(text))
	if err != nil || p < 1 || p > 65535 {
		return 0, errors.New("端口必须是 1 到 65535 之间的整数")
	}
	return p, nil
}

func parseProxyPorts(old pnserver.ProxyPorts, reality, hy2 string) (pnserver.ProxyPorts, error) {
	next := old
	var err error
	if strings.TrimSpace(reality) != "" {
		next.Reality, err = parseProxyPort(reality)
		if err != nil {
			return next, err
		}
	}
	if strings.TrimSpace(hy2) != "" {
		next.Hysteria2, err = parseProxyPort(hy2)
	}
	return next, err
}

func printProxyPorts(w io.Writer, p pnserver.ProxyPorts) {
	fmt.Fprintf(w, "Reality：TCP/%d\nHysteria2：UDP/%d\n", p.Reality, p.Hysteria2)
}

func applyProxyPorts(dir, revision string, old, next pnserver.ProxyPorts, stdout, stderr io.Writer) error {
	if old == next {
		fmt.Fprintln(stdout, "端口未改变。")
		return nil
	}
	if err := changePortsForCLI(pnserver.NewStore(dir), revision, old, next); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "代理端口已更改，现有密钥和用户已保留：")
	printProxyPorts(stdout, next)
	fmt.Fprintln(stdout, "请确认 VPS 防火墙和云安全组已放行新端口。客户端需刷新节点配置；标准节点链接需重新导入。")
	return nil
}

func runPortsMenu(read func(string) (string, bool), stdout, stderr io.Writer, dir string) error {
	c, old, err := readProxyPorts(dir)
	if err != nil {
		return err
	}
	fmt.Fprintln(stdout, "当前代理端口：")
	printProxyPorts(stdout, old)
	reality, ok := read("Reality TCP 新端口（留空保持）：")
	if !ok {
		return nil
	}
	hy2, ok := read("Hysteria2 UDP 新端口（留空保持）：")
	if !ok {
		return nil
	}
	next, err := parseProxyPorts(old, reality, hy2)
	if err != nil {
		return err
	}
	if next != old {
		fmt.Fprintln(stdout, "将更改为：")
		printProxyPorts(stdout, next)
		fmt.Fprintln(stdout, "请先放行新端口。应用时会短暂中断代理连接，客户端需刷新配置。")
		confirm, ok := read("保留现有密钥和用户并更改端口？输入 yes：")
		if !ok || confirm != "yes" {
			fmt.Fprintln(stdout, "已取消。")
			return nil
		}
	}
	return applyProxyPorts(dir, c.Revision, old, next, stdout, stderr)
}

func changeProxyPorts(store *pnserver.Store, revision string, old, next pnserver.ProxyPorts) error {
	hooks, err := userProxyHooks(store)
	if err != nil {
		return err
	}
	validate := hooks.Validate
	hooks.Validate = func(paths pnserver.ManagedConfigPaths) error {
		if err := checkProxyPortAvailability(store, old, next); err != nil {
			return err
		}
		return validate(paths)
	}
	return store.ChangePorts(filepath.Join(store.Dir, "services"), revision, next, hooks)
}

func checkProxyPortAvailability(store *pnserver.Store, old, next pnserver.ProxyPorts) error {
	if next.Reality != old.Reality {
		// Reserve configured control and statistics ports even when stopped.
		state, err := pnserver.NewStore(store.Dir).Load()
		if err != nil {
			return err
		}
		u, err := url.Parse(state.ControlEndpoint)
		if err != nil {
			return err
		}
		control := u.Port()
		if control == "" {
			control = "443"
		}
		if strconv.Itoa(next.Reality) == control || (store.UserTrafficEnabled() && (next.Reality == 17445 || next.Reality == 17446)) {
			return errors.New("该 TCP 端口用于管理接口或流量统计，请选择其他端口")
		}
		if err := checkListenPort("tcp", next.Reality); err != nil {
			return err
		}
	}
	if next.Hysteria2 != old.Hysteria2 {
		if err := checkListenPort("udp", next.Hysteria2); err != nil {
			return err
		}
	}

	return nil
}
