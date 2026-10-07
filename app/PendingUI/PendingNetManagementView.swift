import SBTallyCore
import SwiftUI
import UniformTypeIdentifiers

/// Secret-bearing export data stays in memory until the system file exporter
/// writes to a destination explicitly chosen by the user.
private struct PendingNetClientConfigDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// One-time in-memory handoff from URL opening to the management form. The
/// link is never written to navigation state, defaults, or the VPS store.
@MainActor
final class PendingNetManagementLinkInbox: ObservableObject {
    @Published private(set) var pendingLink: String?

    func offer(_ link: String) { pendingLink = link }

    func take() -> String? {
        defer { pendingLink = nil }
        return pendingLink
    }
}

@MainActor
final class PendingNetManagementController: ObservableObject {
    @Published private(set) var servers: [PendingNetManagedServer]
    @Published private(set) var users: [PendingNetAdminUser] = []
    @Published private(set) var configRevision: String?
    @Published private(set) var issuedLink: String?
    @Published var selectedServerID: String?
    @Published var errorMessage: String?
    @Published var message: String?
    @Published private(set) var working = false
    @Published private(set) var enrollmentInFlight = false

    private let store: PendingNetManagedServerStore

    init(store: PendingNetManagedServerStore = PendingNetManagedServerStore()) {
        self.store = store
        servers = store.servers
        selectedServerID = store.servers.first?.serverID
    }

    func importLink(_ link: String) async -> Bool {
        guard !working, !enrollmentInFlight else { return false }
        let generation = refreshGeneration
        enrollmentInFlight = true
        working = true
        errorMessage = nil
        message = nil
        defer {
            enrollmentInFlight = false
            if refreshGeneration == generation { working = false }
        }
        do {
            try store.ensureWritable()
            let server = try await PendingNetAdminEnrollmentClient().enroll(
                link: link,
                deviceName: ProcessInfo.processInfo.hostName
            )
            try store.upsert(server)
            servers = store.servers
            guard refreshGeneration == generation else { return false }
            selectedServerID = server.serverID
            users = []
            configRevision = nil
            issuedLink = nil
            message = String(localized: "管理链接已导入")
            return true
        } catch {
            if refreshGeneration == generation { errorMessage = error.localizedDescription }
            return false
        }
    }

