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
    /// Messages in the full mirrored transcript. The session itself keeps only
    /// the newest `BridgeMirrorTranscriptStore.sessionTailLimit` of them; the
    /// rest are paged in from the transcript store while scrolling. `nil` for
    /// a mirror written before the transcript store existed.
    var transcriptMessageCount: Int?
    /// A question the desktop agent asked and nobody has answered yet
    /// (`question/requested` without a matching `question/resolved`).
    var pendingQuestion: BridgeDesktopQuestion?

    init(
        bridgeSessionID: String,
        importedAt: Date = .now,
        transcriptMessageCount: Int? = nil,
        pendingQuestion: BridgeDesktopQuestion? = nil
    ) {
        self.bridgeSessionID = bridgeSessionID
        self.importedAt = importedAt
        self.transcriptMessageCount = transcriptMessageCount
        self.pendingQuestion = pendingQuestion
    }
}

/// One item of a desktop `question/requested` event. Options are kept when
/// the desktop log carries them; a log that only reports `optionCount`
/// yields an item answered as free text.
struct BridgeDesktopQuestionItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let question: String
    let header: String?
    let multiSelect: Bool
    let options: [String]
}

/// A question the desktop agent is waiting on (D-014: answered through the
/// bridge, the desktop resolves it).
struct BridgeDesktopQuestion: Codable, Sendable, Equatable, Identifiable {
    let requestID: String
    let questions: [BridgeDesktopQuestionItem]
    let askedAt: Int64

    var id: String { requestID }

    /// The desktop asks through the `ask_user_question` tool, so the question
    /// is a `tool/call` event and its request id is the `callId`; the answer
    /// lands as the matching `tool/result`. `question/requested` (the app's
    /// own event) is accepted too, with `requestId` or `id`.
    static let questionToolNames: Set<String> = ["ask_user_question", "AskUserQuestion"]

    static func parse(_ event: SessionEvent) -> BridgeDesktopQuestion? {
        guard let object = event.data.objectValue else { return nil }
        switch event.type {
        case SessionEventVocabulary.toolCall:
            guard let name = object["name"]?.stringValue, questionToolNames.contains(name),
                  let callID = object["callId"]?.stringValue ?? object["callID"]?.stringValue,
                  let rawArguments = object["arguments"] else { return nil }
            let arguments: [String: JSONValue]
            if let text = rawArguments.stringValue {
                guard let data = text.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
                      let decodedObject = decoded.objectValue else { return nil }
                arguments = decodedObject
            } else if let decodedObject = rawArguments.objectValue {
                arguments = decodedObject
            } else {
                return nil
            }
            return parse(requestID: callID, object: arguments, time: event.time)
        case SessionEventVocabulary.questionRequested:
            guard let requestID = object["requestId"]?.stringValue ?? object["id"]?.stringValue else {
                return nil
            }
            return parse(requestID: requestID, object: object, time: event.time)
        default:
            return nil
        }
    }

    /// Reads the upstream `AskUserQuestion` request shape: `questions[]` with
    /// `question` (or `text`), `header`, `multi_select` (or `multiSelect`) and
    /// `options` as strings or `{label, description}` objects.
    static func parse(requestID: String, object: [String: JSONValue], time: Int64) -> BridgeDesktopQuestion? {
        var rawItems: [JSONValue] = []
        if case let .array(values)? = object["questions"] { rawItems = values }
        var items: [BridgeDesktopQuestionItem] = []
        for (index, raw) in rawItems.enumerated() {
            guard let item = raw.objectValue else { continue }
            let text = item["question"]?.stringValue ?? item["text"]?.stringValue ?? ""
            guard !text.isEmpty else { continue }
            var rawOptions: [JSONValue] = []
            if case let .array(values)? = item["options"] { rawOptions = values }
            let options = rawOptions.compactMap { option -> String? in
                option.stringValue ?? option.objectValue?["label"]?.stringValue
            }
            let multiSelect = item["multi_select"]?.booleanValue
                ?? item["multiSelect"]?.booleanValue
                ?? false
            items.append(
                BridgeDesktopQuestionItem(
                    id: item["id"]?.stringValue ?? "q\(index)",
                    question: text,
                    header: item["header"]?.stringValue,
                    multiSelect: multiSelect,
                    options: options
                )
            )
        }
        if items.isEmpty, let text = object["question"]?.stringValue, !text.isEmpty {
            items = [BridgeDesktopQuestionItem(id: requestID, question: text, header: nil, multiSelect: false, options: [])]
        }
        guard !items.isEmpty else { return nil }
        return BridgeDesktopQuestion(requestID: requestID, questions: items, askedAt: time)
    }

