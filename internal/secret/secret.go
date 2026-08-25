// Package secret resolves the sing-box Clash API secret at the moment it is
// needed rather than once at startup.
//
// 引擎那份 secret 是会变的：`control-secret` 文件丢了引擎就重新生成一份。把它在
// 进程启动时读进变量，采集端就会从那一刻起一直拿着一把废钥匙 —— 而且是静默的：
// Clash API 只是回 401，统计页看上去「没有数据」，没有任何地方说得出为什么。
// 每次要用的时候现读，引擎换了钥匙下一次重连就自己好了。
package secret

import (
	"bufio"
	"errors"
	"io"
	"os"
	"strings"
)

// Source hands back the secret to use for the next request. It is called on
// every use, so an implementation is expected to be cheap.
type Source func() string

// Static always returns the same value. Used for the SBTALLY_SECRET fallback
// and in tests.
func Static(value string) Source {
	return func() string { return value }
}

// FromFile reads the secret out of path on every call. A missing or unreadable
// file yields "" — the same as「没有 secret」, which is what an engine without a
// configured secret looks like — so a transient read failure degrades to one
// failed request instead of a crash.
func FromFile(path string) Source {
	return func() string {
		data, err := os.ReadFile(path)
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(data))
	}
}

// Resolve is the nil-safe way to call a Source.
func Resolve(s Source) string {
	if s == nil {
		return ""
	}
	return s()
}

// FromLifeline reads the first line of r as the secret and hands back a channel
// that closes when r reaches EOF.
//
// 这是给「有监护人的采集器」用的：特权助手用 root 起引擎，那份引擎的 Clash 密钥
// 按设计不落到 App 手里，也不该落到磁盘、命令行或环境变量里 —— 命令行 `ps` 全机
// 可见，环境变量和磁盘文件同用户可读。走一根管子进来，谁都读不到。
//
// 同一根管子顺带当命脉：监护人一走，写端关闭，r 到 EOF，采集器自己退场。没有这
// 一条的话，助手被 SIGKILL 或者中间隔了一层 sudo，采集器就会变成一个还占着统计
// 端口的孤儿。
func FromLifeline(r io.Reader) (Source, <-chan struct{}, error) {
	reader := bufio.NewReader(r)
	line, err := reader.ReadString('\n')
	if err != nil && err != io.EOF {
		return nil, nil, err
	}
	value := strings.TrimSpace(line)
	if value == "" {
		return nil, nil, errors.New("stdin 上没有密钥")
	}
	closed := make(chan struct{})
	go func() {
		defer close(closed)
		// 剩下的字节一概不要，只等这根管子断掉。
		_, _ = io.Copy(io.Discard, reader)
	}()
	return Static(value), closed, nil
}
