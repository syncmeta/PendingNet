import Foundation

public struct PendingNetSharedLink: Identifiable, Sendable {
    public var id: String { label }
    public let label: String
    public let link: String
    public init(label: String, link: String) { self.label = label; self.link = link }
}

public enum PendingNetNodeShare {
    public static func links(profile: PendingNetNodeProfile, name: String) throws -> [PendingNetSharedLink] {
        try profile.protocols.map { item in
            var url = URLComponents()
            var query: [URLQueryItem] = []
            if let vless = item.vlessReality {
                url.scheme = "vless"
                url.user = vless.uuid
                url.host = vless.server.contains(":") && !vless.server.hasPrefix("[") ? "[\(vless.server)]" : vless.server
                url.port = vless.serverPort
                query = [
                    .init(name: "security", value: "reality"), .init(name: "encryption", value: "none"),
                    .init(name: "type", value: "tcp"), .init(name: "flow", value: vless.flow),
                    .init(name: "sni", value: vless.serverName), .init(name: "pbk", value: vless.publicKey),
                    .init(name: "sid", value: vless.shortID), .init(name: "fp", value: "chrome")
                ]
            } else if let hy = item.hysteria2 {
                url.scheme = "hysteria2"
                // A colon belongs to the password, not URLComponents.password.
                var allowed = CharacterSet.urlUserAllowed
                allowed.remove(charactersIn: ":@/?#%")
                url.percentEncodedUser = hy.password.addingPercentEncoding(withAllowedCharacters: allowed)
                url.host = hy.server.contains(":") && !hy.server.hasPrefix("[") ? "[\(hy.server)]" : hy.server
                url.port = hy.serverPort
                query = [.init(name: "sni", value: hy.serverName)]
                if !hy.obfsType.isEmpty { query.append(.init(name: "obfs", value: hy.obfsType)) }
                if !hy.obfsPassword.isEmpty { query.append(.init(name: "obfs-password", value: hy.obfsPassword)) }
                if !hy.certificatePublicKeySHA256.isEmpty {
                    guard let fingerprint = hy.certificateSHA256, fingerprint.count == 64 else {
                        throw PendingNetPairingError.serverRejected(NSLocalizedString("服务器尚未提供 Hysteria2 证书指纹，请升级服务端后重试", comment: "Share needs certificate fingerprint"))
                    }
                    query.append(.init(name: "pinSHA256", value: fingerprint))
                    query.append(.init(name: "insecure", value: "1"))
                    // Standard clients use the certificate fingerprint. PendingNet
                    // also retains the SPKI pin used by its embedded sing-box.
                    query.append(.init(name: "pendingnet-spki", value: hy.certificatePublicKeySHA256))
                }
            } else { throw PendingNetPairingError.invalidServerResponse }
            url.queryItems = query
            url.fragment = name
            guard let link = url.string else { throw PendingNetPairingError.invalidServerResponse }
            return PendingNetSharedLink(label: item.displayName, link: link)
        }
    }
}
