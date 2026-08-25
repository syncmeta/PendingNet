// Package secret resolves the sing-box Clash API secret at the moment it is
// needed rather than once at startup.
//
// 引擎那份 secret 是会变的：`control-secret` 文件丢了引擎就重新生成一份。把它在
// 进程启动时读进变量，采集端就会从那一刻起一直拿着一把废钥匙 —— 而且是静默的：
// Clash API 只是回 401，统计页看上去「没有数据」，没有任何地方说得出为什么。
// 每次要用的时候现读，引擎换了钥匙下一次重连就自己好了。
package secret

import (
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
