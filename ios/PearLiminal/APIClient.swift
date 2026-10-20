import Foundation
import OSLog
import Darwin

struct APIClient {
    static let productionURL = URL(string: "https://agent-messaging.charcoal.workers.dev")!

    let baseURL: URL
    private let session: URLSession

    private static let secureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pearliminal.ios",
        category: "API"
    )

    init(baseURL: URL = APIClient.productionURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.session = session ?? Self.secureSession
    }

    /// Credentials belong to an origin, never a path, query, or user-info URL.
    static func validatedBaseURL(_ value: String) -> URL? {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(),
              !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        let local = isLocalHost(host)
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        parts.scheme = scheme
        parts.host = host
        parts.path = ""
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        return parts.url
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let address = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 {
            let bytes = parts.compactMap { UInt8($0) }
            if bytes.count == 4 && zip(parts, bytes).allSatisfy({ String($0.0) == String($0.1) }) {
                return isPrivateIPv4(bytes)
            }
        }
        // Parse IPv6 numerically rather than accepting a private-looking string prefix.
        let literal = String(address.split(separator: "%", maxSplits: 1).first ?? "")
        var ipv6 = in6_addr()
        guard literal.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return false }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        if bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) { return true }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return isPrivateIPv4(Array(bytes.suffix(4)))
        }
        return false
    }

    private static func isPrivateIPv4(_ bytes: [UInt8]) -> Bool {
        bytes[0] == 10 || bytes[0] == 127
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 169 && bytes[1] == 254)
    }

    func get<T: Decodable>(_ path: String, token: String? = nil, adminSecret: String? = nil) async throws -> T {
        try await send(path, method: "GET", token: token, adminSecret: adminSecret)
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        token: String? = nil,
        adminSecret: String? = nil,
        idempotencyKey: String? = nil
    ) async throws -> Response {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return try await send(
            path,
            method: "POST",
            token: token,
            adminSecret: adminSecret,
            body: try encoder.encode(body),
            idempotencyKey: idempotencyKey
        )
    }

    func delete<T: Decodable>(_ path: String, adminSecret: String) async throws -> T {
        try await send(path, method: "DELETE", adminSecret: adminSecret)
    }

    func getText(_ path: String, adminSecret: String? = nil) async throws -> String {
        let (data, _) = try await perform(path, method: "GET", adminSecret: adminSecret)
        return String(decoding: data, as: UTF8.self)
    }

    func postText<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        adminSecret: String
    ) async throws -> Response {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return try await send(path, method: "POST", adminSecret: adminSecret, body: try encoder.encode(body))
    }

    private func send<T: Decodable>(
        _ path: String,
        method: String,
        token: String? = nil,
        adminSecret: String? = nil,
        body: Data? = nil,
        idempotencyKey: String? = nil
    ) async throws -> T {
        let (data, _) = try await perform(
            path,
            method: method,
            token: token,
            adminSecret: adminSecret,
            body: body,
            idempotencyKey: idempotencyKey
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError(statusCode: nil, message: "The server returned an unexpected response.")
        }
    }

    private func perform(
        _ path: String,
        method: String,
        token: String? = nil,
        adminSecret: String? = nil,
        body: Data? = nil,
        idempotencyKey: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard path.hasPrefix("/v1/"), let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port else {
            throw APIError(statusCode: nil, message: "The API address is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let adminSecret { request.setValue(adminSecret, forHTTPHeaderField: "X-Admin-Secret") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }

        let startedAt = Date()
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                logger.error("\(method, privacy: .public) request returned a non-HTTP response.")
                throw APIError(statusCode: nil, message: "The server returned an invalid response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data)
                let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                logger.error("\(method, privacy: .public) request to \(url.path, privacy: .private) failed with HTTP \(http.statusCode, privacy: .public) in \(elapsedMilliseconds, privacy: .public) ms.")
                throw APIError(statusCode: http.statusCode, message: payload?.error ?? "Request failed (HTTP \(http.statusCode)).")
            }
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            logger.debug("\(method, privacy: .public) request to \(url.path, privacy: .private) succeeded with HTTP \(http.statusCode, privacy: .public) in \(elapsedMilliseconds, privacy: .public) ms.")
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as APIError {
            throw error
        } catch {
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            logger.error("\(method, privacy: .public) request to \(url.path, privacy: .private) failed after \(elapsedMilliseconds, privacy: .public) ms: \(error.localizedDescription, privacy: .private)")
            throw APIError(statusCode: nil, message: error.localizedDescription)
        }
    }
}

struct APIError: LocalizedError {
    let statusCode: Int?
    let message: String
    var errorDescription: String? { message }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct ErrorPayload: Decodable {
    let error: String
}

struct JoinRequest: Encodable {
    let label: String
    let joinSecret: String
}

struct JoinResponse: Decodable {
    let mid: String
    let token: String
}

struct EmptyRequest: Encodable {}

struct EmptyResponse: Decodable {
    let ok: Bool
    let version: Int?
    let mid: String?
}

struct SelfMailbox: Decodable, Identifiable {
    let mid: String
    let label: String
    let capabilities: [String]
    let createdAt: Int64
    let messageCount: Int
    let messageBytes: Int
    var id: String { mid }
}

struct Peer: Decodable, Identifiable {
    let mid: String
    let label: String
    let joinedAt: Int64
    let capabilities: [String]?
    var id: String { mid }
}

struct PeerPage: Decodable {
    let peers: [Peer]
    let nextCursor: String?
}

struct PollPage: Decodable {
    let messages: [InboxMessage]
    let cursor: String?
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case messages
        case cursor
        case hasMore
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        messages = try values.decodeIfPresent([InboxMessage].self, forKey: .messages) ?? []
        hasMore = try values.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false

        if let value = try? values.decode(String.self, forKey: .cursor) {
            cursor = value
        } else if let value = try? values.decode(Int64.self, forKey: .cursor) {
            cursor = String(value)
        } else if let value = try? values.decode(Double.self, forKey: .cursor), value.isFinite, let integer = Int64(exactly: value) {
            cursor = String(integer)
        } else {
            cursor = nil
        }
    }
}

struct InboxMessage: Decodable, Identifiable {
    let id: String
    let from: String
    let payload: MessagePayload
    let ts: Int64

    private enum CodingKeys: String, CodingKey { case id, from, payload, ts }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        from = try values.decode(String.self, forKey: .from)
        ts = try values.decode(Int64.self, forKey: .ts)
        payload = (try? values.decode(MessagePayload.self, forKey: .payload)) ?? MessagePayload(text: nil, type: nil, thread: nil)
    }
}

