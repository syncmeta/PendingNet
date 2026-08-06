import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(PendingNetTunnelError.proxyCoreNotInstalled)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

private enum PendingNetTunnelError: LocalizedError {
    case proxyCoreNotInstalled

    var errorDescription: String? {
        "PendingNet Packet Tunnel 已安装，但代理内核尚未接入。"
    }
}

