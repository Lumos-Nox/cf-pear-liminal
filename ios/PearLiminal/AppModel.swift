import Foundation
import Observation
import OSLog
import LocalAuthentication
import Network
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
    private(set) var closingPeerIDs = Set<String>()
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
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var safetyPollTask: Task<Void, Never>?
    @ObservationIgnored private var socketTask: URLSessionWebSocketTask?
    @ObservationIgnored private var socketReceiveTask: Task<Void, Never>?
    @ObservationIgnored private var socketPingTask: Task<Void, Never>?
    @ObservationIgnored private var realtimeID: UUID?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var streamPollsInFlight = Set<String>()
    @ObservationIgnored private var requestedStreamPolls = Set<String>()
    @ObservationIgnored private var streamSyncInFlight = false
    @ObservationIgnored private var streamSyncRequested = false
    @ObservationIgnored private let networkMonitor = NWPathMonitor()
    @ObservationIgnored private var networkIsAvailable = true
    @ObservationIgnored private var mailboxAuthExpired = false
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
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkPathChanged(available) }
        }
        networkMonitor.start(queue: DispatchQueue(label: "com.pearliminal.network-path"))
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
        mailboxAuthExpired = false
        statusMessage = current.label.isEmpty ? "Mailbox connected." : "Connected as \(current.label)."
        mailboxConnectionWarning = nil
        startRealtime()
    }

    func refreshPeers() async {
        guard let token = mailboxToken, networkIsAvailable, !mailboxAuthExpired, !isRefreshingPeers else { return }
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
            if (error as? APIError)?.statusCode == 401 {
                mailboxAuthExpired = true
                mailboxConnectionWarning = "Mailbox access expired. Sign out and reconnect with a current token."
                stopRealtime()
            } else {
                mailboxConnectionWarning = "Directory refresh failed. Pull down to retry."
            }
        }
    }

    func canDeleteConversation(_ peerID: String) -> Bool {
        mailbox != nil && !history.pending.contains { $0.peerID == peerID && sendingIDs.contains($0.id) }
    }

    func isPeerClosed(_ peerID: String) -> Bool {
        closingPeerIDs.contains(peerID) || history.closedStreams[peerID] != nil
    }

    func peerClosureLabel(_ peerID: String) -> String? {
        if closingPeerIDs.contains(peerID) { return "Closing" }
        return history.closedStreams[peerID]?.peerStatus.capitalized
    }

    func deleteConversation(_ peerID: String) {
        guard canDeleteConversation(peerID) else { return }
        history.conversations[peerID] = nil
        history.drafts[peerID] = nil
        history.unread[peerID] = nil
        unconfirmedIDs.subtract(history.pending.filter { $0.peerID == peerID }.map(\.id))
        history.pending.removeAll { $0.peerID == peerID }
        if selectedPeerID == peerID { selectedPeerID = nil }
        // Keep stream cursors and deduplication IDs so a refresh does not replay
        // deleted notes. Keep thread/sequence metadata for the next outgoing note.
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
        startRealtime()
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
        guard !isPeerClosed(peerID) else {
            errorMessage = "This peer has left or is no longer available. Messages cannot be sent."
            return nil
        }
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
        guard !isPeerClosed(pending.peerID), let token = mailboxToken, let mid = mailbox?.mid,
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
            guard !isPeerClosed(pending.peerID) else { return false }
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

    func refreshInbox() async { await catchUpAllStreams() }

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
        stopRealtime()
        // Keep the final save task so reconnection can wait for its scoped write.
        mailboxToken = nil
        recoveryToken = nil
        mailbox = nil
        peers = []
        history = MailboxHistory()
        selectedPeerID = nil
        closingPeerIDs = []
        handledMessageIDs = []
        sendingIDs = []
        unconfirmedIDs = []
        streamPollsInFlight = []
        requestedStreamPolls = []
        streamSyncInFlight = false
        streamSyncRequested = false
        isRefreshingPeers = false
        isRestoring = false
        consecutivePollFailures = 0
        mailboxAuthExpired = false
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
        stopRealtime()
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
            startRealtime()
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
            if mailbox != nil { startRealtime() }
        } else {
            if appIsBackgrounded { cancelTokenCopy() }
            persistHistory()
            stopRealtime()
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

    private func networkPathChanged(_ available: Bool) {
        guard networkIsAvailable != available else { return }
        networkIsAvailable = available
        stopRealtime()
        if available, mailbox != nil, appIsActive { startRealtime() }
    }

    private func startRealtime() {
        guard appIsActive, networkIsAvailable, !mailboxAuthExpired, mailboxToken != nil, realtimeID == nil else { return }
        let id = UUID()
        let session = sessionID
        realtimeID = id
        connectionTask = Task { [weak self] in
            guard let self else { return }
            await self.runConnectionLoop(id: id, session: session)
        }
        safetyPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.sessionID == session, self.realtimeID == id, self.appIsActive else { return }
                await self.catchUpAllStreams()
            }
        }
    }

    private func stopRealtime() {
        realtimeID = nil
        connectionTask?.cancel()
        connectionTask = nil
        safetyPollTask?.cancel()
        safetyPollTask = nil
        socketReceiveTask?.cancel()
        socketReceiveTask = nil
        socketPingTask?.cancel()
        socketPingTask = nil
        if let socketTask {
            AppLogger.logger.debug("\(LogTimestamp.prefix(), privacy: .public) WebSocket disconnect requested; closeCode=\(socketTask.closeCode.rawValue, privacy: .public)")
        }
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
    }

    private func isCurrentRealtime(_ id: UUID, session: UUID) -> Bool {
        realtimeID == id && sessionID == session && appIsActive && mailboxToken != nil
    }

    private func runConnectionLoop(id: UUID, session: UUID) async {
        var failures = 0
        while isCurrentRealtime(id, session: session), networkIsAvailable, !mailboxAuthExpired, !Task.isCancelled {
            var connectingTask: URLSessionWebSocketTask?
            var connectionOpenedAt: Date?
            do {
                guard let token = mailboxToken else { return }
                let client = api
                AppLogger.logger.debug("\(LogTimestamp.prefix(), privacy: .public) WebSocket connection attempt started")
                let webSocket = try client.webSocketTask("/v1/agent/connect", token: token)
                connectingTask = webSocket
                socketTask = webSocket
                webSocket.resume()
                // A successful protocol ping confirms the upgrade before catch-up begins.
                try await client.sendWebSocketPing(webSocket)
                connectionOpenedAt = Date()
                AppLogger.logger.debug("\(LogTimestamp.prefix(), privacy: .public) WebSocket connection established")
                guard isCurrentRealtime(id, session: session) else { return }
                consecutivePollFailures = 0
                mailboxConnectionWarning = nil
                await catchUpAllStreams()
                guard isCurrentRealtime(id, session: session) else { return }

                let receiveTask = Task { [weak self] in
                    guard let self else { return }
                    await self.receiveSocketMessages(webSocket, id: id, session: session)
                }
                let pingTask = Task { [weak self] in
                    guard let self else { return }
                    await self.keepSocketAlive(webSocket, id: id, session: session)
                }
                socketReceiveTask = receiveTask
                socketPingTask = pingTask
                await receiveTask.value
                pingTask.cancel()
                await pingTask.value
                guard isCurrentRealtime(id, session: session), !Task.isCancelled else { return }
                AppLogger.logger.warning("\(LogTimestamp.prefix(), privacy: .public) WebSocket receive loop ended; closeCode=\(webSocket.closeCode.rawValue, privacy: .public)")
                throw URLError(.networkConnectionLost)
            } catch {
                let closeCode = connectingTask?.closeCode.rawValue ?? -1
                let statusCode = (connectingTask?.response as? HTTPURLResponse)?.statusCode ?? 0
                connectingTask?.cancel(with: .goingAway, reason: nil)
                if let currentSocket = socketTask, let connectingTask, currentSocket === connectingTask {
                    socketTask = nil
                }
                socketReceiveTask?.cancel()
                socketReceiveTask = nil
                socketPingTask?.cancel()
                socketPingTask = nil
                guard isCurrentRealtime(id, session: session), !Task.isCancelled else { return }
                if (connectingTask?.response as? HTTPURLResponse)?.statusCode == 401 {
                    AppLogger.logger.error("\(LogTimestamp.prefix(), privacy: .public) WebSocket authentication rejected with HTTP 401")
                    mailboxAuthExpired = true
                    mailboxConnectionWarning = "Mailbox access expired. Sign out and reconnect with a current token."
                    stopRealtime()
                    return
                }
                if !isCancellation(error) {
                    AppLogger.logger.warning("\(LogTimestamp.prefix(), privacy: .public) WebSocket disconnected; closeCode=\(closeCode, privacy: .public), httpStatus=\(statusCode, privacy: .public), error=\(String(describing: error), privacy: .private)")
                    if let connectionOpenedAt, Date().timeIntervalSince(connectionOpenedAt) >= 60 { failures = 0 }
                    failures += 1
                    consecutivePollFailures += 1
                    mailboxConnectionWarning = "Reconnecting… Saved messages remain available on this iPhone."
                }
                let baseDelay = min(30.0, pow(2.0, Double(min(max(failures - 1, 0), 5))))
                let delay = baseDelay + Double.random(in: 0...(baseDelay * 0.5))
                if !isCancellation(error) {
                    AppLogger.logger.debug("\(LogTimestamp.prefix(), privacy: .public) WebSocket reconnect scheduled after \(delay, privacy: .public) seconds; attempt=\(failures, privacy: .public)")
                }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
        if realtimeID == id {
            realtimeID = nil
            connectionTask = nil
        }
    }

    private func receiveSocketMessages(_ webSocket: URLSessionWebSocketTask, id: UUID, session: UUID) async {
        while isCurrentRealtime(id, session: session), !Task.isCancelled {
            do {
                let frame = try await webSocket.receive()
                let data: Data
                switch frame {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                guard let event = try? JSONDecoder().decode(PushEvent.self, from: data),
                      event.type == "message", let peer = event.message?.from,
                      peer != mailbox?.mid else { continue }
                _ = await catchUpStream(peerID: peer, session: session)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.logger.warning("\(LogTimestamp.prefix(), privacy: .public) WebSocket receive failed; closeCode=\(webSocket.closeCode.rawValue, privacy: .public), error=\(String(describing: error), privacy: .private)")
                return
            }
        }
    }

    private func keepSocketAlive(_ webSocket: URLSessionWebSocketTask, id: UUID, session: UUID) async {
        while isCurrentRealtime(id, session: session), !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
                guard isCurrentRealtime(id, session: session), !Task.isCancelled else { return }
                try await api.sendWebSocketPing(webSocket)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.logger.warning("\(LogTimestamp.prefix(), privacy: .public) WebSocket keepalive stopped after ping failure; closeCode=\(webSocket.closeCode.rawValue, privacy: .public)")
                webSocket.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }

    private func catchUpAllStreams() async {
        guard appIsActive, !mailboxAuthExpired, let token = mailboxToken, let mailboxID = mailbox?.mid else { return }
        let session = sessionID
        if streamSyncInFlight {
            streamSyncRequested = true
            return
        }
        streamSyncInFlight = true
        defer {
            if sessionID == session {
                streamSyncInFlight = false
                if streamSyncRequested, mailboxToken != nil, !mailboxAuthExpired {
                    streamSyncRequested = false
                    Task { await self.catchUpAllStreams() }
                }
            }
        }
        do {
            let streams: StreamList = try await api.get("/v1/agent/streams", token: token)
            guard sessionID == session, appIsActive else { return }
            var changed = false
            var allStreamsCaughtUp = true
            for stream in streams.streams where stream.peer != mailboxID {
                guard history.closedStreams[stream.peer] == nil else { continue }
                if let peerStatus = stream.peerStatus, peerStatus == "left" || peerStatus == "removed" {
                    closingPeerIDs.insert(stream.peer)
                    guard await waitForStreamPoll(peerID: stream.peer, session: session) else { return }
                    guard sessionID == session, appIsActive else { return }

                    let cursor = history.streamCursors[stream.peer] ?? 0
                    if cursor < stream.lastSeq {
                        if stream.messages == 0 {
                            // The stream still exists after its retained messages expire.
                            history.streamCursors[stream.peer] = stream.lastSeq
                            changed = true
                        } else {
                            let drained = await catchUpStream(
                                peerID: stream.peer,
                                session: session,
                                through: stream.lastSeq,
                                allowClosing: true
                            )
                            allStreamsCaughtUp = drained && allStreamsCaughtUp
                            guard sessionID == session, appIsActive else { return }
                        }
                    }

                    let drainedCursor = history.streamCursors[stream.peer] ?? 0
                    if drainedCursor >= stream.lastSeq {
                        history.closedStreams[stream.peer] = ClosedStreamRecord(
                            peerStatus: peerStatus,
                            peerStatusAt: stream.peerStatusAt,
                            lastSeq: stream.lastSeq
                        )
                        closingPeerIDs.remove(stream.peer)
                        changed = true
                    } else {
                        allStreamsCaughtUp = false
                    }
                    continue
                }

                closingPeerIDs.remove(stream.peer)
                if stream.messages == 0 {
                    let previous = history.streamCursors[stream.peer] ?? 0
                    if stream.lastSeq > previous {
                        history.streamCursors[stream.peer] = stream.lastSeq
                        changed = true
                    }
                } else {
                    allStreamsCaughtUp = await catchUpStream(peerID: stream.peer, session: session) && allStreamsCaughtUp
                    guard sessionID == session, appIsActive else { return }
                }
            }
            if changed { persistHistory() }
            if allStreamsCaughtUp {
                consecutivePollFailures = 0
                mailboxConnectionWarning = nil
            }
        } catch {
            guard sessionID == session, !isCancellation(error) else { return }
            consecutivePollFailures += 1
            if (error as? APIError)?.statusCode == 401 {
                mailboxAuthExpired = true
                mailboxConnectionWarning = "Mailbox access expired. Sign out and reconnect with a current token."
                stopRealtime()
            } else {
                mailboxConnectionWarning = "Reconnecting… Saved messages remain available on this iPhone."
            }
        }
    }

    private func waitForStreamPoll(peerID: String, session: UUID) async -> Bool {
        while streamPollsInFlight.contains(peerID) {
            guard sessionID == session, appIsActive, mailboxToken != nil else { return false }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return sessionID == session && appIsActive
    }

    private func catchUpStream(
        peerID: String,
        session: UUID,
        through targetSeq: Int64? = nil,
        allowClosing: Bool = false
    ) async -> Bool {
        guard sessionID == session, appIsActive, let token = mailboxToken,
              peerID != mailbox?.mid,
              !mailboxAuthExpired,
              history.closedStreams[peerID] == nil,
              (!closingPeerIDs.contains(peerID) || allowClosing) else { return true }
        if streamPollsInFlight.contains(peerID) {
            requestedStreamPolls.insert(peerID)
            return true
        }
        streamPollsInFlight.insert(peerID)
        defer {
            if sessionID == session {
                streamPollsInFlight.remove(peerID)
                if requestedStreamPolls.remove(peerID) != nil, appIsActive, !mailboxAuthExpired {
                    Task { await self.catchUpStream(peerID: peerID, session: session) }
                }
            }
        }
        let client = api
        do {
            var seenCursors = Set<Int64>()
            var hasMore = true
            while hasMore || (targetSeq.map { (history.streamCursors[peerID] ?? 0) < $0 } ?? false) {
                try Task.checkCancellation()
                let cursor = history.streamCursors[peerID] ?? 0
                if let targetSeq, cursor >= targetSeq { break }
                guard seenCursors.insert(cursor).inserted else {
                    throw APIError(statusCode: nil, message: "A conversation returned a repeated stream cursor.")
                }
                let path = "/v1/agent/poll?peer=\(peerID.queryEncoded)&since=\(cursor)&limit=500"
                let page: PollPage = try await client.get(path, token: token)
                guard sessionID == session, appIsActive else { return false }
                var addedMessage = false
                for message in page.messages where message.from == peerID {
                    let localID = "received-\(peerID)-\(message.id)"
                    let legacyLocalID = "received-\(message.id)"
                    guard let text = message.payload.text,
                          !handledMessageIDs.contains(localID), !handledMessageIDs.contains(legacyLocalID) else { continue }
                    handledMessageIDs.insert(localID)
                    addedMessage = true
                    append(ChatMessage(id: localID, from: peerID, text: text, timestamp: message.ts, type: message.payload.type ?? "msg"), conversation: peerID)
                    if history.threads[peerID] == nil, let thread = message.payload.thread { history.threads[peerID] = thread }
                    if selectedPeerID != peerID { history.unread[peerID, default: 0] += 1 }
                }
                guard let rawCursor = page.cursor, let nextCursor = Int64(rawCursor), nextCursor >= cursor else {
                    throw APIError(statusCode: nil, message: "The server returned an invalid stream cursor.")
                }
                if nextCursor != cursor { history.streamCursors[peerID] = nextCursor }
                if addedMessage || nextCursor != cursor { persistHistory() }
                if page.hasMore && (page.messages.isEmpty || nextCursor == cursor) {
                    throw APIError(statusCode: nil, message: "Conversation pagination did not advance.")
                }
                if let targetSeq {
                    if nextCursor >= targetSeq {
                        hasMore = false
                    } else if page.hasMore {
                        hasMore = true
                    } else {
                        // No retained rows remain after this page; any later seqs expired.
                        history.streamCursors[peerID] = max(nextCursor, targetSeq)
                        persistHistory()
                        hasMore = false
                    }
                } else {
                    hasMore = page.hasMore
                }
            }
            return true
        } catch {
            guard sessionID == session, !isCancellation(error) else { return false }
            consecutivePollFailures += 1
            if (error as? APIError)?.statusCode == 401 {
                mailboxAuthExpired = true
                mailboxConnectionWarning = "Mailbox access expired. Sign out and reconnect with a current token."
                stopRealtime()
            } else {
                mailboxConnectionWarning = "Reconnecting… Saved messages remain available on this iPhone."
            }
            return false
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
