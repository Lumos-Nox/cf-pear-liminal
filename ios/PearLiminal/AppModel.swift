import Foundation
import Observation
import OSLog
import LocalAuthentication
#if canImport(UIKit)
import UIKit
#endif

private enum AppLogger {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pearliminal.ios",
        category: "AppModel"
    )
}

enum RegistryKind: String, CaseIterable, Identifiable {
    case capabilities
    case guide
    case policy
    case client

    var id: String { rawValue }
    var title: String {
        switch self {
        case .capabilities: return "Capabilities"
        case .guide: return "Guide"
        case .policy: return "Policy"
        case .client: return "Client source"
        }
    }
}

struct ChatMessage: Codable, Identifiable {
    let id: String
    let from: String
    let text: String
    let timestamp: Int64
    let type: String
    // Preserve the queued row's identity when its server receipt arrives.
    let clientID: String?

    var presentationID: String { clientID ?? id }

    init(id: String, from: String, text: String, timestamp: Int64, type: String, clientID: String? = nil) {
        self.id = id
        self.from = from
        self.text = text
        self.timestamp = timestamp
        self.type = type
        self.clientID = clientID
    }
}

@Observable @MainActor
final class AppModel {
    private(set) var mailbox: SelfMailbox?
    private(set) var peers: [Peer] = []
    private(set) var history = MailboxHistory()
    private(set) var selectedPeerID: String?
    private(set) var isWorking = false
    private(set) var isRestoring = false
    private(set) var isCopyingMailboxToken = false
    private(set) var isRefreshingPeers = false
    private(set) var errorMessage: String?
    private(set) var mailboxConnectionWarning: String?
    private(set) var statusMessage: String?
    private(set) var isAdminUnlocked = false
    private(set) var adminAgents: [Peer] = []
    private(set) var selectedAdminAgent: AdminAgent?
    private(set) var adminInspectionError: String?
    private(set) var isLoadingRegistries = false
    private(set) var registryTexts: [RegistryKind: String] = [:]
    private(set) var registryStatus: String?
    private(set) var registryError: String?
    private(set) var apiBaseURLText: String
    private(set) var sendingIDs = Set<String>()
    // Queued is distinct from unconfirmed: a new note has not failed just
    // because its asynchronous delivery task has not started yet.
    private(set) var unconfirmedIDs = Set<String>()

    var conversations: [String: [ChatMessage]] { history.conversations }
    var canCopyMailboxToken: Bool { mailbox != nil && mailboxToken != nil }

    @ObservationIgnored private var api: APIClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: MailboxStore
    @ObservationIgnored private let credentials: any MailboxCredentials
    @ObservationIgnored private var mailboxToken: String?
    @ObservationIgnored private var recoveryToken: String?
    @ObservationIgnored private var adminSecret: String?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var inboxPollID: UUID?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var adminID = UUID()
    @ObservationIgnored private var inspectionID = UUID()
    @ObservationIgnored private var workID: UUID?
    @ObservationIgnored private var workIsAdmin = false
    @ObservationIgnored private var handledMessageIDs = Set<String>()
    @ObservationIgnored private var appIsActive = true
    @ObservationIgnored private var appIsBackgrounded = false
    @ObservationIgnored private var tokenCopyAttemptID = UUID()
    @ObservationIgnored private var pendingTokenCopySession: UUID?
    @ObservationIgnored private let authenticateTokenCopy: @MainActor () async throws -> Bool
    @ObservationIgnored private let writeTokenToClipboard: @MainActor (String) -> Bool
    @ObservationIgnored private var consecutivePollFailures = 0

