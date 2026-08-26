import Foundation

/// 代理引擎（sing-box）在哪。
///
/// 引擎现在从源码编进 app bundle 的 `Contents/MacOS`，跟着 App 一起签名、一起
/// 更新。在这之前它只可能来自机器上自己装的那份（homebrew / `/usr/local`）——
/// 于是任何一台没 `brew install sing-box` 的新电脑，装完 App 一连接就报「找不到
/// sing-box」，而界面上没有任何地方能补救。那两条路径保留成退路，但不再是主路。
///
/// App 侧、特权助手侧用的是**同一份**判断：两边各写一遍，迟早会出现「app 用包内
/// 那份、助手用 homebrew 那份」这种两个引擎版本不一致的现场。
public enum PendingNetEngineBinary {
    public static let executableName = "sing-box"

    /// 机器上自己装的那份。只当退路 —— 开发机上手边有什么就用什么，仍然管用。
    public static let fallbackPaths = [
        "/opt/homebrew/bin/sing-box",
        "/usr/local/bin/sing-box",
    ]

    /// 包里没有引擎时对用户说什么。
    ///
    /// 从前这句是「请先安装 sing-box」——内置之后它就是彻头彻尾的误导：用户装
    /// 一个 sing-box 也修不好，因为真出这个错只可能是包本身不完整。
    public static let missingEngineMessage =
        "这个 PendingNet 安装包里没有代理引擎，包不完整。请从 Releases 重新下载安装一次。"

    /// 自己这个可执行文件的邻居目录。App 和特权助手都住在
    /// `PendingNet.app/Contents/MacOS`，引擎就在旁边。
    ///
    /// argv[0] 也算一条：助手是 launchd 按 `BundleProgram` 拉起的，`Bundle.main`
    /// 对一个不在 bundle 结构里的可执行文件可能什么都给不出来，那时 argv[0] 仍然
    /// 是绝对路径。（和 StatsCollector 找 sbtally 的写法同一套。）
    public static func siblingDirectories(
        bundleExecutable: URL?,
        argv0: String?
    ) -> [URL] {
        var directories: [URL] = []
        for candidate in [
            bundleExecutable?.deletingLastPathComponent(),
            argv0.map { URL(fileURLWithPath: $0).deletingLastPathComponent() },
        ] {
            guard let candidate else { continue }
            let path = candidate.standardizedFileURL.path
            guard !directories.contains(where: { $0.standardizedFileURL.path == path }) else {
                continue
            }
            directories.append(candidate)
        }
        return directories
    }

    /// 候选路径，按优先级：包内那份在前，机器上自己装的在后。
    public static func candidatePaths(siblingDirectories: [URL]) -> [String] {
        siblingDirectories.map {
            $0.appendingPathComponent(executableName).path
        } + fallbackPaths
    }

    /// 纯函数版，给测试用：`isExecutable` 由调用方决定。
    public static func locate(
        siblingDirectories: [URL],
        isExecutable: (String) -> Bool
    ) -> String? {
        candidatePaths(siblingDirectories: siblingDirectories).first(where: isExecutable)
    }

    /// 现场版：本进程的邻居目录 + 退路。
    public static func locate(fileManager: FileManager = .default) -> URL? {
        let directories = siblingDirectories(
            bundleExecutable: Bundle.main.executableURL,
            argv0: CommandLine.arguments.first
        )
        guard let path = locate(
            siblingDirectories: directories,
            isExecutable: { fileManager.isExecutableFile(atPath: $0) }
        ) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
