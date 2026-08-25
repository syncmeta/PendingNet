// Package dropprivs re-runs this process under another user's credentials.
//
// 为什么不用 sudo：统计采集器由特权助手用 root 起，但必须落到登录用户身上跑
// （统计库在他的目录里，root 建出来的库和 -wal/-shm 会让「仅端口」模式下那份
// 采集器再也写不进去）。最省事的写法本来是 `sudo -u <user>`，但 sudo 从 1.9.14
// 起默认 use_pty：它会给命令套一个伪终端并自己当中间人。那对我们是两处致命——
// 密钥走 stdin 进来，伪终端的回显会把它抄进日志；而管子断掉的 EOF 传不到孙子
// 进程，采集器就不再是「监护人一走自己退场」，会留下占着统计端口的孤儿。
//
// 所以自己降：fork 出来的子进程在 exec 之前 setgid/setuid，标准输入输出原样继承，
// 中间不隔任何东西。
package dropprivs

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
)

// StripFlag removes `-name value` / `--name value` / `-name=value` from args.
//
// 降身份是「再跑一遍自己，但不要再降一次」，所以重跑用的命令行必须原样保留除了
// 这个开关以外的一切 —— 照着解析结果重新拼一遍迟早会和真正的 flag 集合漂移。
func StripFlag(args []string, name string) []string {
	out := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "-"+name || arg == "--"+name {
			i++ // 连它的值一起丢掉
			continue
		}
		if hasPrefix(arg, "-"+name+"=") || hasPrefix(arg, "--"+name+"=") {
			continue
		}
		out = append(out, arg)
	}
	return out
}

func hasPrefix(s, prefix string) bool {
	return len(s) >= len(prefix) && s[:len(prefix)] == prefix
}

// Rerun executes this binary again with args under uid/gid, wiring the standard
// streams straight through, and returns the child's exit code.
//
// 直连 stdin 是关键：密钥和命脉都在那根管子上。
func Rerun(args []string, uid, gid uint32) (int, error) {
	self, err := os.Executable()
	if err != nil {
		return 0, err
	}
	command := exec.Command(self, args...)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	command.SysProcAttr = &syscall.SysProcAttr{
		Credential: &syscall.Credential{
			Uid: uid,
			Gid: gid,
			// Groups 留空 = 连 root 的附加组（wheel 那些）一起丢掉。
			// 只有 root 调得动 setgroups，所以自己重跑自己那种情况跳过它 ——
			// 那时候本来也没有多余的权限要丢。
			NoSetGroups: os.Getuid() != 0,
		},
	}
	if err := command.Run(); err != nil {
		var exitError *exec.ExitError
		if errors.As(err, &exitError) {
			return exitError.ExitCode(), nil
		}
		return 0, err
	}
	return 0, nil
}