    init(api: APIClient? = nil, defaults: UserDefaults = .standard, store: MailboxStore = MailboxStore(), credentials: (any MailboxCredentials)? = nil,
         authenticateTokenCopy: (@MainActor () async throws -> Bool)? = nil,
         writeTokenToClipboard: (@MainActor (String) -> Bool)? = nil) {
        self.authenticateTokenCopy = authenticateTokenCopy ?? {
            try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Authenticate to copy your mailbox bearer token.")
        }
        self.writeTokenToClipboard = writeTokenToClipboard ?? { token in
            #if canImport(UIKit)
            UIPasteboard.general.setItems(
                [[UIPasteboard.typeAutomatic: token]],
                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
            )
            return true
            #else
            return false
            #endif
        }
        self.credentials = credentials ?? KeychainStore(defaults: defaults)
        self.defaults = defaults
        self.store = store
        let saved = defaults.string(forKey: "apiBaseURL") ?? APIClient.productionURL.absoluteString
        let url = api?.baseURL ?? APIClient.validatedBaseURL(saved) ?? APIClient.productionURL
        self.api = api ?? APIClient(baseURL: url)
        apiBaseURLText = url.absoluteString
    }

    private func beginWork(admin: Bool = false) -> UUID? {
        guard !isWorking else { return nil }
        let id = UUID()
        workID = id
        workIsAdmin = admin
        isWorking = true
        errorMessage = nil
        return id
    }

    private func finishWork(_ id: UUID) {
        guard workID == id else { return }
        workID = nil
        workIsAdmin = false
        isWorking = false
    }

    func restoreSession() async {
        guard mailbox == nil, !isRestoring, !isWorking, let token = recoveryToken ?? credentials.read(server: api.baseURL) else { return }
        isRestoring = true
        let session = sessionID
        defer { if sessionID == session { isRestoring = false } }
        do {
            let current: SelfMailbox = try await api.get("/v1/agent/self", token: token)
            guard sessionID == session, !Task.isCancelled else { return }
            try credentials.write(token, server: api.baseURL)
            recoveryToken = nil
            await activate(current, token: token)
        } catch {
            guard sessionID == session, !isCancellation(error) else { return }
            mailboxConnectionWarning = recoveryToken == nil
                ? "Could not reconnect. Your saved token is safe; check the server and try again."
                : "The new mailbox token has not been saved. Keep this app open and retry."
            errorMessage = error.localizedDescription
        }
    }

    func createMailbox(label: String, joinSecret: String) async {
        guard !isRestoring, mailbox == nil else { return }
        guard recoveryToken == nil else { errorMessage = "Retry the mailbox already created before creating another."; return }
        guard !joinSecret.isEmpty else { errorMessage = "Enter the join secret."; return }
        guard let work = beginWork() else { return }
        let session = sessionID
        defer { finishWork(work) }
        do {
            let response: JoinResponse = try await api.post("/v1/agent/join", body: JoinRequest(label: label.trimmingCharacters(in: .whitespacesAndNewlines), joinSecret: joinSecret))
            guard sessionID == session else { return }
            // Save the token before any further network call, so a failed identity lookup is recoverable.
            recoveryToken = response.token
            try credentials.write(response.token, server: api.baseURL)
            recoveryToken = nil
            let current: SelfMailbox = try await api.get("/v1/agent/self", token: response.token)
            guard sessionID == session else { return }
            await activate(current, token: response.token)
            guard sessionID == session, mailbox != nil else { return }
            statusMessage = "Mailbox created and saved securely on this iPhone."
        } catch {
            guard sessionID == session, !isCancellation(error) else { return }
            mailboxConnectionWarning = recoveryToken == nil
                ? "If the mailbox was created, use Retry saved mailbox to reconnect."
                : "Mailbox created, but its token could not be saved. Keep this app open and use Retry saved mailbox."
            errorMessage = error.localizedDescription
        }
    }

