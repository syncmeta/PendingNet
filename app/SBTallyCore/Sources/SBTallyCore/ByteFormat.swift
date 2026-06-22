import Foundation

public func humanBytes(_ n: Int64) -> String {
    let unit: Int64 = 1024
    if n < unit { return "\(n) B" }
    var div = unit
    var exp = 0
    var x = n / unit
    while x >= unit { div *= unit; exp += 1; x /= unit }
    let units = ["K", "M", "G", "T", "P", "E"]
    return String(format: "%.1f %@iB", Double(n) / Double(div), units[exp])
}