    func refresh() async {
        guard let server = servers.first(where: { $0.serverID == selectedServerID }) else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        working = true
        errorMessage = nil
        users = []
        configRevision = nil
        issuedLink = nil
        defer { if refreshGeneration == generation { working = false } }
        let client = PendingNetAdminAPIClient(server: server)
        do {
            let fetchedUsers = try await client.users()
            guard refreshGeneration == generation, selectedServerID == server.serverID else { return }
            users = fetchedUsers
            // The three documents may contain proxy secrets. Only the opaque
            // revision is retained for display; the snapshot is discarded.
            let revision = try await client.config().revision
            guard refreshGeneration == generation, selectedServerID == server.serverID else { return }
            configRevision = revision
        } catch {
            if refreshGeneration == generation, selectedServerID == server.serverID {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var refreshGeneration = 0

    func selectServer(_ id: String?) {
        guard selectedServerID != id else { return }
        clearTransientLink()
        selectedServerID = id
    }

    func clearTransientLink() {
        refreshGeneration += 1
        issuedLink = nil
        users = []
        configRevision = nil
        errorMessage = nil
        message = nil
        working = false
    }

    func issuePairing(role: PendingNetAdminPairingRole) async {
        guard !working, let server = servers.first(where: { $0.serverID == selectedServerID }) else { return }
        let generation = refreshGeneration
        working = true
        issuedLink = nil
        errorMessage = nil
        message = nil
        defer { if refreshGeneration == generation { working = false } }
        do {
            let issued = try await PendingNetAdminAPIClient(server: server)
                .issuePairing(role: role, ttlSeconds: 600)
            guard refreshGeneration == generation, selectedServerID == server.serverID else { return }
            issuedLink = issued.link
            message = String(localized: "链接已签发，请及时复制；离开此页后不会保存")
        } catch {
            if refreshGeneration == generation, selectedServerID == server.serverID {
                errorMessage = error.localizedDescription
            }
        }
    }

    func revokeUser(id: String) async {
        guard !working, let server = servers.first(where: { $0.serverID == selectedServerID }) else { return }
        let generation = refreshGeneration
        working = true
        issuedLink = nil
        errorMessage = nil
        message = nil
        defer { if refreshGeneration == generation { working = false } }
        do {
            let client = PendingNetAdminAPIClient(server: server)
            try await client.revokeUser(id: id)
            let latest = try await client.users()
            guard refreshGeneration == generation, selectedServerID == server.serverID else { return }
            users = latest
            message = String(localized: "用户已撤销")
        } catch {
            if refreshGeneration == generation, selectedServerID == server.serverID {
                errorMessage = error.localizedDescription
            }
        }
    }

    func clientConfig(platform: PendingNetClientConfigPlatform) async -> Data? {
        guard !working, let server = servers.first(where: { $0.serverID == selectedServerID }) else { return nil }
        let generation = refreshGeneration
        working = true
        issuedLink = nil
        errorMessage = nil
        message = nil
        defer { if refreshGeneration == generation { working = false } }
        do {
            let data = try await PendingNetAdminAPIClient(server: server).clientConfig(platform: platform)
            guard refreshGeneration == generation, selectedServerID == server.serverID else { return nil }
            return data
        } catch {
            if refreshGeneration == generation, selectedServerID == server.serverID {
                errorMessage = error.localizedDescription
            }
            return nil
        }
    }

    func exportFinished(_ result: Result<URL, Error>) {
        switch result {
        case .success: message = String(localized: "配置文件已保存")
        case .failure(let error): errorMessage = error.localizedDescription
        }
    }
}

/// Management is intentionally a distinct tab from the proxy connection
/// picker. Importing here never selects a VPS or changes the tunnel.
struct PendingNetManagementView: View {
    @EnvironmentObject private var linkInbox: PendingNetManagementLinkInbox
    @StateObject private var controller = PendingNetManagementController()
    @State private var link = ""
    @State private var revokeUserID: String?
    @State private var revokeServerID: String?
    @State private var confirmAdminIssue = false
    @State private var adminIssueServerID: String?
    @State private var exportDocument: PendingNetClientConfigDocument?
    @State private var exportFilename = ""
    @State private var showExporter = false
    @State private var exportServerID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("管理")
                    .font(PendingNetTheme.Fonts.sectionTitle("管理"))

                VStack(alignment: .leading, spacing: 10) {
                    Text("导入管理链接")
                        .font(.headline)
                    SecureField("粘贴 pendingnet:// 管理链接", text: $link)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Button("导入") {
                        let pasted = link
                        link = ""
                        Task {
                            if await controller.importLink(pasted) { await controller.refresh() }
                        }
                    }
                    .disabled(controller.working || controller.enrollmentInFlight || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !controller.servers.isEmpty {
                    Picker("服务器", selection: Binding(
                        get: { controller.selectedServerID },
                        set: { id in
                            controller.selectServer(id)
                            showExporter = false
                            exportDocument = nil
                            exportServerID = nil
                            revokeUserID = nil
                            revokeServerID = nil
                            confirmAdminIssue = false
                            adminIssueServerID = nil
                        }
                    )) {
                        ForEach(controller.servers) { server in
                            Text(server.name).tag(Optional(server.serverID))
                        }
                    }
                    Button("刷新") { Task { await controller.refresh() } }
                        .disabled(controller.working)

                    HStack {
                        Button("签发普通链接") {
                            Task { await controller.issuePairing(role: .client) }
                        }
                        Button("签发管理链接") {
                            adminIssueServerID = controller.selectedServerID
                            confirmAdminIssue = true
                        }
                    }
                    .disabled(controller.working)

                    HStack {
                        Button("导出 Android 配置") { exportConfig(.android) }
                        Button("导出 Windows 配置") { exportConfig(.windows) }
                    }
                    .disabled(controller.working)
                    Text("导出的文件包含连接凭据，请妥善保管。")
                        .font(.caption)
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)

                    if let issued = controller.issuedLink {
                        Text("一次性链接（十分钟内有效，仅在此页临时显示）")
                            .font(.caption)
                        Text(issued)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }

                    if let revision = controller.configRevision {
                        Text(String(format: NSLocalizedString("配置版本：%@", comment: ""), String(revision.prefix(12))))
                            .font(.caption.monospaced())
                            .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    }
                    Text("服务端配置目前只读；在线修改尚未开放。")
                        .font(.caption)
                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                    if !controller.users.isEmpty {
                        Text("用户")
                            .font(.headline)
                        ForEach(controller.users) { user in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(user.name)
                                Text(user.revokedAt == nil ? LocalizedStringKey("有效") : LocalizedStringKey("已撤销"))
                                    .font(.caption)
                                    .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                                if user.revokedAt == nil {
                                    Button("撤销用户") {
                                        revokeServerID = controller.selectedServerID
                                        revokeUserID = user.id
                                    }
                                        .disabled(controller.working)
                                }
                                ForEach(user.loginIPs ?? [], id: \.ip) { login in
                                    Text(String(format: NSLocalizedString("%@ · 首次登录 %@", comment: ""), login.ip, login.firstSeenAt))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(PendingNetTheme.Palette.inkMuted)
                                }
                            }
                        }
                    }
                }

                if let message = controller.message {
                    Text(message).foregroundStyle(PendingNetTheme.Palette.success)
                }
                if let error = controller.errorMessage {
                    Text(error).foregroundStyle(PendingNetTheme.Palette.danger)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(PendingNetTheme.Metrics.gutter)
        }
        .background(PendingNetTheme.Palette.canvas.ignoresSafeArea())
        .task(id: controller.selectedServerID) { await controller.refresh() }
        .onAppear { acceptOpenedLink() }
        .onDisappear {
            link = ""
            controller.clearTransientLink()
            showExporter = false
            exportDocument = nil
            exportServerID = nil
            revokeUserID = nil
            revokeServerID = nil
            confirmAdminIssue = false
            adminIssueServerID = nil
        }
        .onChange(of: linkInbox.pendingLink) { _, _ in acceptOpenedLink() }
        .alert("撤销此用户？", isPresented: Binding(
            get: { revokeUserID != nil },
            set: {
                if !$0 {
                    revokeUserID = nil
                    revokeServerID = nil
                }
            }
        )) {
            Button("撤销用户", role: .destructive) {
                if let id = revokeUserID,
                   let serverID = revokeServerID,
                   controller.selectedServerID == serverID {
                    Task {
                        guard controller.selectedServerID == serverID else { return }
                        await controller.revokeUser(id: id)
                    }
                }
                revokeUserID = nil
                revokeServerID = nil
            }
            Button("取消", role: .cancel) {
                revokeUserID = nil
                revokeServerID = nil
            }
        }
        .alert("签发管理链接？", isPresented: $confirmAdminIssue) {
            Button("签发管理链接") {
                if let serverID = adminIssueServerID, controller.selectedServerID == serverID {
                    Task {
                        guard controller.selectedServerID == serverID else { return }
                        await controller.issuePairing(role: .admin)
                    }
                }
                adminIssueServerID = nil
            }
            Button("取消", role: .cancel) { adminIssueServerID = nil }
        } message: {
            Text("持有此链接的人可以取得完整管理权限。请仅交给信任的人。")
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            let matchesCurrentServer = exportServerID != nil && exportServerID == controller.selectedServerID
            exportDocument = nil
            exportServerID = nil
            if matchesCurrentServer {
                controller.exportFinished(result)
            }
        }
    }

    private func acceptOpenedLink() {
        if let incoming = linkInbox.take() { link = incoming }
    }

    private func exportConfig(_ platform: PendingNetClientConfigPlatform) {
        guard let serverID = controller.selectedServerID else { return }
        Task {
            guard let data = await controller.clientConfig(platform: platform) else { return }
            guard controller.selectedServerID == serverID else { return }
            exportFilename = platform == .android ? "pendingnet-android" : "pendingnet-windows"
            exportServerID = serverID
            exportDocument = PendingNetClientConfigDocument(data: data)
            showExporter = true
        }
    }
}
