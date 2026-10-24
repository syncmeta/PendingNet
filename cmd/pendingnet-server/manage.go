package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sbtally/internal/pairing"
	"sbtally/internal/pnserver"
	"strings"
	"text/tabwriter"
	"time"
)

const managerHelp = `PendingNet VPS 管理
用法: sudo pendingnet [命令]
  （不带参数）             打开管理菜单
  links [--kind all|node|pair|manage] [--ttl 10m]
                           生成标准节点、连接配对或管理链接
  users list               查看配对用户及设备
  users rename <用户 ID> --name <名字>
                           修改用户显示名称
  users revoke <用户 ID>   撤销用户的控制权限和未使用配对链接
  service status|start|stop|restart [--component all|control|reality|hysteria]
                           查看或启停服务
  logs [--component control|reality|hysteria]
                           查看最近 80 条日志
  update                   更新控制服务及发版锁定内核，保留配置和凭据
  ports [--reality 端口] [--hysteria2 端口]
                           查看或更改代理端口，保留密钥与用户
  traffic                  查看每个用户的累计上传和下载字节
  version                  查看 PendingNet 版本
  engine-lock              查看该版本锁定的上游内核
  client export ...        导出 Android / Windows sing-box 配置
状态和链接、用户命令支持 --state-dir；安装细项仍可使用 pendingnet-server。
`

func runLinks(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("links", flag.ContinueOnError)
	fs.SetOutput(stderr)
	dir := fs.String("state-dir", defaultStateDir, "private server state directory")
	kind := fs.String("kind", "all", "all, node, pair, or manage")
	userID := fs.String("user", "", "existing user ID for standard node links")
	ttl := fs.Duration("ttl", 10*time.Minute, "one-time link lifetime (max 24h)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("links takes flags only")
	}
	if *kind != "all" && *kind != "node" && *kind != "pair" && *kind != "manage" {
		return errors.New("--kind must be all, node, pair, or manage")
	}
	if *ttl <= 0 || *ttl > 24*time.Hour {
		return errors.New("--ttl must be greater than zero and at most 24h")
	}
	store := pnserver.NewStore(*dir)
	state, err := store.Load()
	if err != nil {
		return err
	}
	return runUserLinks(store, state, *kind, *userID, *ttl, stdout)
}

// Production uses real managed-service validation. Tests replace only this
// process boundary so CLI state/output can be verified without systemd.
var syncUserServicesForCLI = syncUserServices

func runUserLinks(store *pnserver.Store, state pnserver.State, kind, userID string, ttl time.Duration, stdout io.Writer) error {
	files := []pairing.File{}
	for _, role := range []string{"pair", "manage"} {
		if kind != "all" && kind != role {
			continue
		}
		var file pairing.File
		var err error
		if role == "manage" {
			file, err = store.CreateAdminPairing(ttl)
		} else {
			file, err = store.CreatePairing(ttl)
		}
		if err != nil {
			return err
		}
		files = append(files, file)
		if role == "pair" {
			userID, err = store.PairingUserID(file.Enrollment.Token)
			if err != nil {
				return err
			}
		}
	}
	if err := syncUserServicesForCLI(store); err != nil {
		return err
	}
	if kind == "all" || kind == "node" {
		if userID == "" {
			for _, u := range state.Users {
				if u.Role != "admin" && u.RevokedAt == nil {
					userID = u.ID
					break
				}
			}
		}
		if userID == "" {
			return errors.New("no connection user; generate a pairing link first")
		}
		profile, err := store.UserNodeProfile(userID)
		if err != nil {
			return err
		}
		links, err := pnserver.BuildNodeLinks(profile, state.Name)
		if err != nil {
			return err
		}
		fmt.Fprintln(stdout, "用户 ID：", userID)
		for _, link := range links {
			fmt.Fprintf(stdout, "%s 节点链接：\n%s\n\n", link.Name, link.URL)
		}
	}
	for _, file := range files {
		link, err := file.URL(time.Now())
		if err != nil {
			return err
		}
		label := "连接配对"
		if file.Enrollment.Role == "admin" {
			label = "管理"
		}
		fmt.Fprintf(stdout, "%s链接（一次性，有效期 %s）：\n%s\n\n", label, ttl, link)
	}
	return nil
}

