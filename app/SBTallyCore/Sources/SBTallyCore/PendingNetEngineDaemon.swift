import Foundation

/// TUN / 系统代理下那份 root 引擎的 launchd 作业。
///
/// 它的 plist 从前只由老的手工安装脚本 `deploy/install.sh` 写一次，`Program` 是
/// **安装那一刻** `command -v sing-box` 的结果 —— 也就是 homebrew 那份。于是：
/// 没跑过那个脚本的机器上这个作业根本不存在；跑过的机器上，就算 App 已经带了自己
/// 的引擎，root 这一侧跑的仍然是机器上那份、版本随 brew 漂。
///
/// 现在由特权助手每次启动引擎前按包内引擎的实际位置重写一遍 —— App 挪了位置、
/// 升了版本，下一次连接就跟上。
public enum PendingNetEngineDaemon {
    public static let label = "io.sbtally.singbox"
    public static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    public static let logPath = "/var/log/sbtally-singbox.log"

    /// 第一次用 TUN / 系统代理时把 root 引擎所需的配置目录铺出来。
    ///
    /// 只补缺的文件，不覆盖已经在用的配置：老用户可能有应用分流、规则集和多个
    /// VPS，拿一份空基线盖掉它们会直接断网。如果老安装只有 `master.json`，从它
    /// 派生两个接管变体；全新安装才从客户端自己的生成器创建基线。
    public static func prepareConfigDirectory(
        at directoryPath: String,
        preferredMode: String,
        fileManager: FileManager = .default,
        makeControlSecret: () -> String = {
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
    ) throws {
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let secretURL = directory.appendingPathComponent(PendingNetRootConfig.secretFilename)
        let secret: String
        if let existing = try? String(contentsOf: secretURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            secret = existing
        } else {
            secret = makeControlSecret()
            guard !secret.isEmpty else {
                throw PendingNetRuntimeConfigError.invalidLocalConfiguration
            }
            try writeIfMissing(Data((secret + "\n").utf8), to: secretURL, fileManager: fileManager)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretURL.path)

        let tunURL = directory.appendingPathComponent(PendingNetRootConfig.tunFilename)
        let noTunURL = directory.appendingPathComponent(PendingNetRootConfig.noTunFilename)
        let masterURL = directory.appendingPathComponent(PendingNetRootConfig.activeFilename)

        // 旧版生成的 `dns-local` 在 macOS TUN 下可能拿不到 DHCP / 系统 DNS，
        // 导致白名单中的国内域名全部解析超时。这里只迁移那一个精确的旧形状，
        // 不用新基线覆盖用户已有的 VPS、路由和规则集。
        for url in [masterURL, tunURL, noTunURL] where fileManager.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            let migrated = try PendingNetRootConfig.migratingLegacyLocalDNS(in: existing)
            if migrated != existing {
                try migrated.write(to: url, options: .atomic)
            }
        }

        let existingBase = [masterURL, tunURL, noTunURL].compactMap {
            try? Data(contentsOf: $0)
        }.first
        let cachePath = directory.appendingPathComponent(PendingNetRootConfig.cacheFilename).path

        let tun = try existingBase.map {
            try PendingNetRootConfig.variant(from: $0, enableTUN: true)
        } ?? PendingNetRootConfig.make(
            enableTUN: true, controlSecret: secret, cachePath: cachePath)
        let noTun = try existingBase.map {
            try PendingNetRootConfig.variant(from: $0, enableTUN: false)
        } ?? PendingNetRootConfig.make(
            enableTUN: false, controlSecret: secret, cachePath: cachePath)

        try writeIfMissing(tun, to: tunURL, fileManager: fileManager)
        try writeIfMissing(noTun, to: noTunURL, fileManager: fileManager)
        try writeIfMissing(preferredMode == "tun" ? tun : noTun,
                           to: masterURL, fileManager: fileManager)
        for url in [tunURL, noTunURL, masterURL] {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// 作业只负责提供 root 权限，不再自行决定“开机就连接”。真正的开机自启由
    /// App 的登录项控制：App 启动后读取上次连接开关，再显式 kickstart 这份作业。
    /// 否则一个留在 `/Library/LaunchDaemons` 的 plist 会绕过设置页，永久把机器
    /// 拉进上次的 TUN——这正是旧版的行为。
    public static func jobDefinition(
        enginePath: String,
        configPath: String,
        workingDirectory: String
    ) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [enginePath, "run", "-c", configPath],
            "WorkingDirectory": workingDirectory,
            "RunAtLoad": false,
            "KeepAlive": false,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
    }

    public static func plistData(
        enginePath: String,
        configPath: String,
        workingDirectory: String
    ) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: jobDefinition(
                enginePath: enginePath,
                configPath: configPath,
                workingDirectory: workingDirectory
            ),
            format: .xml,
            options: 0
        )
    }

    /// 盘上那份作业现在指着哪个引擎。读不出来就是 nil（文件不在、或者不是我们认识的形状）。
    public static func declaredEnginePath(plistData: Data) -> String? {
        guard let root = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil
        ) as? [String: Any],
            let arguments = root["ProgramArguments"] as? [String],
            let program = arguments.first, !program.isEmpty else { return nil }
        return program
    }

    private static func writeIfMissing(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try data.write(to: url, options: .atomic)
    }
}
