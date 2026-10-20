import XCTest
@testable import PearLiminalCore

@MainActor private final class SimulationCredentials: MailboxCredentials {
    private var tokens: [URL: String] = [:]
    func read(server: URL) -> String? { tokens[server] }
    func write(_ token: String, server: URL) { tokens[server] = token }
    func delete(server: URL) { tokens[server] = nil }
}

@MainActor final class SimulationTests: XCTestCase {
    func testRealHTTPAmbiguousSendAndIdempotentRetry() async throws {
        guard let address = ProcessInfo.processInfo.environment["PEAR_SIMULATION_URL"],
              let url = APIClient.validatedBaseURL(address), url.host == "127.0.0.1" else {
            throw XCTSkip("Start postman/simulations/ios.sim.yaml and set PEAR_SIMULATION_URL to its loopback origin.")
        }
        let client = APIClient(baseURL: url)
        let _: EmptyResponse = try await client.post("/v1/simulation/reset", body: EmptyRequest(), token: "simulation-only")
        let suite = "PearSimulation.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let store = MailboxStore(directory: directory)
        let model = AppModel(api: APIClient(baseURL: url), defaults: defaults, store: store, credentials: SimulationCredentials())
        defer {
            model.setAppActive(false)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        model.setAppActive(false)
        await model.reconnect(token: "simulation-only")
        let peer = try XCTUnwrap(model.peers.first)
        XCTAssertEqual(model.mailbox?.label, "Local test")
        let sent = await model.sendMessage("Local HTTP regression", to: peer.mid)
        XCTAssertFalse(sent, "The simulation fails the first response after accepting the send")
        let pending = try XCTUnwrap(model.pendingMessages(for: peer.mid).first)
        await model.retryMessage(pending)
        XCTAssertTrue(model.pendingMessages(for: peer.mid).isEmpty)
        XCTAssertEqual(model.conversations[peer.mid]?.count, 1)
        XCTAssertEqual(model.conversations[peer.mid]?.first?.id, "sent-\(peer.mid)-1")
        let another = await model.sendMessage("Next sequence", to: peer.mid)
        XCTAssertTrue(another)
        XCTAssertEqual(model.conversations[peer.mid]?.count, 2)
        XCTAssertEqual(model.history.sequences[peer.mid], 2)
        try await store.save(model.history, server: url, mid: XCTUnwrap(model.mailbox?.mid))
        do {
            let _: EmptyResponse = try await client.get("/v1/simulation/redirect", token: "simulation-only")
            XCTFail("Credential-bearing requests must not follow redirects")
        } catch let error as APIError { XCTAssertEqual(error.statusCode, 302) }
        do {
            let _: EmptyResponse = try await client.get("/v1/simulation/html-error", token: "simulation-only")
            XCTFail("Expected proxy error")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 500)
            XCTAssertEqual(error.message, "Request failed (HTTP 500).")
        }
    }
}
