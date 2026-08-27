import Foundation

/// 把本地 Clash 控制口的底层错误翻成用户能处理的一句话。
///
/// `NSError.description` 会连同 URLSession task、底层 CFNetwork 字典和完整 URL
/// 一起展开；那份内容适合日志，不适合占满界面的 Toast。
public enum PendingNetControlFailureMessage {
    public static func text(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return "代理控制失败，请重新连接后再试。"
        }

        switch URLError.Code(rawValue: nsError.code) {
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .timedOut:
            return "代理引擎没有响应，请先打开连接；若已经连接，请重新连接后再试。"
        case .userAuthenticationRequired:
            return "找不到代理控制凭据，请重新连接后再试。"
        case .cannotParseResponse, .badServerResponse:
            return "代理引擎返回了无法识别的状态，请重新连接后再试。"
        default:
            return "代理控制失败，请重新连接后再试。"
        }
    }
}