struct MessagePayload: Decodable {
    let text: String?
    let type: String?
    let thread: String?
}

struct SendRequest: Codable {
    let to: String
    let payload: SendPayload
}

struct SendPayload: Codable {
    let text: String
    var type = "msg"
    var thread: String? = nil
    var seq: Int? = nil
}

struct SendResponse: Decodable {
    let id: String
    let ts: Int64?
    let duplicate: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case messageId
        case ts
        case duplicate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = (try? values.decode(String.self, forKey: .id))
            ?? (try? values.decode(String.self, forKey: .messageId)), !value.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: values, debugDescription: "Missing accepted message ID")
        }
        id = value
        duplicate = try? values.decode(Bool.self, forKey: .duplicate)

        if let value = try? values.decode(Int64.self, forKey: .ts) {
            ts = value
        } else if let value = try? values.decode(Double.self, forKey: .ts), value.isFinite, let integer = Int64(exactly: value) {
            ts = integer
        } else if let value = try? values.decode(String.self, forKey: .ts), let parsed = Int64(value) {
            ts = parsed
        } else {
            ts = nil
        }
    }
}

struct AdminPeerPage: Decodable {
    let agents: [Peer]
    let nextCursor: String?
}

struct AdminAgent: Decodable, Identifiable {
    let mid: String
    let label: String
    let capabilities: [String]
    let createdAt: Int64
    let active: Bool
    let messageCount: Int
    let messageBytes: Int
    var id: String { mid }
}

struct Capability: Codable, Identifiable {
    let name: String
    var description: String
    var id: String { name }
}

struct CapabilityRegistry: Decodable {
    let version: Int
    let capabilities: [Capability]
}

struct CapabilitiesUpdate: Encodable {
    let capabilities: [Capability]
}

struct MarkdownUpdate: Encodable {
    let markdown: String
}

struct ClientUpdate: Encodable {
    let source: String
}

struct AgentDeleteResponse: Decodable {
    let ok: Bool
}