func runUsers(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		return errors.New("usage: pendingnet users list|revoke <user ID> [--state-dir path]")
	}
	command := args[0]
	args = args[1:]
	id := ""
	if command == "revoke" || command == "rename" {
		if len(args) == 0 || strings.HasPrefix(args[0], "-") {
			return errors.New("revoke requires a user ID")
		}
		id = args[0]
		args = args[1:]
	} else if command != "list" {
		return errors.New("users supports list, rename, or revoke")
	}
	fs := flag.NewFlagSet("users "+command, flag.ContinueOnError)
	fs.SetOutput(stderr)
	dir := fs.String("state-dir", defaultStateDir, "private server state directory")
	name := fs.String("name", "", "user display name for rename")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("unexpected users arguments")
	}
	store := pnserver.NewStore(*dir)
	if command == "rename" {
		if err := store.RenameUser(id, *name); err != nil {
			return err
		}
		fmt.Fprintln(stdout, "用户名称已保存")
		return nil
	}
	if command == "revoke" {
		if err := store.RevokeUser(id); err != nil {
			return err
		}
		if store.UserTrafficEnabled() {
			if err := syncUserServicesForCLI(store); err != nil {
				return err
			}
		}
		fmt.Fprintln(stdout, "已撤销用户：", id)
		if store.UserTrafficEnabled() {
			fmt.Fprintln(stdout, "该用户的 Reality 和 Hysteria2 凭据已禁用。")
		} else {
			fmt.Fprintln(stdout, "未启用独立用户代理：标准节点凭据仍有效。")
		}
		return nil
	}
	state, err := store.Load()
	if err != nil {
		return err
	}
	w := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	traffic, err := store.UserTraffic()
	if err != nil {
		return err
	}
	fmt.Fprintln(w, "用户 ID\t名称\t角色\t状态\t设备数\t上传字节\t下载字节")
	for _, u := range state.Users {
		count := 0
		for _, d := range state.Devices {
			if d.UserID == u.ID {
				count++
			}
		}
		role := "连接"
		if u.Role == "admin" {
			role = "管理"
		}
		status := "有效"
		if u.RevokedAt != nil {
			status = "已撤销"
		}
		fmt.Fprintf(w, "%s\t%q\t%s\t%s\t%d\t%d\t%d\n", u.ID, u.Name, role, status, count, traffic[u.ID].Upload, traffic[u.ID].Download)
	}
	return w.Flush()
}

var serviceUnits = map[string]string{"control": "pendingnet-server.service", "reality": "pendingnet-xray.service", "hysteria": "pendingnet-hysteria.service"}

func runServices(args []string, stdout, stderr io.Writer, logs bool) error {
	action := "status"
	if !logs {
		if len(args) == 0 {
			return errors.New("service requires status, start, stop, or restart")
		}
		action = args[0]
		args = args[1:]
		if action != "status" && action != "start" && action != "stop" && action != "restart" {
			return errors.New("unsupported service action")
		}
	}
	fs := flag.NewFlagSet("service", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fallback := "all"
	if logs {
		fallback = "control"
	}
	component := fs.String("component", fallback, "all, control, reality, or hysteria")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("unexpected service arguments")
	}
	units := []string{}
	if *component == "all" {
		units = []string{serviceUnits["control"], serviceUnits["reality"], serviceUnits["hysteria"]}
	} else if unit, ok := serviceUnits[*component]; ok {
		units = []string{unit}
	} else {
		return errors.New("unknown service component")
	}
	if !logs && action != "status" && os.Geteuid() != 0 {
		return errors.New("service changes must run as root")
	}
	name := "systemctl"
	command := append([]string{action, "--no-pager"}, units...)
	if logs {
		name = "journalctl"
		command = []string{"--no-pager", "-n", "80"}
		for _, u := range units {
			command = append(command, "-u", u)
		}
	}
	run := func() error {
		cmd := exec.Command(name, command...)
		cmd.Stdout = stdout
		cmd.Stderr = stderr
		return cmd.Run()
	}
	if logs || action == "status" {
		return run()
	}
	store := pnserver.NewStore(defaultStateDir)
	return store.WithEngineOperationLock(func() error {
		if action == "stop" || action == "restart" {
			if err := collectUserTraffic(store); err != nil {
				fmt.Fprintln(stderr, "刷新停止前流量统计失败：", err)
			}
		}
		return run()
	})
}

