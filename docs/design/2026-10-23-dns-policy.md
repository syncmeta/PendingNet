# DNS 策略统一与 Reality 慢速排查

本文记录 DNS 代码设计与发布前验证；线上发布和 VPS 升级须另以发布记录为准。以下隔离测试不证明用户报告的速度已经改善。

## 配置行为

- macOS TUN、系统代理、仅端口模式以及旧 Go 配置生成器：代理解析经所选节点访问 Cloudflare DoH，直连解析使用阿里 DoH。上游连接使用固定 IP 和显式 TLS 名称，无明文 bootstrap 或明文 fallback。
- DNS 选择跟随全局、白名单、黑名单；内部目标解析规则互斥，修复原先国内解析后又被默认解析覆盖的问题。不同上游缓存隔离。
- 节点地址使用域名时由直连 DoH bootstrap，避免“连接代理需要先经过代理解析”的循环。iOS 为代理出站显式指定 bootstrap，目标解析仍保留原有模式策略。
- Android/Windows 的 App 导出和服务端导出都配置 DoH；TUN 导出有 DNS 接管规则，显式代理目标通过 DoH 解析。
- iOS 无法取得隧道 DNS 地址时，在应用网络设置前失败，不再只写日志后继续。
- 新建 VPS 的 Xray 配置使用内置 DoH，Freedom 使用 `ForceIPv4v6`，DoH 失败不退回系统 DNS；Hysteria2 的客户端目标解析使用经过证书验证的 HTTPS resolver。

系统代理/仅端口只覆盖进入引擎的请求，不接管所有应用自行发出的 DNS。服务端规则覆盖代理目标解析，不等于改造整个 VPS 操作系统、管理程序或伪装站点的所有解析。

## 升级行为

- macOS 只迁移旧版本生成的精确 local/UDP 上游形状，保留自定义上游选项；精确识别旧默认分流规则后升级为随模式切换的策略。
- 旧仅端口配置在下一次启动时补上缺失的 DNS，验证成功才保存。已有自定义 DNS 不由该迁移替换。
- 服务端旧裸 Freedom 默认配置和缺失的 Hysteria resolver，在下一次用户配置同步的既有验证、备份、重启和失败回滚事务中迁移。已有自定义 DNS 或 Freedom 设置保留。实际迁移结果须在升级后检查。

## 验证

- 修改前，新增 Go 回归复现 Xray 无加密 resolver、Windows 导出无 DoH、Android 导出无接管规则；Swift 两项回归出现 12 个预期失败。
- `go test ./...` 全套通过。Xray/Hysteria 外部二进制验证测试未提供对应二进制，不能据此声明这两颗内核已实跑。
- Swift 全套 347 项、1 项跳过、0 失败；随后新增部分规则集下载场景，最终 DNS 专项 6 项通过。跳过项是未提供实时配对文件的在线服务测试。
- 配置检查与隔离实跑使用 sing-box 1.14.3，revision `7054cac5124465ffdb145870d7c01885566711b1`，与仓库锁一致。二进制仅作为临时验证器使用。
- `scripts/check-dns-policy.py` 对 Swift root、Swift 仅端口、Go root 分别验证三种模式 × 三类域名 × DNS/HTTP 两种入口，共 54 条路径。使用临时证书、本机 HTTPS DNS 和 HTTP 服务；保留生成器的 DNS/路由规则，替换节点、规则集内容与上游端点，不创建 TUN 或修改系统设置。三份配置均验证 TLS 名称不匹配被拒绝、未回退直连上游。这不证明真实公网 DoH 可达或代理隧道性能。
- iOS 隧道扩展完成 arm64 模拟器 Release 编译和链接。宿主 iOS App 最终链接因磁盘空间不足失败；本轮临时构建目录已清理。未安装或运行 GUI。
- VLESS 分享链接与运行配置的 UUID、服务器、Vision flow、SNI、Reality 公钥、short ID、Chrome 指纹一致性回归通过；未发现生成链接漏掉这些参数。