    /// The request id an event closes: the `tool/result` of the question's
    /// tool call (`message.toolCallId`, `message.callId`, `meta.callId`) or a
    /// `question/resolved` event.
    static func resolvedRequestID(_ event: SessionEvent) -> String? {
        guard let object = event.data.objectValue else { return nil }
        switch event.type {
        case SessionEventVocabulary.toolResult:
            let message = object["message"]?.objectValue
            return message?["toolCallId"]?.stringValue
                ?? message?["callId"]?.stringValue
                ?? message?["source"]?.objectValue?["callId"]?.stringValue
                ?? object["meta"]?.objectValue?["callId"]?.stringValue
                ?? object["callId"]?.stringValue
        case SessionEventVocabulary.questionResolved:
            return object["requestId"]?.stringValue ?? object["id"]?.stringValue
        default:
            return nil
        }
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

/// One entry of `GET /bridge/v1/sessions/{id}/files?path=`: a file or
/// directory inside the desktop session's workspace.
struct BridgeFileEntry: Decodable, Sendable, Equatable, Identifiable {
    let name: String
    let type: String
    let size: Int64?
    let modifiedAt: Int64?

    var id: String { name }
    var isDirectory: Bool { type == "dir" || type == "directory" }
    var isSymlink: Bool { type == "symlink" }

    init(name: String, type: String, size: Int64? = nil, modifiedAt: Int64? = nil) {
        self.name = name
        self.type = type
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

/// A directory listing of the desktop workspace. `path` is relative to the
/// workspace root ("" for the root itself); `root` is the desktop's absolute
/// path, shown for orientation only.
struct BridgeDirectoryListing: Decodable, Sendable, Equatable {
    let root: String?
    let path: String
    let entries: [BridgeFileEntry]

    init(root: String?, path: String, entries: [BridgeFileEntry]) {
        self.root = root
        self.path = path
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case root, path, entries }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decodeIfPresent(String.self, forKey: .root)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        entries = try container.decodeIfPresent([BridgeFileEntry].self, forKey: .entries) ?? []
    }
}

/// Bytes of one workspace file read through `GET …/files/raw?path=`.
struct BridgeFileContent: Sendable, Equatable {
    let path: String
    let data: Data
    let mimeType: String?
    /// The bridge cut the file at the requested limit.
    let truncated: Bool
    /// Full size on the desktop when the bridge reports it.
    let totalBytes: Int64?

    var isImage: Bool { mimeType?.hasPrefix("image/") == true }

    /// UTF-8 text when the bytes decode as such and hold no NUL byte.
    var text: String? {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
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
    /// Bridge 0.2: `tool/call` event frames name the tool and its call id.
    let toolName: String?
    let callId: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "sessionId"
        case throughSeq, seq, time, eventType, role, content, reason, text, usage, messages, message
        case toolName, callId
    }

    var kind: Kind {
        switch type {
        case "snapshot": return .snapshot
        case "event": return .event
        case "delta": return .delta
        case "reasoning": return .reasoning
        case "usage": return .usage
        case "turn/end": return .turnEnd
        case "question": return .question
        case "question-resolved": return .questionResolved
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
        /// Bridge 0.2: the desktop agent asked a question (`ask_user_question`).
        case question
        /// Bridge 0.2: a question was answered (from either side).
        case questionResolved
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
    /// `x-dsh-through-seq`: the last sequence in this page, or the echoed
    /// `since` when the page is empty, so the cursor never moves backwards.
    let throughSeq: Int64?
    /// `x-dsh-head-seq`: the real end of the desktop log (paged bridges).
    var headSeq: Int64? = nil
    /// `x-dsh-has-more`: more events follow this page.
    var hasMore = false

    var isIncremental: Bool { since != nil }

    /// The desktop log end this page reveals. A rolled-back log shows up as a
    /// head behind the mirror's cursor.
    var desktopHead: Int64? { headSeq ?? throughSeq }
}