    func reconnect(token: String) async {
        guard !isRestoring, mailbox == nil else { return }
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { errorMessage = "Enter the mailbox token."; return }
        guard let work = beginWork() else { return }
        let session = sessionID
        defer { finishWork(work) }
        do {
            let current: SelfMailbox = try await api.get("/v1/agent/self", token: cleaned)
            guard sessionID == session else { return }
            try credentials.write(cleaned, server: api.baseURL)
            recoveryToken = nil
            await activate(current, token: cleaned)
        } catch {
            guard sessionID == session, !isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func activate(_ current: SelfMailbox, token: String) async {
        let session = sessionID
        let server = api.baseURL
        // A rapid sign-out/reconnect must see the previous session's final queued save.
        await saveTask?.value
        guard sessionID == session else { return }
        var saved = MailboxHistory()
        do {
            saved = try await store.load(server: server, mid: current.mid) ?? MailboxHistory()
        } catch {
            guard sessionID == session else { return }
            // Keep the unreadable file intact: do not silently overwrite it with an empty history.
            errorMessage = "Could not open local message history. Unlock your iPhone and retry."
            mailboxConnectionWarning = "Local history could not be opened. The original file has been preserved."
            return
        }
        guard sessionID == session else { return }
        // Migrate the previous outgoing-only cache once, only for its original server.
        let legacyKey = "sentMessages.\(current.mid)"
        if server == APIClient.productionURL, let data = defaults.data(forKey: legacyKey),
           let legacy = try? JSONDecoder().decode([String: [ChatMessage]].self, from: data) {
            for (peer, messages) in legacy {
                let ids = Set((saved.conversations[peer] ?? []).map(\.id))
                let migrated = messages.filter { $0.from == current.mid }.map {
                    ChatMessage(id: "sent-\(peer)-\($0.id)", from: $0.from, text: $0.text, timestamp: $0.timestamp, type: $0.type)
                }
                saved.conversations[peer, default: []].append(contentsOf: migrated.filter { !ids.contains($0.id) })
                saved.conversations[peer]?.sort { $0.timestamp < $1.timestamp }
                saved.conversations[peer] = Array((saved.conversations[peer] ?? []).suffix(500))
            }
            do {
                try await store.save(saved, server: server, mid: current.mid)
                defaults.removeObject(forKey: legacyKey)
            } catch { errorMessage = "Could not migrate local history; the original copy has been kept." }
        }
        guard sessionID == session else { return }
        history = saved
        unconfirmedIDs = Set(saved.pending.map(\.id))
        handledMessageIDs = Set(saved.conversations.values.flatMap { $0.map(\.id) })
        mailboxToken = token
        mailbox = current
        statusMessage = current.label.isEmpty ? "Mailbox connected." : "Connected as \(current.label)."
        mailboxConnectionWarning = nil
        startPolling()
        await refreshPeers()
    }

    func refreshPeers() async {
        guard let token = mailboxToken, !isRefreshingPeers else { return }
        let session = sessionID
        let client = api
        isRefreshingPeers = true
        defer { if sessionID == session { isRefreshingPeers = false } }
        do {
            var all: [Peer] = []
            var cursor: String?
            var seen = Set<String>()
            repeat {
                try Task.checkCancellation()
                var path = "/v1/agent/peers?limit=100"
                if let cursor {
                    guard seen.insert(cursor).inserted else { throw APIError(statusCode: nil, message: "The directory returned a repeated page cursor.") }
                    path += "&cursor=\(cursor.queryEncoded)"
                }
                let page: PeerPage = try await client.get(path, token: token)
                guard sessionID == session else { return }
                all.append(contentsOf: page.peers)
                cursor = page.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
            } while cursor != nil
            var mids = Set<String>()
            peers = all.filter { $0.mid != mailbox?.mid && mids.insert($0.mid).inserted }
        } catch {
            guard sessionID == session, !isCancellation(error) else { return }
            mailboxConnectionWarning = "Directory refresh failed. Pull down to retry."
        }
    }

    func canDeleteConversation(_ peerID: String) -> Bool {
        mailbox != nil && !history.pending.contains { $0.peerID == peerID && sendingIDs.contains($0.id) }
    }

    func deleteConversation(_ peerID: String) {
        guard canDeleteConversation(peerID) else { return }
        history.conversations[peerID] = nil
        history.drafts[peerID] = nil
        history.unread[peerID] = nil
        unconfirmedIDs.subtract(history.pending.filter { $0.peerID == peerID }.map(\.id))
        history.pending.removeAll { $0.peerID == peerID }
        if selectedPeerID == peerID { selectedPeerID = nil }
        // Keep the inbox cursor and deduplication IDs: a refresh must not replay
        // the deleted notes. Keep thread/sequence metadata so an active agent
        // can still accept the next note after its visible history is cleared.
        if api.baseURL == APIClient.productionURL, let mid = mailbox?.mid {
            let legacyKey = "sentMessages.\(mid)"
            if let data = defaults.data(forKey: legacyKey),
               var legacy = try? JSONDecoder().decode([String: [ChatMessage]].self, from: data) {
                legacy[peerID] = nil
                if let updated = try? JSONEncoder().encode(legacy) { defaults.set(updated, forKey: legacyKey) }
            }
        }
        persistHistory()
    }

    func enterConversation(_ peerID: String) {
        guard mailbox != nil else { return }
        selectedPeerID = peerID
        history.unread[peerID] = 0
        persistHistory()
        startPolling()
    }

    func leaveConversation(_ peerID: String) {
        guard selectedPeerID == peerID else { return }
        selectedPeerID = nil
    }

    func draft(for peerID: String) -> String { history.drafts[peerID] ?? "" }
    func updateDraft(_ text: String, for peerID: String) {
        guard mailbox != nil else { return }
        history.drafts[peerID] = text.isEmpty ? nil : text
        persistHistory(debounce: true)
    }

    func pendingMessages(for peerID: String) -> [PendingMessage] { history.pending.filter { $0.peerID == peerID } }

    @discardableResult
    func sendMessage(_ text: String, to peerID: String) async -> Bool {
        guard let pending = queueMessage(text, to: peerID) else { return false }
        return await deliver(pending)
    }

    func queueMessage(_ text: String, to peerID: String) -> PendingMessage? {
        guard mailbox != nil, mailboxToken != nil else { return nil }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let thread = history.threads[peerID] ?? String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let payload = SendPayload(text: text, thread: thread, seq: history.sequences[peerID] ?? (conversations[peerID] ?? []).filter { $0.from == mailbox?.mid }.count)
        guard let data = try? JSONEncoder().encode(payload), data.count <= 64 * 1024 else {
            errorMessage = "This message exceeds the 64 KiB payload limit. Shorten it before sending."
            return nil
        }
        guard pendingMessages(for: peerID).isEmpty else {
            errorMessage = "Retry the pending message before sending another."
            return nil
        }
        history.threads[peerID] = thread
        let pending = PendingMessage(id: "ios-\(UUID().uuidString.lowercased())", peerID: peerID, payload: payload, timestamp: Int64(Date().timeIntervalSince1970 * 1000))
        history.pending.append(pending)
        history.drafts[peerID] = nil
        persistHistory()
        return pending
    }

    func retryMessage(_ pending: PendingMessage) async { _ = await deliver(pending) }

    private func deliver(_ pending: PendingMessage) async -> Bool {
        guard let token = mailboxToken, let mid = mailbox?.mid,
              history.pending.contains(where: { $0.id == pending.id }), sendingIDs.insert(pending.id).inserted else { return false }
        let session = sessionID
        let client = api
        let server = client.baseURL
        unconfirmedIDs.remove(pending.id)
        defer {
            if sessionID == session {
                sendingIDs.remove(pending.id)
                // A completed/canceled attempt that still has an outbox entry
                // needs a safe retry. Successful sends already removed theirs.
                if history.pending.contains(where: { $0.id == pending.id }) {
                    unconfirmedIDs.insert(pending.id)
                }
            }
        }
        do {
            // The original request and key survive timeouts and process termination.
            saveTask?.cancel()
            try await store.save(history, server: server, mid: mid)
            guard sessionID == session else { return false }
            let response: SendResponse = try await client.post("/v1/agent/send", body: SendRequest(to: pending.peerID, payload: pending.payload), token: token, idempotencyKey: pending.id)
            guard sessionID == session else { return false }
            let message = ChatMessage(id: "sent-\(pending.peerID)-\(response.id)", from: mid, text: pending.payload.text, timestamp: response.ts ?? pending.timestamp, type: pending.payload.type, clientID: pending.id)
            append(message, conversation: pending.peerID)
            handledMessageIDs.insert(message.id)
            history.pending.removeAll { $0.id == pending.id }
            history.sequences[pending.peerID] = (pending.payload.seq ?? 0) + 1
            persistHistory()
            return true
        } catch {
            guard sessionID == session, !isCancellation(error) else { return false }
            errorMessage = "Delivery is unconfirmed. Retry the pending message safely with its original key. \(error.localizedDescription)"
            persistHistory()
            return false
        }
    }

    func refreshInbox() async { await pollInbox() }

    func signOut() {
        do { try credentials.delete(server: api.baseURL) }
        catch { errorMessage = error.localizedDescription; return }
        persistHistory()
        resetSession()
        statusMessage = "Signed out on this iPhone. The mailbox remains active."
    }

    private func resetSession() {
        sessionID = UUID()
        cancelTokenCopy()
        stopPolling()
        // Keep the final save task so reconnection can wait for its scoped write.
        mailboxToken = nil
        recoveryToken = nil
        mailbox = nil
        peers = []
        history = MailboxHistory()
        selectedPeerID = nil
        handledMessageIDs = []
        sendingIDs = []
        unconfirmedIDs = []
        inboxPollID = nil
        isRefreshingPeers = false
        isRestoring = false
        consecutivePollFailures = 0
        workID = nil
        workIsAdmin = false
        isWorking = false
        errorMessage = nil
        statusMessage = nil
        mailboxConnectionWarning = nil
        lockAdmin()
    }

    func clearError() { errorMessage = nil }

    func copyMailboxToken() async {
        guard canCopyMailboxToken, !appIsBackgrounded, !isCopyingMailboxToken else { return }
        let session = sessionID
        let attempt = UUID()
        tokenCopyAttemptID = attempt
        errorMessage = nil
        statusMessage = nil
        isCopyingMailboxToken = true
        defer {
            if tokenCopyAttemptID == attempt && pendingTokenCopySession == nil {
                isCopyingMailboxToken = false
            }
        }
        do {
            let authenticated = try await authenticateTokenCopy()
            guard authenticated, sessionID == session, tokenCopyAttemptID == attempt,
                  !appIsBackgrounded, !Task.isCancelled else { return }
            // Face ID can finish before scenePhase returns to active. Wait for that
            // transition instead of silently dropping a successful authentication.
            if appIsActive { completeTokenCopy(session: session) }
            else { pendingTokenCopySession = session }
        } catch {
            guard sessionID == session, tokenCopyAttemptID == attempt, !isCancellation(error) else { return }
            if let authenticationError = error as? LAError,
               [.userCancel, .systemCancel, .appCancel].contains(authenticationError.code) { return }
            errorMessage = "Could not authenticate to copy the token. Please try again."
        }
    }

    private func completeTokenCopy(session: UUID) {
        defer { pendingTokenCopySession = nil; isCopyingMailboxToken = false }
        guard sessionID == session, appIsActive, !appIsBackgrounded, let token = mailboxToken else { return }
        if writeTokenToClipboard(token) {
            statusMessage = "Token copied for 2 minutes on this device."
        } else {
            errorMessage = "Could not copy the token. Please try again."
        }
    }

    private func cancelTokenCopy() {
        tokenCopyAttemptID = UUID()
        pendingTokenCopySession = nil
        isCopyingMailboxToken = false
    }

    func deleteMailbox() async {
        guard let token = mailboxToken, let mid = mailbox?.mid, let work = beginWork() else { return }
        let session = sessionID
        let server = api.baseURL
        defer { finishWork(work) }
        do {
            let _: EmptyResponse = try await api.post("/v1/agent/leave", body: EmptyRequest(), token: token)
            guard sessionID == session else { return }
            saveTask?.cancel()
            // Invalidate sends and polls before cleanup; signOut would save the deleted history again.
            resetSession()
            do {
                try credentials.delete(server: server)
                try await store.delete(server: server, mid: mid)
                defaults.removeObject(forKey: "sentMessages.\(mid)")
                statusMessage = "Mailbox deleted and inbox erased."
            } catch {
                errorMessage = "The mailbox was deleted, but local cleanup failed: \(error.localizedDescription)"
            }
        } catch {
            guard sessionID == session, !isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func unlockAdmin(secret: String) async {
        let cleaned = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 32 else { errorMessage = "Admin secrets must be at least 32 characters."; return }
        guard appIsActive, let work = beginWork(admin: true) else { return }
        let session = adminID
        defer { finishWork(work) }
        do {
            adminSecret = cleaned
            let agents = try await fetchAdminAgents(secret: cleaned)
            guard adminID == session, appIsActive else { return }
            adminAgents = agents
            isAdminUnlocked = true
            await loadAdminRegistries()
        } catch {
            guard adminID == session, !isCancellation(error) else { return }
            lockAdmin()
            errorMessage = error.localizedDescription
        }
    }

    func lockAdmin() {
        if workIsAdmin, let workID { finishWork(workID) }
        adminID = UUID()
        inspectionID = UUID()
        adminSecret = nil
        isAdminUnlocked = false
        adminAgents = []
        selectedAdminAgent = nil
        adminInspectionError = nil
        registryTexts = [:]
        isLoadingRegistries = false
        registryStatus = nil
        registryError = nil
    }

    func refreshAdminAgents() async {
        guard let secret = adminSecret, let work = beginWork(admin: true) else { return }
        let session = adminID
        defer { finishWork(work) }
        do {
            let agents = try await fetchAdminAgents(secret: secret)
            guard adminID == session else { return }
            adminAgents = agents
        } catch {
            guard adminID == session, !isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func fetchAdminAgents(secret: String) async throws -> [Peer] {
        let client = api
        let session = adminID
        var all: [Peer] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            guard adminID == session else { throw CancellationError() }
            var path = "/v1/admin/agents?limit=100"
            if let cursor {
                guard seen.insert(cursor).inserted else { throw APIError(statusCode: nil, message: "The admin directory returned a repeated page cursor.") }
                path += "&cursor=\(cursor.queryEncoded)"
            }
            let page: AdminPeerPage = try await client.get(path, adminSecret: secret)
            all.append(contentsOf: page.agents)
            cursor = page.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
        } while cursor != nil
        var seenIDs = Set<String>()
        return all.filter { seenIDs.insert($0.mid).inserted }
    }

    func inspectAdminAgent(_ peer: Peer) async {
        guard let secret = adminSecret else { return }
        let session = adminID
        let inspection = UUID()
        inspectionID = inspection
        selectedAdminAgent = nil
        adminInspectionError = nil
        do {
            let agent: AdminAgent = try await api.get("/v1/admin/agents/\(peer.mid.queryEncoded)", adminSecret: secret)
            guard adminID == session, inspectionID == inspection else { return }
            selectedAdminAgent = agent
        } catch {
            guard adminID == session, inspectionID == inspection, !isCancellation(error) else { return }
            adminInspectionError = error.localizedDescription
        }
    }

    @discardableResult
    func deleteAdminAgent(_ mid: String) async -> Bool {
        guard let secret = adminSecret, let work = beginWork(admin: true) else { return false }
        let session = adminID
        defer { finishWork(work) }
        do {
            let _: AgentDeleteResponse = try await api.delete("/v1/admin/agents/\(mid.queryEncoded)", adminSecret: secret)
            guard adminID == session else { return false }
            if selectedAdminAgent?.mid == mid { selectedAdminAgent = nil }
            adminAgents.removeAll { $0.mid == mid }
            return true
        } catch {
            guard adminID == session, !isCancellation(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func loadAdminRegistries() async {
        guard isAdminUnlocked, !isLoadingRegistries else { return }
        let session = adminID
        let client = api
        isLoadingRegistries = true
        defer { if adminID == session { isLoadingRegistries = false } }
        do {
            async let capabilities: CapabilityRegistry = client.get("/v1/public/capabilities")
            async let guide = client.getText("/v1/public/guide")
            async let policy = client.getText("/v1/public/policy")
            async let source = optionalClientText(client)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let texts: [RegistryKind: String] = [
                .capabilities: String(decoding: try encoder.encode(await capabilities.capabilities), as: UTF8.self),
                .guide: try await guide, .policy: try await policy, .client: try await source,
            ]
            guard adminID == session else { return }
            registryTexts = texts
        } catch {
            guard adminID == session, !isCancellation(error) else { return }
            registryError = error.localizedDescription
        }
    }

    private func optionalClientText(_ client: APIClient) async throws -> String {
        do { return try await client.getText("/v1/public/client") }
        catch let error as APIError where error.statusCode == 404 { return "" }
    }

    func updateRegistryText(_ text: String, kind: RegistryKind) {
        guard isAdminUnlocked, !isLoadingRegistries, registryTexts[kind] != nil else { return }
        registryTexts[kind] = text
        registryError = nil
        registryStatus = nil
    }

    func saveRegistry(_ kind: RegistryKind) async {
        guard !isLoadingRegistries, let secret = adminSecret, let text = registryTexts[kind], let work = beginWork(admin: true) else { return }
        let session = adminID
        registryError = nil
        registryStatus = "Saving…"
        defer { finishWork(work) }
        do {
            let result: EmptyResponse
            switch kind {
            case .capabilities:
                let capabilities = try JSONDecoder().decode([Capability].self, from: Data(text.utf8))
                result = try await api.postText("/v1/admin/registry/capabilities", body: CapabilitiesUpdate(capabilities: capabilities), adminSecret: secret)
            case .guide, .policy:
                result = try await api.postText("/v1/admin/registry/\(kind.rawValue)", body: MarkdownUpdate(markdown: text), adminSecret: secret)
            case .client:
                result = try await api.postText("/v1/admin/registry/client", body: ClientUpdate(source: text), adminSecret: secret)
            }
            guard adminID == session else { return }
            registryStatus = result.version.map { "Saved as version \($0)." } ?? "Saved."
        } catch {
            guard adminID == session, !isCancellation(error) else { return }
            registryError = error.localizedDescription
            registryStatus = nil
        }
    }

    func setAppActive(_ active: Bool, isBackgrounded: Bool = false) {
        appIsActive = active
        appIsBackgrounded = !active && isBackgrounded
        if active {
            if let session = pendingTokenCopySession { completeTokenCopy(session: session) }
            if mailbox != nil { startPolling() }
        } else {
            if appIsBackgrounded { cancelTokenCopy() }
            persistHistory()
            stopPolling()
            lockAdmin()
        }
    }

    func updateAPIBaseURL(_ value: String) {
        guard !isWorking, !isRestoring else { errorMessage = "Wait for the current operation before changing servers."; return }
        guard let url = APIClient.validatedBaseURL(value) else {
            errorMessage = "Enter an HTTPS server origin without a path, query, or credentials. HTTP is supported for private LAN addresses, localhost, and .local development hosts."
            return
        }
        guard url != api.baseURL else { return }
        // Flush the old server's data and invalidate every in-flight response before switching.
        persistHistory()
        resetSession()
        api = APIClient(baseURL: url)
        apiBaseURLText = url.absoluteString
        defaults.set(url.absoluteString, forKey: "apiBaseURL")
        statusMessage = "Server changed. Reconnect to a mailbox on this server."
    }

    func resetAPIBaseURL() { updateAPIBaseURL(APIClient.productionURL.absoluteString) }

    private func startPolling() {
        guard appIsActive, mailboxToken != nil, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var cycles = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollInbox()
                if cycles % 5 == 0 { await self.refreshPeers() }
                cycles += 1
                let delay = min(30, 3 * (1 << min(self.consecutivePollFailures, 3)))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollInbox() async {
        guard appIsActive, let token = mailboxToken, inboxPollID == nil else { return }
        let session = sessionID
        let pollID = UUID()
        let client = api
        inboxPollID = pollID
        defer { if inboxPollID == pollID { inboxPollID = nil } }
        do {
            var cursorSet = Set<String>()
            var more = true
            while more {
                try Task.checkCancellation()
                let cursor = history.cursor
                guard cursorSet.insert(cursor).inserted else { throw APIError(statusCode: nil, message: "Inbox returned a repeated cursor.") }
                let page: PollPage = try await client.get("/v1/agent/poll?since=\(cursor.queryEncoded)&limit=100", token: token)
                guard sessionID == session, appIsActive else { return }
                var addedMessages = false
                for message in page.messages {
                    let localID = "received-\(message.id)"
                    guard let text = message.payload.text, handledMessageIDs.insert(localID).inserted else { continue }
                    addedMessages = true
                    append(ChatMessage(id: localID, from: message.from, text: text, timestamp: message.ts, type: message.payload.type ?? "msg"), conversation: message.from)
                    if history.threads[message.from] == nil, let thread = message.payload.thread { history.threads[message.from] = thread }
                    if selectedPeerID != message.from { history.unread[message.from, default: 0] += 1 }
                }
                let nextCursor = page.cursor ?? cursor
                if nextCursor != cursor { history.cursor = nextCursor }
                if addedMessages || nextCursor != cursor { persistHistory() }
                if page.hasMore && (page.messages.isEmpty || history.cursor == cursor) {
                    throw APIError(statusCode: nil, message: "Inbox pagination did not advance.")
                }
                more = page.hasMore
            }
            consecutivePollFailures = 0
            mailboxConnectionWarning = nil
        } catch {
            guard sessionID == session, !isCancellation(error) else { return }
            consecutivePollFailures += 1
            if (error as? APIError)?.statusCode == 401 {
                mailboxConnectionWarning = "Mailbox access expired. Sign out and reconnect with a current token."
                stopPolling()
            } else {
                mailboxConnectionWarning = "Reconnecting… Saved messages remain available on this iPhone."
            }
        }
    }

    private func append(_ message: ChatMessage, conversation peerID: String) {
        var messages = history.conversations[peerID] ?? []
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        if let last = messages.last, last.timestamp > message.timestamp {
            let index = messages.firstIndex { $0.timestamp > message.timestamp } ?? messages.endIndex
            messages.insert(message, at: index)
        } else { messages.append(message) }
        // Keep rendering, memory, and disk usage bounded for long-lived mailboxes.
        history.conversations[peerID] = Array(messages.suffix(500))
        if handledMessageIDs.count > 10_000 {
            handledMessageIDs = Set(history.conversations.values.flatMap { $0.map(\.id) })
        }
    }

    private func persistHistory(debounce: Bool = false) {
        guard let mid = mailbox?.mid else { return }
        saveTask?.cancel()
        let snapshot = history
        let revision = DispatchTime.now().uptimeNanoseconds
        let server = api.baseURL
        let session = sessionID
        let store = store
        saveTask = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(350)) }
                try Task.checkCancellation()
                try await store.save(snapshot, server: server, mid: mid, revision: revision)
            } catch {
                guard let self, self.sessionID == session, !self.isCancellation(error) else { return }
                self.errorMessage = "Could not save local history. Keep the app open and retry."
            }
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

private extension String {
    var queryEncoded: String {
        addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? self
    }
}
