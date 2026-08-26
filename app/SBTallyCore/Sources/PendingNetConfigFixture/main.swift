import Foundation
import SBTallyCore

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: PendingNetConfigFixture <output-directory>\n".utf8))
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let selector = PendingNetRuntimeServer.selectorTag(forServerID: "pns_build_acceptance")
let runtime = PendingNetRuntimeServer(
    serverID: "pns_build_acceptance",
    name: "Build acceptance",
    selectorTag: selector,
    proxyOutbounds: Data("""
    [
      {
        "type": "vless",
        "tag": "\(selector)-reality",
        "server": "198.51.100.1",
        "server_port": 443,
        "uuid": "11111111-1111-4111-8111-111111111111",
        "flow": "xtls-rprx-vision",
        "tls": {
          "enabled": true,
          "server_name": "www.example.com",
          "reality": {
            "enabled": true,
            "public_key": "YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE",
            "short_id": "0123456789abcdef"
          },
          "utls": {"enabled": true, "fingerprint": "chrome"}
        }
      },
      {
        "type": "hysteria2",
        "tag": "\(selector)-hy2",
        "server": "198.51.100.1",
        "server_port": 443,
        "password": "build-acceptance",
        "obfs": {"type": "salamander", "password": "build-acceptance"},
        "tls": {"enabled": true, "server_name": "www.example.com", "insecure": true}
      }
    ]
    """.utf8)
)

for (name, tun) in [("root-tun.json", true), ("root-notun.json", false)] {
    let base = try PendingNetRootConfig.make(
        enableTUN: tun,
        controlSecret: "build-acceptance-secret",
        cachePath: output.appendingPathComponent("root-cache.db").path
    )
    try PendingNetLocalConfigComposer.merge(baseConfig: base, runtimeServer: runtime)
        .write(to: output.appendingPathComponent(name), options: .atomic)
}

// iOS 的真实配置生成器把 TUN stack 设为 gvisor。用同一颗刚编出的 CLI 内核检查它，
// 可以实证 `with_gvisor` 在 tag 里；root-tun 那份则覆盖 macOS 实际使用的 system stack。
try PendingNetTunnelConfig.make(
    runtimeServer: runtime,
    routeMode: .global,
    ruleSetDirectory: output.path,
    cachePath: output.appendingPathComponent("tunnel-cache.db").path
).write(to: output.appendingPathComponent("gvisor-tun.json"), options: .atomic)
