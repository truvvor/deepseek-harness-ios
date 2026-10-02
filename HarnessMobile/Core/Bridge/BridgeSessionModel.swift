import Foundation

/// Provenance marker for a session this app imported from the DeepSeek Harness
/// desktop bridge.
///
/// A mirrored session is **read-only on this device**: it exists so the user can
/// read desktop work in the app, and the local agent loop must never run for it.
/// Otherwise the app would append its own turns to a projection of another
/// host's canonical log and the two histories would diverge. See `DECISIONS.md`
/// D-012.
///
/// The field is optional on `ConversationSession`, so snapshot version 4 stays
/// valid both ways: an older snapshot decodes with `nil`, and a snapshot written
/// by a build that knows mirrors still decodes in an older build because
/// `Codable` ignores unknown keys for a non-strict decoder.
struct BridgeSessionMirror: Codable, Sendable, Equatable {
    /// Desktop session id exactly as the bridge reported it, e.g. `session-<uuid>`.
    let bridgeSessionID: String
    /// When this app last pulled the desktop log for this mirror.
    let importedAt: Date

    init(bridgeSessionID: String, importedAt: Date = .now) {
        self.bridgeSessionID = bridgeSessionID
        self.importedAt = importedAt
    }
}

/// Durable `localUUID ↔ bridgeSessionId` correspondence plus the incremental
/// follow position.
///
/// Two sequence numbers are tracked on purpose and they are **not
/// interchangeable**:
/// - `importedThroughBridgeSeq` is the last sequence number of the *desktop*
///   log that this device has ingested. `/stream?since=` needs that number.
/// - the local trajectory keeps its own dense sequence numbering, so admission
///   through `SessionTrajectoryRepository.admitSyncEnvelope` uses local
///   sequences.
///
/// They coincide while the desktop log is dense from seq 0 (the normal case,
/// which the converter preserves verbatim); the converter only renumbers when
/// the desktop log is sparse, and that is exactly when the two diverge.
struct BridgeSessionMapping: Codable, Sendable, Equatable {
    let bridgeSessionID: String
    let localSessionID: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var importedThroughBridgeSeq: Int64
    var importedEventCount: Int

    var mirror: BridgeSessionMirror {
        BridgeSessionMirror(bridgeSessionID: bridgeSessionID, importedAt: updatedAt)
    }
}

enum BridgeSessionMappingError: Error, LocalizedError, Sendable, Equatable {
    case unreadableStore
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unreadableStore:
            return "The desktop mirror map could not be read."
        case let .unsupportedVersion(version):
            return "Unsupported desktop mirror map version \(version)."
        }
    }
}

/// One desktop session as `/bridge/v1/sessions` reports it.
struct BridgeSessionListEntry: Decodable, Sendable, Equatable, Identifiable {
    let sessionID: String
    let title: String?
    let updatedAt: Int64?
    let running: Bool?
    let blank: Bool?
    let archived: Bool?
    let cwd: String?
    let parentSessionID: String?
    let origin: String?

    var id: String { sessionID }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case title, updatedAt, running, blank, archived, cwd, origin
        case parentSessionID = "parentSessionId"
    }

    var isArchived: Bool { archived == true }

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? sessionID : trimmed
    }
}

/// `GET /bridge/v1/sessions` envelope (`{object: "list", data: [...]}`).
struct BridgeSessionListResponse: Decodable, Sendable, Equatable {
    let object: String?
    let data: [BridgeSessionListEntry]
}

struct BridgeSessionHealth: Decodable, Sendable, Equatable {
    let status: String?
    let ok: Bool?
    let build: String?
    let services: [String: JSONValue]?

    init(status: String?, ok: Bool? = nil, build: String?, services: [String: JSONValue]?) {
        self.status = status
        self.ok = ok
        self.build = build
        self.services = services
    }

    var isHealthy: Bool { status?.lowercased() == "ok" || ok == true }

    /// What the settings probe shows. A decoded `/health` answer already proves
    /// the bridge is reachable and the token accepted, so a body without a
    /// `status` field reads as reachable rather than unavailable.
    var displayStatus: String {
        if let status, !status.isEmpty { return status }
        if let ok { return ok ? "ok" : "degraded" }
        return "reachable"
    }
}