func runUpdate(args []string, stdout, stderr io.Writer) error {
	if len(args) != 0 {
		return errors.New("update takes no arguments; use vps-install.sh for custom repositories")
	}
	if os.Geteuid() != 0 {
		return errors.New("update must run as root")
	}
	dir, err := os.MkdirTemp("", "pendingnet-update-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "vps-install.sh")
	cmd := exec.Command("curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--max-time", "60", "--output", path, "https://raw.githubusercontent.com/syncmeta/PendingNet/main/deploy/vps-install.sh")
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("download installer: %w", err)
	}
	cmd = exec.Command("bash", path, "--update-only")
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	return cmd.Run()
}

func runMenu(input io.Reader, stdout, stderr io.Writer, stateDir string) error {
	scanner := bufio.NewScanner(input)
	read := func(prompt string) (string, bool) {
		fmt.Fprint(stdout, prompt)
		if !scanner.Scan() {
			return "", false
		}
		return strings.TrimSpace(scanner.Text()), true
	}
	for {
		fmt.Fprintln(stdout, "\nPendingNet VPS 管理\n1. 查看状态\n2. 生成节点、连接和管理链接\n3. 生成连接配对链接\n4. 生成管理链接\n5. 查看用户\n6. 撤销用户\n7. 查看日志\n8. 重启服务\n9. 停止服务\n10. 启动服务\n11. 更新 PendingNet 和内核\n12. 查看版本与内核目标\n13. 用户改名\n14. 查看用户流量\n15. 更改端口\n0. 退出")
		choice, ok := read("选择：")
		if !ok {
			return scanner.Err()
		}
		var err error
		switch choice {
		case "0", "q", "exit":
			return nil
		case "1":
			err = runStatus([]string{"--state-dir", stateDir}, stdout, stderr)
			if err == nil {
				err = runServices([]string{"status"}, stdout, stderr, false)
			}
		case "2", "3", "4":
			kind := "all"
			if choice == "3" {
				kind = "pair"
			}
			if choice == "4" {
				kind = "manage"
			}
			err = runLinks([]string{"--state-dir", stateDir, "--kind", kind}, stdout, stderr)
		case "5":
			err = runUsers([]string{"list", "--state-dir", stateDir}, stdout, stderr)
		case "6":
			id, ok := read("要撤销的用户 ID（留空取消）：")
			if !ok {
				return scanner.Err()
			}
			if id == "" {
				continue
			}
			confirm, ok := read("撤销控制权限和未使用配对链接？输入 yes：")
			if !ok {
				return scanner.Err()
			}
			if confirm != "yes" {
				continue
			}
			err = runUsers([]string{"revoke", id, "--state-dir", stateDir}, stdout, stderr)
		case "15":
			err = runPortsMenu(read, stdout, stderr, stateDir)
		case "14":
			err = runUserTraffic([]string{"--state-dir", stateDir}, stdout, stderr)
		case "13":
			id, ok := read("用户 ID（留空取消）：")
			if !ok {
				return scanner.Err()
			}
			if id == "" {
				continue
			}
			name, ok := read("新名称：")
			if !ok {
				return scanner.Err()
			}
			err = runUsers([]string{"rename", id, "--name", name, "--state-dir", stateDir}, stdout, stderr)
		case "7":
			err = runServices(nil, stdout, stderr, true)
		case "8", "9", "10", "11":
			confirm, ok := read("操作可能短暂中断连接，继续请输入 yes：")
			if !ok {
				return scanner.Err()
			}
			if confirm != "yes" {
				continue
			}
			if choice == "11" {
				err = runUpdate(nil, stdout, stderr)
			} else {
				action := map[string]string{"8": "restart", "9": "stop", "10": "start"}[choice]
				err = runServices([]string{action}, stdout, stderr, false)
			}
		case "12":
			err = runVersion(nil, stdout, stderr)
			if err == nil {
				err = run([]string{"engine-lock"}, stdout, stderr)
			}
		default:
			fmt.Fprintln(stderr, "请输入菜单编号。")
		}
		if err != nil {
			fmt.Fprintln(stderr, "操作失败：", err)
		}
	}
}

func runInstallCommand(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("install-command", flag.ContinueOnError)
	fs.SetOutput(stderr)
	path := fs.String("path", "/usr/local/bin/pendingnet", "management command alias path")
	target := fs.String("target", "/usr/local/bin/pendingnet-server", "server executable path")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("unexpected install-command arguments")
	}
	if err := pnserver.InstallCommandAlias(*target, *path); err != nil {
		return err
	}
	fmt.Fprintln(stdout, *path)
	return nil
}
