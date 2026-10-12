import SBTallyCore
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct PendingNodeSharePanel: View {
    let server: PairedVPSRecord
    @State private var links: [PendingNetSharedLink] = []
    @State private var pairingLink: String?
    @State private var busy = false
    @State private var shareTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("分享节点").font(PendingNetTheme.Fonts.bodyEmphasized)
            VStack(alignment: .leading, spacing: 8) {
                Button("标准节点链接") { shareTask = Task { await standardLinks() } }
                Button("PendingNet 配对链接") { shareTask = Task { await issuePairing() } }
            }
            .buttonStyle(PendingQuietButtonStyle())
            .disabled(busy)
            if busy { ProgressView().controlSize(.small) }
            if let error { Text(error).font(PendingNetTheme.Fonts.caption).foregroundStyle(PendingNetTheme.Palette.danger) }
            ForEach(links) { item in shareRow(item.label, link: item.link) }
            if let pairingLink {
                shareRow("PendingNet", link: pairingLink)
                Text("配对链接 10 分钟内有效，只能使用一次。")
                    .font(PendingNetTheme.Fonts.caption)
            }
            if !links.isEmpty || pairingLink != nil {
                Text("链接包含访问凭据，请只分享给信任的人。")
                    .font(PendingNetTheme.Fonts.caption).foregroundStyle(PendingNetTheme.Palette.inkMuted)
            }
        }
        .onDisappear { shareTask?.cancel(); links = []; pairingLink = nil }
    }

    private func shareRow(_ label: String, link: String) -> some View {
        HStack {
            Text(verbatim: label)
            Spacer()
            Button("复制") {
                #if os(iOS)
                UIPasteboard.general.string = link
                #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                #endif
            }
            ShareLink(item: link) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享")
        }
    }

    private func standardLinks() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            guard let token = try PendingNetCredentialStore.load(serverID: server.serverID) else {
                throw PendingNetPairingError.serverRejected(String(localized: "这台设备还没有这台 VPS 的访问凭据，请重新导入它的链接"))
            }
            let profile: PendingNetNodeProfile
            if server.isSharedNode {
                let decoded = try PendingNetSharedNode.decode(link: token)
                links = [.init(label: decoded.profile.protocols.first?.displayName ?? server.name, link: token)]
                return
            }
            else {
                profile = try await PendingNetServerClient(endpoint: server.endpoint,
                    certificateSHA256: server.certificateSHA256, accessToken: token).nodeProfile()
                guard profile.serverID == server.serverID else { throw PendingNetPairingError.invalidServerResponse }
            }
            guard !Task.isCancelled else { return }
            links = try PendingNetNodeShare.links(profile: profile, name: server.name)
        } catch { self.error = error.localizedDescription }
    }

    private func issuePairing() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            guard !server.isSharedNode,
                  let managed = PendingNetManagedServerStore().servers.first(where: {
                      $0.serverID == server.serverID && $0.endpoint == server.endpoint && $0.certificateSHA256 == server.certificateSHA256
                  }) else { throw PendingNetAdminAPIError.missingCredential }
            let grant = try await PendingNetAdminAPIClient(server: managed).issuePairing(role: .client, ttlSeconds: 600)
            guard !Task.isCancelled else { return }
            pairingLink = grant.link
        } catch { self.error = error.localizedDescription }
    }
}
