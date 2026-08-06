import Foundation
import SBTallyCore
import UIKit

struct IOSPairedServer: Codable, Equatable {
    var serverID: String
    var name: String
    var endpoint: String
    var certificateSHA256: String
    var deviceID: String
    var capabilities: [String]
}

@MainActor
final class PendingNetIOSController: ObservableObject {
    @Published private(set) var server: IOSPairedServer?
    @Published private(set) var nodeProfile: PendingNetNodeProfile?
    @Published private(set) var working = false
    @Published var message: String?
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let defaultsKey = "pendingnet.ios.paired-server.v1"

    init() {
        guard let data = defaults.data(forKey: defaultsKey) else { return }
        server = try? JSONDecoder().decode(IOSPairedServer.self, from: data)
    }

    func importAndEnroll(url: URL) async {
        working = true
        message = nil
        errorMessage = nil
        defer { working = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let pairing = try PendingNetPairingFile.decode(Data(contentsOf: url))
            let result = try await PendingNetEnrollmentClient().enroll(
                pairing: pairing,
                deviceName: UIDevice.current.name
            )
            try PendingNetCredentialStore.save(
                accessToken: result.accessToken,
                serverID: result.server.serverID
            )
            let paired = IOSPairedServer(
                serverID: result.server.serverID,
                name: result.server.name,
                endpoint: pairing.control.endpoint,
                certificateSHA256: pairing.control.certificateSHA256,
                deviceID: result.deviceID,
                capabilities: result.server.capabilities
            )
            server = paired
            if let data = try? JSONEncoder().encode(paired) {
                defaults.set(data, forKey: defaultsKey)
            }
            message = "已配对：\(paired.name)"
            await refreshNodeProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshNodeProfile() async {
        guard let server else { return }
        do {
            guard let token = try PendingNetCredentialStore.load(serverID: server.serverID) else {
                throw PendingNetPairingError.serverRejected("此设备没有找到 VPS 访问凭据，请重新配对")
            }
            let profile = try await PendingNetServerClient(
                endpoint: server.endpoint,
                certificateSHA256: server.certificateSHA256,
                accessToken: token
            ).nodeProfile()
            guard profile.serverID == server.serverID else {
                throw PendingNetPairingError.invalidServerResponse
            }
            nodeProfile = profile
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