回归日志在 `/private/tmp/pendingnet-dns-{go-all,swift-all,policy-final,integration,integration-go,ios-build}.log`。

## Windows v2rayN 与 PendingNet Reality 对照

用户确认两侧均为 Reality。当前没有同网络同目标的测量数据，不能把慢速归因于协议选择、DNS 或地理位置。

首先记录客户端和内核版本、接管方式、规则模式、节点、城市/运营商、目标文件、时间；使用相同节点、固定 Reality 和相同测试目标，一次只改变一个条件。不同人不同设备的结果只能作为线索。

| 对照 | 保持相同 | 只改变 | 结果主要指向 |
|---|---|---|---|
| 客户端对照 | 同设备、网络、节点、目标、时段 | 客户端或内核 | 配置、DNS、IPv4/IPv6、分流、TUN 差异 |
| 运营商对照 | 同设备、客户端、节点、目标 | Wi-Fi/手机热点 | 接入网、运营商、到 VPS 的路由 |
| VPS 地区对照 | 同设备、客户端、接入网、目标 | VPS 地区 | 入口/出口线路、节点负载；不能只按物理距离判断 |
| CDN 对照 | 同设备、客户端、节点、目标域名 | 经过验证的目标 IP | DNS/CDN 分配与 VPS 到目标的路径 |

PendingNet 尚无原生 Windows 客户端；严格的同 Windows 对照应使用仓库导出的完整 sing-box 配置，与 v2rayN 的 VLESS 配置比较。Windows v2rayN 与 macOS PendingNet 的比较同时改变了操作系统，不能单独证明客户端差异。

Windows 可针对同一个 HTTPS 静态文件重复三次，记录时间和吞吐。将端口替换为 v2rayN 实际监听端口，将 URL 替换为同一个适量大小的测试文件：

```powershell
curl.exe --proxy http://127.0.0.1:PORT --noproxy never-bypass.invalid --connect-timeout 10 --max-time 60 --output NUL --silent --show-error --write-out 'connect=%{time_connect} tls=%{time_appconnect} first_byte=%{time_starttransfer} total=%{time_total} bytes=%{size_download} bytes_per_sec=%{speed_download}\n' 'https://YOUR_TEST_HOST/test-file'
```

这些是累计时间。代理为本机时，`time_connect` 主要衡量到本机代理的连接，不能当成到 VPS 的 RTT；`time_namelookup` 也不能测出远端目标 DNS 耗时。真正的 DNS 耗时需从同一请求对应的内核日志或独立解析探针取证。

若只是首开慢，优先对比 DNS、握手、IPv6 回退和规则匹配；若大文件持续慢，优先对比 TCP 重传、丢包、路径、带宽和节点负载。ping/路由跟踪只能辅助定位，不能替代代理下载测速；某一中间跳不回应也不单独证明丢包。所有结果均按本地缓存/首访与重复请求分别记录。

修改本地 hosts 或直接用 IP URL 会改变 SNI/Host/CDN 行为，不能作为干净的 DNS 对照。固定目标 IP 的测试必须保留原来的 TLS SNI 和 HTTP Host，并确认代理内核确实连接指定地址。

## 上游依据

- [Xray DoH 与本地模式](https://xtls.github.io/en/config/dns.html)
- [锁定 Xray 版本的 Freedom strategy](https://github.com/XTLS/Xray-core/blob/v26.3.27/infra/conf/freedom.go)
- [Hysteria2 HTTPS resolver](https://v2.hysteria.network/docs/advanced/Full-Server-Config/#resolver)
- [sing-box domain_resolver](https://sing-box.sagernet.org/configuration/shared/dial/#domain_resolver)
- [锁定 sing-box 的非终止 resolve 动作](https://github.com/SagerNet/sing-box/blob/v1.14.3/route/route.go)
