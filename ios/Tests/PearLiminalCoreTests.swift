import XCTest
@testable import PearLiminalCore

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, String))?
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        DispatchQueue.global().async { [self] in
            lock.lock()
            let isStopped = stopped
            lock.unlock()
            guard !isStopped else { return }
            do {
                let (status, body) = try handler(request)
                lock.lock()
                defer { lock.unlock() }
                guard !stopped else { return }
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                lock.lock()
                defer { lock.unlock() }
                if !stopped { client?.urlProtocol(self, didFailWithError: error) }
            }
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

@MainActor private final class MemoryCredentials: MailboxCredentials {
    var tokens: [URL: String] = [:]
    var shouldFailWrites = false
    func read(server: URL) -> String? { tokens[server] }
    func write(_ token: String, server: URL) throws {
        if shouldFailWrites { throw APIError(statusCode: nil, message: "Simulated Keychain failure") }
        tokens[server] = token
    }
    func delete(server: URL) { tokens[server] = nil }
}

@MainActor final class PearLiminalCoreTests: XCTestCase {
    private let origin = URL(string: "https://test.example.invalid")!
    private var session: URLSession!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var suite: String!
    private var credentials: MemoryCredentials!
    private var store: MailboxStore!
    private let identity = #"{"mid":"m-test","label":"Alice","capabilities":[],"created_at":1,"message_count":0,"message_bytes":0}"#

    override func setUp() async throws {
        suite = "PearLiminalTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        store = MailboxStore(directory: directory)
        credentials = MemoryCredentials()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        StubProtocol.handler = nil
    }

    private func model(
        authenticateTokenCopy: (@MainActor () async throws -> Bool)? = nil,
        writeTokenToClipboard: (@MainActor (String) -> Bool)? = nil
    ) -> AppModel {
        AppModel(api: APIClient(baseURL: origin, session: session), defaults: defaults, store: store, credentials: credentials,
                 authenticateTokenCopy: authenticateTokenCopy, writeTokenToClipboard: writeTokenToClipboard)
    }

    private func connectedModel(
        authenticateTokenCopy: (@MainActor () async throws -> Bool)? = nil,
        writeTokenToClipboard: (@MainActor (String) -> Bool)? = nil
    ) async -> AppModel {
        let identity = identity
        StubProtocol.handler = { request in
            if request.url!.path == "/v1/agent/self" { return (200, identity) }
            return (200, #"{"peers":[],"next_cursor":null}"#)
        }
        let model = model(authenticateTokenCopy: authenticateTokenCopy, writeTokenToClipboard: writeTokenToClipboard)
        model.setAppActive(false)
        await model.reconnect(token: "test-token")
        XCTAssertEqual(model.mailbox?.mid, "m-test")
        return model
    }

    func testOriginValidationRejectsCredentialLeakVectors() {
        for value in ["https://user:secret@example.com", "https://example.com/api", "https://example.com?token=x", "https://example.com#x", "http://example.com", "file:///etc/passwd", "//example.com"] {
            XCTAssertNil(APIClient.validatedBaseURL(value), value)
        }
        XCTAssertEqual(APIClient.validatedBaseURL(" HTTPS://Example.COM:443/ ")?.absoluteString, "https://example.com")
        XCTAssertNotNil(APIClient.validatedBaseURL("http://mac.local:8788"))
        XCTAssertNotNil(APIClient.validatedBaseURL("http://127.0.0.1:8788"))
    }

    func testMalformedPayloadDoesNotPoisonEntireInbox() async throws {
        StubProtocol.handler = { _ in
            (200, #"{"messages":[{"id":"bad","from":"peer","payload":[1,2],"ts":1},{"id":"good","from":"peer","payload":{"text":"hello","type":"msg"},"ts":2}],"cursor":2,"has_more":false}"#)
        }
        let client = APIClient(baseURL: origin, session: session)
        let page: PollPage = try await client.get("/v1/agent/poll")
        XCTAssertNil(page.messages[0].payload.text)
        XCTAssertEqual(page.messages[1].payload.text, "hello")
        XCTAssertEqual(page.cursor, "2")
    }

    func testHugeNumericFieldsCannotTrap() async throws {
        StubProtocol.handler = { _ in (200, #"{"messages":[],"cursor":1e100,"has_more":false}"#) }
        let client = APIClient(baseURL: origin, session: session)
        let page: PollPage = try await client.get("/v1/agent/poll")
        XCTAssertNil(page.cursor)
        StubProtocol.handler = { _ in (200, #"{"id":"test","ts":1e100}"#) }
        let response: SendResponse = try await client.post("/v1/agent/send", body: EmptyRequest())
        XCTAssertNil(response.ts)
    }

    func testAPIRejectsAbsoluteURLsBeforeSendingCredentials() async {
        StubProtocol.handler = { _ in XCTFail("Must not send a request"); return (200, "{}") }
        do {
            let _: EmptyResponse = try await APIClient(baseURL: origin, session: session).get("https://other.invalid/v1/agent/self", token: "private")
            XCTFail("Absolute URL must be rejected")
        } catch { XCTAssertTrue(error is APIError) }
    }

    func testCancellationRemainsCancellation() async {
        StubProtocol.handler = { _ in throw URLError(.cancelled) }
        do {
            let _: EmptyResponse = try await APIClient(baseURL: origin, session: session).get("/v1/agent/self")
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testServerChangeInvalidatesSessionAndScopesCredentials() async {
        let model = await connectedModel()
        model.updateDraft("private draft", for: "peer")
        model.updateAPIBaseURL("https://another.example.invalid")
        XCTAssertNil(model.mailbox)
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertEqual(model.draft(for: "peer"), "")
        XCTAssertEqual(credentials.read(server: origin), "test-token")
        XCTAssertNil(credentials.read(server: URL(string: model.apiBaseURLText)!))
        XCTAssertFalse(model.canCopyMailboxToken)
    }

    func testFailedSendReusesOriginalKeyAndBodyOnRetry() async throws {
        let model = await connectedModel()
        var attempts: [URLRequest] = []
        var bodies: [Data] = []
        StubProtocol.handler = { request in
            attempts.append(request)
            if let data = request.httpBody { bodies.append(data) }
            else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let length = stream.read(&buffer, maxLength: buffer.count)
                    if length <= 0 { break }
                    data.append(buffer, count: length)
                }
                bodies.append(data)
            }
            return attempts.count == 1 ? (503, #"{"error":"unavailable"}"#) : (200, #"{"id":"accepted","ts":3,"duplicate":true}"#)
        }
        let first = await model.sendMessage("Hello", to: "peer")
        XCTAssertFalse(first)
        XCTAssertEqual(model.pendingMessages(for: "peer").count, 1)
        let persisted = try await store.load(server: origin, mid: "m-test")
        XCTAssertEqual(persisted?.pending.first?.payload.text, "Hello")
        let pending = try XCTUnwrap(model.pendingMessages(for: "peer").first)
        XCTAssertTrue(model.unconfirmedIDs.contains(pending.id))
        await model.retryMessage(pending)
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0].value(forHTTPHeaderField: "Idempotency-Key"), attempts[1].value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.first, bodies.last)
        let sentBody = try JSONDecoder().decode(SendRequest.self, from: XCTUnwrap(bodies.first))
        XCTAssertEqual(sentBody.to, "peer")
        XCTAssertEqual(sentBody.payload.text, "Hello")
        XCTAssertEqual(sentBody.payload.type, "msg")
        XCTAssertTrue(model.pendingMessages(for: "peer").isEmpty)
        XCTAssertTrue(model.unconfirmedIDs.isEmpty)
        XCTAssertEqual(model.conversations["peer"]?.count, 1)
        XCTAssertEqual(model.conversations["peer"]?.first?.id, "sent-peer-accepted")
        model.signOut()
    }

    func testQueuedAndInFlightMessageNeverShowsUnconfirmedWarning() async throws {
        let model = await connectedModel()
        let pending = try XCTUnwrap(model.queueMessage("Hello", to: "peer"))
        // This is the gap between queueing and the UI's asynchronous send task.
        XCTAssertFalse(model.sendingIDs.contains(pending.id))
        XCTAssertFalse(model.unconfirmedIDs.contains(pending.id))
        let received = expectation(description: "Send started")
        let gate = DispatchSemaphore(value: 0)
        StubProtocol.handler = { _ in
            received.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return (200, #"{"id":"accepted","ts":1}"#)
        }
        let task = Task { await model.retryMessage(pending) }
        await fulfillment(of: [received], timeout: 2)
        XCTAssertTrue(model.sendingIDs.contains(pending.id))
        XCTAssertFalse(model.unconfirmedIDs.contains(pending.id))
        gate.signal()
        await task.value
        XCTAssertTrue(model.pendingMessages(for: "peer").isEmpty)
        XCTAssertTrue(model.unconfirmedIDs.isEmpty)
        let delivered = try XCTUnwrap(model.conversations["peer"]?.first)
        XCTAssertEqual(delivered.id, "sent-peer-accepted")
        XCTAssertEqual(delivered.presentationID, pending.id, "Acknowledgement must keep the queued bubble's identity")
        try await store.save(model.history, server: origin, mid: "m-test")
        let restored = try await store.load(server: origin, mid: "m-test")
        XCTAssertEqual(restored?.conversations["peer"]?.first?.presentationID, pending.id)
        model.signOut()
    }

    func testOlderMessageHistoryDecodesWithoutClientIdentity() throws {
        let data = Data(#"{"id":"sent-peer-old","from":"m-test","text":"Old note","timestamp":1,"type":"msg"}"#.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertNil(message.clientID)
        XCTAssertEqual(message.presentationID, "sent-peer-old")
    }

    func testUnconfirmedWarningIsHiddenWhileRetryIsInFlight() async throws {
        let model = await connectedModel()
        StubProtocol.handler = { _ in (503, #"{"error":"unavailable"}"#) }
        let sent = await model.sendMessage("Retry me", to: "peer")
        XCTAssertFalse(sent)
        let pending = try XCTUnwrap(model.pendingMessages(for: "peer").first)
        XCTAssertTrue(model.unconfirmedIDs.contains(pending.id))
        let received = expectation(description: "Retry started")
        let gate = DispatchSemaphore(value: 0)
        StubProtocol.handler = { _ in
            received.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return (200, #"{"id":"retried","ts":2}"#)
        }
        let task = Task { await model.retryMessage(pending) }
        await fulfillment(of: [received], timeout: 2)
        XCTAssertTrue(model.sendingIDs.contains(pending.id))
        XCTAssertFalse(model.unconfirmedIDs.contains(pending.id))
        gate.signal()
        await task.value
        XCTAssertTrue(model.unconfirmedIDs.isEmpty)
        XCTAssertEqual(model.conversations["peer"]?.count, 1)
        model.signOut()
    }

    func testCanceledDeliveryRemainsRetryableWithoutFailureAlert() async throws {
        let model = await connectedModel()
        StubProtocol.handler = { _ in throw URLError(.cancelled) }
        let sent = await model.sendMessage("Interrupted", to: "peer")
        XCTAssertFalse(sent)
        let pending = try XCTUnwrap(model.pendingMessages(for: "peer").first)
        XCTAssertTrue(model.unconfirmedIDs.contains(pending.id))
        XCTAssertFalse(model.sendingIDs.contains(pending.id))
        XCTAssertNil(model.errorMessage)
        model.signOut()
    }

    func testLockDuringUnlockCannotReopenAdminConsole() async {
        let model = model()
        let received = expectation(description: "Admin request started")
        let gate = DispatchSemaphore(value: 0)
        StubProtocol.handler = { _ in
            received.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return (200, #"{"agents":[],"next_cursor":null}"#)
        }
        let task = Task { await model.unlockAdmin(secret: String(repeating: "x", count: 32)) }
        await fulfillment(of: [received], timeout: 2)
        model.setAppActive(false)
        gate.signal()
        await task.value
        XCTAssertFalse(model.isAdminUnlocked)
        XCTAssertTrue(model.adminAgents.isEmpty)
        XCTAssertTrue(model.registryTexts.isEmpty)
    }

    func testLateSendCannotRepopulateSignedOutHistory() async {
        let model = await connectedModel()
        let received = expectation(description: "Send started")
        let gate = DispatchSemaphore(value: 0)
        StubProtocol.handler = { _ in
            received.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return (200, #"{"id":"late","ts":1}"#)
        }
        let task = Task { await model.sendMessage("private", to: "peer") }
        await fulfillment(of: [received], timeout: 2)
        model.signOut()
        gate.signal()
        let sent = await task.value
        XCTAssertFalse(sent)
        XCTAssertNil(model.mailbox)
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertTrue(model.sendingIDs.isEmpty)
        XCTAssertTrue(model.unconfirmedIDs.isEmpty)
    }

    func testHistoryIsSeparatedByServerAndMailbox() async throws {
        var history = MailboxHistory()
        history.drafts["peer"] = "private draft"
        try await store.save(history, server: origin, mid: "m-one")
        let restored = try await store.load(server: origin, mid: "m-one")
        XCTAssertEqual(restored?.drafts["peer"], "private draft")
        let otherMailbox = try await store.load(server: origin, mid: "m-two")
        let otherServer = try await store.load(server: URL(string: "https://other.invalid")!, mid: "m-one")
        XCTAssertNil(otherMailbox)
        XCTAssertNil(otherServer)
    }

    func testOversizedJSONPayloadDoesNotQueueOrSend() async {
        let model = await connectedModel()
        StubProtocol.handler = { _ in XCTFail("Oversized payload must not be sent"); return (200, "{}") }
        // JSON escaping makes this larger than its raw text representation.
        let sent = await model.sendMessage(String(repeating: "\"", count: 40_000), to: "peer")
        XCTAssertFalse(sent)
        XCTAssertTrue(model.pendingMessages(for: "peer").isEmpty)
        XCTAssertNotNil(model.errorMessage)
        model.signOut()
    }
    func testDeletingMailboxDoesNotRecreateItsLocalHistory() async throws {
        let model = await connectedModel()
        model.updateDraft("erase me", for: "peer")
        try await store.save(model.history, server: origin, mid: "m-test")
        StubProtocol.handler = { _ in (200, #"{"ok":true}"#) }
        await model.deleteMailbox()
        XCTAssertNil(model.mailbox)
        XCTAssertNil(credentials.read(server: origin))
        let stored = try await store.load(server: origin, mid: "m-test")
        XCTAssertNil(stored)
    }

    func testInvalidServerEditPreservesWorkingSession() async {
        let model = await connectedModel()
        model.updateAPIBaseURL("http://public.example.invalid")
        XCTAssertEqual(model.mailbox?.mid, "m-test")
        XCTAssertEqual(model.apiBaseURLText, origin.absoluteString)
        XCTAssertEqual(defaults.string(forKey: "apiBaseURL"), nil)
        model.signOut()
    }

    func testFailedSendSurvivesReconnectionWithoutChangingItsKey() async throws {
        let first = await connectedModel()
        StubProtocol.handler = { _ in (503, #"{"error":"try later"}"#) }
        _ = await first.sendMessage("keep this", to: "peer")
        let key = try XCTUnwrap(first.pendingMessages(for: "peer").first?.id)
        first.signOut()
        credentials.tokens[origin] = "test-token"
        let identity = identity
        StubProtocol.handler = { request in
            if request.url!.path == "/v1/agent/self" { return (200, identity) }
            return (200, #"{"peers":[]}"#)
        }
        let restored = model()
        restored.setAppActive(false)
        await restored.restoreSession()
        XCTAssertEqual(restored.pendingMessages(for: "peer").first?.id, key)
        XCTAssertTrue(restored.unconfirmedIDs.contains(key))
        XCTAssertEqual(restored.pendingMessages(for: "peer").first?.payload.text, "keep this")
        restored.signOut()
    }

    func testLateDirectoryCannotRepopulateSignedOutSession() async {
        let model = await connectedModel()
        let received = expectation(description: "Directory requested")
        let gate = DispatchSemaphore(value: 0)
        StubProtocol.handler = { _ in
            received.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return (200, #"{"peers":[{"mid":"peer","label":"Late","joined_at":1}]}"#)
        }
        let task = Task { await model.refreshPeers() }
        await fulfillment(of: [received], timeout: 2)
        model.signOut()
        gate.signal()
        await task.value
        XCTAssertNil(model.mailbox)
        XCTAssertTrue(model.peers.isEmpty)
    }

    func testRepeatedDirectoryCursorStopsWithoutLooping() async {
        let model = await connectedModel()
        var requests = 0
        StubProtocol.handler = { _ in
            requests += 1
            return (200, #"{"peers":[],"next_cursor":"again"}"#)
        }
        await model.refreshPeers()
        XCTAssertEqual(requests, 2)
        XCTAssertNotNil(model.mailboxConnectionWarning)
        model.signOut()
    }

    func testIncomingIDCannotCollideWithSentMessageID() async throws {
        let model = await connectedModel()
        StubProtocol.handler = { _ in (200, #"{"id":"1","ts":1}"#) }
        let sent = await model.sendMessage("outgoing", to: "peer")
        XCTAssertTrue(sent)
        StubProtocol.handler = { request in
            if request.url!.path == "/v1/agent/poll" {
                return (200, #"{"messages":[{"id":"1","from":"peer","payload":{"text":"incoming"},"ts":2}],"cursor":"1","has_more":false}"#)
            }
            return (200, #"{"peers":[]}"#)
        }
        model.setAppActive(true)
        let deadline = Date().addingTimeInterval(2)
        while model.conversations["peer"]?.count != 2 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.setAppActive(false)
        XCTAssertEqual(model.conversations["peer"]?.map(\.text), ["outgoing", "incoming"])
        XCTAssertEqual(Set(model.conversations["peer"]?.map(\.id) ?? []).count, 2)
        XCTAssertEqual(model.history.unread["peer"], 1)
        model.signOut()
    }

    func testSuccessfulHTTPWithoutMessageIDRemainsUnconfirmed() async {
        let model = await connectedModel()
        StubProtocol.handler = { _ in (200, "{}") }
        let sent = await model.sendMessage("keep pending", to: "peer")
        XCTAssertFalse(sent)
        XCTAssertEqual(model.pendingMessages(for: "peer").count, 1)
        XCTAssertNil(model.conversations["peer"])
        model.signOut()
    }

    func testOlderQueuedSnapshotCannotOverwriteANewerSave() async throws {
        var older = MailboxHistory()
        older.drafts["peer"] = "old"
        var newer = MailboxHistory()
        newer.drafts["peer"] = "new"
        try await store.save(newer, server: origin, mid: "m-test", revision: 2)
        try await store.save(older, server: origin, mid: "m-test", revision: 1)
        let loaded = try await store.load(server: origin, mid: "m-test")
        XCTAssertEqual(loaded?.drafts["peer"], "new")
    }

    func testCreatedMailboxTokenCanRecoverAfterKeychainWriteFailure() async {
        let model = model()
        model.setAppActive(false)
        credentials.shouldFailWrites = true
        StubProtocol.handler = { _ in (200, #"{"mid":"m-test","token":"recover-me"}"#) }
        await model.createMailbox(label: "Alice", joinSecret: "test-secret")
        XCTAssertNil(model.mailbox)
        XCTAssertNil(credentials.read(server: origin))
        XCTAssertNotNil(model.mailboxConnectionWarning)
        credentials.shouldFailWrites = false
        let identity = identity
        StubProtocol.handler = { request in
            if request.url!.path == "/v1/agent/self" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer recover-me")
                return (200, identity)
            }
            return (200, #"{"peers":[]}"#)
        }
        await model.restoreSession()
        XCTAssertEqual(model.mailbox?.mid, "m-test")
        XCTAssertEqual(credentials.read(server: origin), "recover-me")
        model.signOut()
    }

    func testLocalHTTPAcceptsPrivateLANAddressesAndRejectsPublicAddresses() {
        for host in ["10.0.0.2", "172.16.0.1", "172.31.255.254", "192.168.1.42", "169.254.1.2", "127.0.0.2", "[::1]", "[fd12:3456::1]", "[fe80::1]", "[::ffff:192.168.1.2]"] {
            XCTAssertNotNil(APIClient.validatedBaseURL("http://\(host):8788"), host)
        }
        for host in ["8.8.8.8", "172.15.1.1", "172.32.0.1", "192.169.0.1", "169.253.1.1", "10.example.com", "192.168.1.999", "[2001:4860:4860::8888]", "[::ffff:8.8.8.8]"] {
            XCTAssertNil(APIClient.validatedBaseURL("http://\(host):8788"), host)
        }
    }

    func testFaceIDCompletionWhileInactiveCopiesOnceWhenActive() async {
        var liveModel: AppModel?
        var copied: [String] = []
        let model = await connectedModel(authenticateTokenCopy: {
            liveModel?.setAppActive(false)
            return true
        }, writeTokenToClipboard: { token in copied.append(token); return true })
        liveModel = model
        model.setAppActive(true)
        await model.copyMailboxToken()
        XCTAssertTrue(copied.isEmpty)
        XCTAssertTrue(model.isCopyingMailboxToken)
        model.setAppActive(true)
        model.setAppActive(true)
        XCTAssertEqual(copied, ["test-token"])
        XCTAssertFalse(model.isCopyingMailboxToken)
        XCTAssertEqual(model.statusMessage, "Token copied for 2 minutes on this device.")
        model.signOut()
    }

    func testBackgroundingInvalidatesSuccessfulFaceIDBeforeCopy() async {
        let authenticating = expectation(description: "Authentication started")
        var continuation: CheckedContinuation<Bool, Never>?
        var copied: [String] = []
        let model = await connectedModel(authenticateTokenCopy: {
            await withCheckedContinuation { continuation = $0; authenticating.fulfill() }
        }, writeTokenToClipboard: { copied.append($0); return true })
        let task = Task { await model.copyMailboxToken() }
        await fulfillment(of: [authenticating], timeout: 2)
        model.setAppActive(false, isBackgrounded: true)
        model.setAppActive(true)
        continuation?.resume(returning: true)
        await task.value
        XCTAssertTrue(copied.isEmpty)
        XCTAssertFalse(model.isCopyingMailboxToken)
        model.signOut()
    }

    func testSignOutDuringFaceIDCannotCopyOldToken() async {
        let authenticating = expectation(description: "Authentication started")
        var continuation: CheckedContinuation<Bool, Never>?
        var copied: [String] = []
        let model = await connectedModel(authenticateTokenCopy: {
            await withCheckedContinuation { continuation = $0; authenticating.fulfill() }
        }, writeTokenToClipboard: { copied.append($0); return true })
        let task = Task { await model.copyMailboxToken() }
        await fulfillment(of: [authenticating], timeout: 2)
        model.signOut()
        continuation?.resume(returning: true)
        await task.value
        model.setAppActive(true)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertFalse(model.isCopyingMailboxToken)
    }

    func testClipboardFailureDoesNotClaimTokenWasCopied() async {
        let model = await connectedModel(authenticateTokenCopy: { true }, writeTokenToClipboard: { _ in false })
        model.setAppActive(true)
        await model.copyMailboxToken()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNotEqual(model.statusMessage, "Token copied for 2 minutes on this device.")
        XCTAssertFalse(model.isCopyingMailboxToken)
        model.signOut()
    }

    func testDeletingDepartedConversationPersistsWithoutDeletingMailboxOrOtherChats() async throws {
        var saved = MailboxHistory()
        saved.cursor = "25"
        saved.conversations["departed"] = [ChatMessage(id: "received-24", from: "departed", text: "Old note", timestamp: 1, type: "msg")]
        saved.conversations["other"] = [ChatMessage(id: "received-25", from: "other", text: "Keep me", timestamp: 2, type: "msg")]
        saved.drafts = ["departed": "discard draft", "other": "keep draft"]
        saved.unread = ["departed": 3, "other": 1]
        saved.pending = [PendingMessage(id: "unsent", peerID: "departed", payload: SendPayload(text: "pending"), timestamp: 3)]
        saved.threads["departed"] = "existing-thread"
        saved.sequences["departed"] = 4
        try await store.save(saved, server: origin, mid: "m-test")
        let model = await connectedModel()
        model.deleteConversation("departed")
        XCTAssertFalse(model.unconfirmedIDs.contains("unsent"))
        XCTAssertNil(model.conversations["departed"])
        XCTAssertEqual(model.draft(for: "departed"), "")
        XCTAssertTrue(model.pendingMessages(for: "departed").isEmpty)
        XCTAssertNil(model.history.unread["departed"])
        XCTAssertEqual(model.mailbox?.mid, "m-test")
        XCTAssertEqual(credentials.read(server: origin), "test-token")
        XCTAssertEqual(model.conversations["other"]?.first?.text, "Keep me")
        XCTAssertEqual(model.draft(for: "other"), "keep draft")
        XCTAssertEqual(model.history.unread["other"], 1)
        XCTAssertEqual(model.history.cursor, "25")
        XCTAssertEqual(model.history.threads["departed"], "existing-thread")
        XCTAssertEqual(model.history.sequences["departed"], 4)
        model.signOut()
        credentials.tokens[origin] = "test-token"
        await model.restoreSession()
        XCTAssertNil(model.conversations["departed"])
        XCTAssertTrue(model.pendingMessages(for: "departed").isEmpty)
        XCTAssertEqual(model.draft(for: "departed"), "")
        XCTAssertEqual(model.conversations["other"]?.first?.text, "Keep me")
        XCTAssertEqual(model.history.cursor, "25")
        let persisted = try await store.load(server: origin, mid: "m-test")
        XCTAssertNil(persisted?.conversations["departed"])
        XCTAssertNil(persisted?.drafts["departed"])
        model.signOut()
    }

    func testConversationCannotBeDeletedWhileSendIsInFlight() async {
        let model = await connectedModel()
        let received = expectation(description: "Send started")
        let gate = DispatchSemaphore(value: 0)
        StubProtocol.handler = { _ in
            received.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return (200, #"{"id":"accepted","ts":1}"#)
        }
        let task = Task { await model.sendMessage("keep until finished", to: "peer") }
        await fulfillment(of: [received], timeout: 2)
        XCTAssertFalse(model.canDeleteConversation("peer"))
        model.deleteConversation("peer")
        XCTAssertEqual(model.pendingMessages(for: "peer").count, 1)
        gate.signal()
        let sent = await task.value
        XCTAssertTrue(sent)
        XCTAssertTrue(model.canDeleteConversation("peer"))
        model.deleteConversation("peer")
        XCTAssertNil(model.conversations["peer"])
        XCTAssertEqual(model.mailbox?.mid, "m-test")
        model.signOut()
    }

}