/// `POST /bridge/v1/sessions/{id}/prompt` mode: `queue` waits behind a running
/// desktop turn, `steer` injects into it.
enum BridgePromptMode: String, Codable, Sendable {
    case queue
    case steer
}

struct BridgePromptRequest: Encodable, Sendable {
    let text: String
    let mode: BridgePromptMode
}

/// `POST /bridge/v1/sessions/{id}/prompt` answer, sent after `turn/end`.
struct BridgePromptResult: Decodable, Sendable, Equatable {
    let sessionID: String?
    let text: String?
    let usage: JSONValue?
    let completed: Bool?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case text, usage, completed
    }
}

/// `{ "error": { "message", "code", ... } }` returned by bridge routes.
struct BridgeErrorEnvelope: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        let message: String?
        let code: String?
    }

    let error: Detail
}

/// `GET /bridge/v1/sessions/{id}/messages` envelope.
struct BridgeMessagePage: Decodable, Sendable, Equatable {
    /// Plain history rows mapped by the bridge (`user`/`assistant`/optional `tool`).
    struct Message: Decodable, Sendable, Equatable, Identifiable {
        let role: String
        let content: String
        let seq: UInt64?
        let time: Int64?
        let model: String?
        let provider: String?
        let usage: JSONValue?
        let isError: Bool?

        var id: String { "\(seq ?? 0)-\(role)" }
    }

    let sessionID: String
    let throughSeq: Int64?
    let hasMore: Bool?
    let messages: [Message]

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case throughSeq, hasMore, messages
    }
}

/// Header line of the canonical v4 session export (`{"type":"session",...}`).
struct BridgeSessionLogHeader: Decodable, Sendable, Equatable {
    let id: String
    let version: Int?
    let createdAt: Int64?
    let cwd: String?
    let parentSession: String?
    let agentPreset: String?
    let origin: String?
    let delegationDepth: Int?
    let isSeeded: Bool?

    /// The desktop prefix is `session-<uuid>`; the app stores a bare UUID.
    var sessionUUID: UUID? {
        let raw = id.hasPrefix("session-") ? String(id.dropFirst("session-".count)) : id
        return UUID(uuidString: raw)
    }
}

/// A live SSE frame from `GET /bridge/v1/sessions/{id}/stream`.
///
/// Only the frame kinds the desktop bridge actually emits are modelled. An
/// unrecognized frame decodes to `.unknown` instead of failing the stream: a
/// newer bridge must not tear down an otherwise healthy mirror.
struct BridgeStreamFrame: Decodable, Sendable, Equatable {
    let type: String
    let sessionID: String?
    let throughSeq: Int64?
    let seq: UInt64?
    let time: Int64?
    let eventType: String?
    let role: String?
    let content: String?
    let reason: String?
    let text: String?
    let usage: JSONValue?
    let messages: [BridgeMessagePage.Message]?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "sessionId"
        case throughSeq, seq, time, eventType, role, content, reason, text, usage, messages, message
    }

    var kind: Kind {
        switch type {
        case "snapshot": return .snapshot
        case "event": return .event
        case "delta": return .delta
        case "reasoning": return .reasoning
        case "usage": return .usage
        case "turn/end": return .turnEnd
        case "closed": return .closed
        case "error": return .error
        default: return .unknown(type)
        }
    }

    enum Kind: Sendable, Equatable {
        case snapshot
        case event
        case delta
        case reasoning
        case usage
        case turnEnd
        case closed
        case error
        case unknown(String)
    }
}

/// One `GET …/export?since=` answer.
struct BridgeExportPage: Sendable, Equatable {
    let data: Data
    /// Echo of `x-dsh-since`; `nil` when the bridge ignored `since` and sent
    /// the full log.
    let since: Int64?
    /// `x-dsh-through-seq`: the desktop head this page reaches.
    let throughSeq: Int64?

    var isIncremental: Bool { since != nil }
}
