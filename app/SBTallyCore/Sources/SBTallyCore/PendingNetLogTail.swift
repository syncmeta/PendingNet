import Foundation

/// 有界读取诊断日志的末尾。root 引擎日志历史上曾长到 160 MB，日志页不能整份加载。
public enum PendingNetLogTail {
    public static let defaultMaximumBytes = 512 * 1024

    public static func read(
        path: String,
        maximumBytes: Int = defaultMaximumBytes,
        fileManager: FileManager = .default
    ) throws -> String {
        guard maximumBytes > 0 else { return "" }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let limit = UInt64(maximumBytes)
        let offset = size > limit ? size - limit : 0

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var data = try handle.readToEnd() ?? Data()

        // 从文件中间切入时第一行通常不完整；扔掉它，避免页首出现半条 UTF-8 或
        // 半段时间戳。如果整段没有换行，就保留尾巴本身，至少仍有诊断价值。
        if offset > 0, let newline = data.firstIndex(of: 0x0a) {
            data = Data(data[data.index(after: newline)...])
        }
        let decoded = String(decoding: data, as: UTF8.self)
        // sing-box 在文件里也可能留下终端 ANSI 颜色码；GUI 只该显示正文。
        return decoded.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
    }
}
