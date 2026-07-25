import Foundation

let ETC = "/usr/local/etc/sbtally"
let LABEL = "system/io.sbtally.singbox"

func sh(_ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, out)
}
func launchctl(_ sub: [String]) -> String? {
    let (code, out) = sh(["/bin/launchctl"] + sub)
    return code == 0 ? nil : out
}
func networkServices() -> [String] { // active-ish: all listed services minus '*'-disabled
    let (_, out) = sh(["/usr/sbin/networksetup", "-listallnetworkservices"])
    return out.split(separator: "\n").dropFirst().map(String.init).filter { !$0.hasPrefix("*") }
}
func setSystemProxy(_ on: Bool) {
    for s in networkServices() {
        if on {
            _ = sh(["/usr/sbin/networksetup", "-setwebproxy", s, "127.0.0.1", "2080"])
            _ = sh(["/usr/sbin/networksetup", "-setsecurewebproxy", s, "127.0.0.1", "2080"])
            _ = sh(["/usr/sbin/networksetup", "-setsocksfirewallproxy", s, "127.0.0.1", "2080"])
        } else {
            _ = sh(["/usr/sbin/networksetup", "-setwebproxystate", s, "off"])
            _ = sh(["/usr/sbin/networksetup", "-setsecurewebproxystate", s, "off"])
            _ = sh(["/usr/sbin/networksetup", "-setsocksfirewallproxystate", s, "off"])
        }
    }
}
func currentMode() -> String {
    (try? String(contentsOfFile: "\(ETC)/mode", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "tun"
}
func engineRunning() -> Bool {
    let (code, out) = sh(["/bin/launchctl", "print", LABEL])
    return code == 0 && out.contains("state = running")
}

final class Helper: NSObject, HelperProtocol, NSXPCListenerDelegate {
    func startEngine(reply: @escaping (String?) -> Void) {
        _ = launchctl(["bootout", LABEL])   // idempotent
        let err = launchctl(["bootstrap", "system", "/Library/LaunchDaemons/io.sbtally.singbox.plist"])
        if err == nil && currentMode() == "sysproxy" { setSystemProxy(true) }
        reply(err)
    }
    func stopEngine(reply: @escaping (String?) -> Void) {
        setSystemProxy(false)               // unconditional: never leave stale proxy
        reply(launchctl(["bootout", LABEL]))
    }
    func setTakeover(_ mode: String, reply: @escaping (String?) -> Void) {
        guard ["tun", "sysproxy", "local"].contains(mode) else { return reply("bad mode") }
        let variant = mode == "tun" ? "master-tun.json" : "master-notun.json"
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: "\(ETC)/\(variant)"))
            try data.write(to: URL(fileURLWithPath: "\(ETC)/master.json"))
            try mode.write(toFile: "\(ETC)/mode", atomically: true, encoding: .utf8)
        } catch { return reply("\(error)") }
        setSystemProxy(mode == "sysproxy")
        reply(launchctl(["kickstart", "-k", LABEL]))
    }
    func status(reply: @escaping (Bool, String, String) -> Void) {
        let (_, tail) = sh(["/usr/bin/tail", "-n", "5", "/var/log/sbtally-singbox.log"])
        reply(engineRunning(), currentMode(), tail)
    }
    func listener(_ l: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        c.exportedObject = self
        c.resume()
        return true
    }
}

let delegate = Helper()
let listener = NSXPCListener(machServiceName: "net.pending.PendingNet.helper")
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
