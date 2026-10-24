import CryptoKit
import Foundation

struct PendingMessage: Codable, Identifiable {
    let id: String
    let peerID: String
    let payload: SendPayload
    let timestamp: Int64
}

struct ClosedStreamRecord: Codable, Equatable {
    let peerStatus: String
    let peerStatusAt: Int64?
    let lastSeq: Int64
}

struct MailboxHistory: Codable {
    var cursor = "0"
    var conversations: [String: [ChatMessage]] = [:]
    var pending: [PendingMessage] = []
    var drafts: [String: String] = [:]
    var threads: [String: String] = [:]
    var unread: [String: Int] = [:]
    var sequences: [String: Int] = [:]
    var streamCursors: [String: Int64] = [:]
    var closedStreams: [String: ClosedStreamRecord] = [:]

    private enum CodingKeys: String, CodingKey {
        case cursor, conversations, pending, drafts, threads, unread, sequences, streamCursors, closedStreams
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try values.decodeIfPresent(String.self, forKey: .cursor) ?? "0"
        conversations = try values.decodeIfPresent([String: [ChatMessage]].self, forKey: .conversations) ?? [:]
        pending = try values.decodeIfPresent([PendingMessage].self, forKey: .pending) ?? []
        drafts = try values.decodeIfPresent([String: String].self, forKey: .drafts) ?? [:]
        threads = try values.decodeIfPresent([String: String].self, forKey: .threads) ?? [:]
        unread = try values.decodeIfPresent([String: Int].self, forKey: .unread) ?? [:]
        sequences = try values.decodeIfPresent([String: Int].self, forKey: .sequences) ?? [:]
        streamCursors = try values.decodeIfPresent([String: Int64].self, forKey: .streamCursors) ?? [:]
        closedStreams = try values.decodeIfPresent([String: ClosedStreamRecord].self, forKey: .closedStreams) ?? [:]
    }
}

/// Serializes disk work away from the main actor. No credentials are written here.
actor MailboxStore {
    private let directory: URL
    private var latestWrites: [URL: UInt64] = [:]

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("MailboxHistory", isDirectory: true)
    }

    private func file(server: URL, mid: String) -> URL {
        let digest = SHA256.hash(data: Data("\(server.absoluteString)|\(mid)".utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined()).appendingPathExtension("json")
    }

    func load(server: URL, mid: String) throws -> MailboxHistory? {
        let url = file(server: server, mid: mid)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(MailboxHistory.self, from: Data(contentsOf: url))
    }

    func save(_ history: MailboxHistory, server: URL, mid: String, revision: UInt64 = DispatchTime.now().uptimeNanoseconds) throws {
        let destination = file(server: server, mid: mid)
        guard revision >= latestWrites[destination, default: 0] else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = file(server: server, mid: mid)
        try JSONEncoder().encode(history).write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        latestWrites[destination] = revision
    }

    func delete(server: URL, mid: String) throws {
        let url = file(server: server, mid: mid)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        latestWrites[url] = DispatchTime.now().uptimeNanoseconds
    }
}
