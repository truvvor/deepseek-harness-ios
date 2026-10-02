import Foundation

/// Progress of a desktop-session import, in terms the UI can show directly.
struct BridgeImportProgress: Sendable, Equatable {
    let completed: Int
    let total: Int
    let currentTitle: String?

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
}

enum BridgeImportOutcome: Sendable, Equatable {
    /// A new local mirror session was created (and is now selectable).
    case created(localSessionID: UUID)
    /// An already-mapped mirror was refreshed with the desktop suffix.
    case refreshed(localSessionID: UUID, appendedEvents: Int)
    /// The mirror already held every desktop event.
    case unchanged(localSessionID: UUID)

    var localSessionID: UUID {
        switch self {
        case let .created(id), let .refreshed(id, _), let .unchanged(id): return id
        }
    }
}

enum BridgeImportError: Error, LocalizedError, Sendable, Equatable {
    case notMirrorable(String)
    case trajectoryHasAssetsOrTombstones
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case let .notMirrorable(reason):
            return "This desktop session cannot be mirrored: \(reason)"
        case .trajectoryHasAssetsOrTombstones:
            return "Desktop events reference attachments this app cannot mirror yet."
        case let .rollbackFailed(reason):
            return "The interrupted desktop import was rolled back only partially: \(reason)"
        }
    }
}

/// Imports a desktop DeepSeek Harness session into the app as a read-only
/// mirror.
///
/// Write path, all reused rather than reinvented:
/// 1. `SessionTrajectoryRepository.admitSyncEnvelope` (the audited append-only
///    admission seam) for the events, in `HarnessSyncEnvelope.maximumEvents`
///    chunks;
/// 2. `SessionStore.createSession` for the identity, then
///    `SessionStore.checkpointSession` for the visible snapshot, because
///    `createSession` starts empty;
/// 3. `SessionStore.renameSession` for the desktop title, so the app's automatic
///    titling cannot overwrite it on the next local turn (there is no local turn
///    for a mirror anyway);
/// 4. `SessionQueryReadModel.refresh` for the search projection.
///
/// A mirror never starts the local agent loop: see `BridgeSessionMirror` and the
/// send gate in `AppModel`.
actor BridgeSessionImporter {
    /// Matches `HarnessSyncEnvelope.maximumEvents`; admission is fail-closed on
    /// anything larger.
    static let maximumEventsPerEnvelope = HarnessSyncEnvelope.maximumEvents

    private let client: BridgeClient
    private let sessionStore: SessionStore
    private let trajectory: SessionTrajectoryRepository
    private let queryModel: SessionQueryReadModel?
    private let mappings: BridgeSessionMirrorStore

    init(
        client: BridgeClient,
        sessionStore: SessionStore,
        trajectory: SessionTrajectoryRepository,
        queryModel: SessionQueryReadModel?,
        mappings: BridgeSessionMirrorStore
    ) {
        self.client = client
        self.sessionStore = sessionStore
        self.trajectory = trajectory
        self.queryModel = queryModel
        self.mappings = mappings
    }

    /// Imports (or refreshes) every listed desktop session.
    ///
    /// A per-session failure is reported through `failures` and does not abort
    /// the remaining sessions, so one unmappable session cannot block the rest.
    func importSessions(
        _ entries: [BridgeSessionListEntry],
        progress: @Sendable (BridgeImportProgress) async -> Void = { _ in }
    ) async -> (outcomes: [BridgeImportOutcome], failures: [String: String]) {
        var outcomes: [BridgeImportOutcome] = []
        var failures: [String: String] = [:]
        let ordered = entries.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }

        for (index, entry) in ordered.enumerated() {
            await progress(
                BridgeImportProgress(
                    completed: index,
                    total: ordered.count,
                    currentTitle: entry.displayTitle
                )
            )
            do {
                outcomes.append(try await importSession(entry))
            } catch {
                failures[entry.sessionID] = error.localizedDescription
            }
        }
        await progress(
            BridgeImportProgress(completed: ordered.count, total: ordered.count, currentTitle: nil)
        )
        return (outcomes, failures)
    }

    @discardableResult
    func importSession(_ entry: BridgeSessionListEntry) async throws -> BridgeImportOutcome {
        let log = try await client.exportLog(sessionID: entry.sessionID)
        let report = try BridgeSessionEventConverter.decodeLog(log)
        return try await importConverted(
            bridgeSessionID: entry.sessionID,
            listTitle: entry.title,
            header: report.header,
            events: report.events,
            lastBridgeSequence: report.lastBridgeSequence
        )
    }

    /// Applies an already-converted desktop log. Split out so the conversion and
    /// the write path can each be exercised without a live bridge.
    @discardableResult
    func importConverted(
        bridgeSessionID: String,
        listTitle: String?,
        header: BridgeSessionLogHeader?,
        events: [SessionEvent],
        lastBridgeSequence: Int64
    ) async throws -> BridgeImportOutcome {
        let existing = try await mappings.mapping(bridgeSessionID: bridgeSessionID)
        let localSessionID = existing?.localSessionID ?? UUID()
        let isNew = existing == nil

        var createdLocalSession = false
        do {
            if isNew {
                _ = try await sessionStore.createSession(
                    id: localSessionID,
                    title: Self.provisionalTitle(
                        events: events,
                        listTitle: listTitle,
                        header: header,
                        bridgeSessionID: bridgeSessionID
                    ),
                    bridgeMirror: BridgeSessionMirror(bridgeSessionID: bridgeSessionID),
                    makeActive: false
                )
                createdLocalSession = true
            }

            let appended = try await admit(events, sessionID: localSessionID)
            try await refreshDerivedState(
                sessionID: localSessionID,
                events: events,
                header: header,
                listTitle: listTitle,
                bridgeSessionID: bridgeSessionID,
                titleIsFinal: !isNew
            )
            try await mappings.record(
                BridgeSessionMapping(
                    bridgeSessionID: bridgeSessionID,
                    localSessionID: localSessionID,
                    title: Self.resolvedTitle(
                        events: events,
                        listTitle: listTitle,
                        header: header,
                        bridgeSessionID: bridgeSessionID
                    ) ?? "Desktop Session",
                    createdAt: existing?.createdAt ?? .now,
                    updatedAt: .now,
                    importedThroughBridgeSeq: lastBridgeSequence,
                    importedEventCount: events.count
                )
            )

            if isNew {
                return .created(localSessionID: localSessionID)
            }
            return appended.isEmpty
                ? .unchanged(localSessionID: localSessionID)
                : .refreshed(localSessionID: localSessionID, appendedEvents: appended.count)
        } catch {
            if createdLocalSession {
                try? await trajectory.delete(sessionID: localSessionID)
                await rollbackLocalSession(localSessionID)
            }
            throw error
        }
    }

    /// Admits the converted desktop events through the audited sync seam.
    ///
    /// `baseSequence` uses `UInt64.max` for the virtual "before seq 0" position
    /// exactly as `HarnessSyncEnvelope` documents, then advances by the admitted
    /// suffix. A local log that is already ahead is skipped rather than rewritten,
    /// which keeps a re-import idempotent.
    private func admit(_ events: [SessionEvent], sessionID: UUID) async throws -> [SessionEvent] {
        var admitted: [SessionEvent] = []
        var baseSequence = UInt64.max
        var startIndex = 0

        while startIndex < events.count {
            let endIndex = min(startIndex + Self.maximumEventsPerEnvelope, events.count)
            let chunk = Array(events[startIndex..<endIndex])
            let envelope = try HarnessSyncEnvelope(
                sessionID: sessionID,
                baseSequence: baseSequence,
                events: chunk,
                metadata: ["transport": "dsh-api-bridge"]
            )
            do {
                let result = try await trajectory.admitSyncEnvelope(envelope)
                admitted.append(contentsOf: result)
                baseSequence = chunk[chunk.count - 1].seq
            } catch SessionTrajectoryRepositoryError.syncBaseMismatch {
                // This mirror already holds that range; continue from the next one.
                baseSequence = chunk[chunk.count - 1].seq
            }
            startIndex = endIndex
        }
        return admitted
    }

    private func refreshDerivedState(
        sessionID: UUID,
        events: [SessionEvent],
        header: BridgeSessionLogHeader?,
        listTitle: String?,
        bridgeSessionID: String,
        titleIsFinal: Bool
    ) async throws {
        let persisted = try await trajectory.allEvents(sessionID: sessionID)
        let messages = SessionTrajectoryConversationProjection.messages(from: persisted)
        _ = try await sessionStore.checkpointSession(
            id: sessionID,
            checkpoint: ConversationCheckpoint(
                messages: messages,
                workState: ConversationWorkState(),
                bridgeMirror: BridgeSessionMirror(bridgeSessionID: bridgeSessionID)
            )
        )
        if !titleIsFinal,
           let title = Self.resolvedTitle(
               events: events,
               listTitle: listTitle,
               header: header,
               bridgeSessionID: bridgeSessionID
           ) {
            _ = try await sessionStore.renameSession(id: sessionID, title: title, source: .user)
        }
        if let queryModel {
            try await queryModel.refresh(sessionID: sessionID, persistence: trajectory)
        }
    }

    private func rollbackLocalSession(_ sessionID: UUID) async {
        _ = try? await sessionStore.deleteSession(id: sessionID)
    }

    static func resolvedTitle(
        events: [SessionEvent],
        listTitle: String?,
        header: BridgeSessionLogHeader?,
        bridgeSessionID: String
    ) -> String? {
        if let explicit = events.reversed().first(where: { $0.type == "session/title" })?
            .data.objectValue?["title"]?.stringValue {
            let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        }
        for event in events where event.type == SessionEventVocabulary.userMessage {
            let text = SessionQueryText.firstText(in: event.data.objectValue?["content"])
            if !text.isEmpty { return String(text.prefix(80)) }
        }
        if let listTitle {
            let trimmed = listTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        }
        if let cwd = header?.cwd, !cwd.isEmpty {
            return "Desktop · " + String(cwd.split(separator: "/").last ?? "Session")
        }
        return nil
    }

    static func provisionalTitle(
        events: [SessionEvent],
        listTitle: String?,
        header: BridgeSessionLogHeader?,
        bridgeSessionID: String
    ) -> String {
        resolvedTitle(
            events: events,
            listTitle: listTitle,
            header: header,
            bridgeSessionID: bridgeSessionID
        ) ?? "Desktop Session"
    }
}

/// Extracts plain text from a DSH `ContentBlock[]`, matching the projection the
/// read model and the desktop bridge both use.
enum SessionQueryText {
    static func firstText(in value: JSONValue?) -> String {
        guard case let .array(blocks)? = value else { return "" }
        var parts: [String] = []
        for block in blocks {
            guard let object = block.objectValue else { continue }
            if object["type"]?.stringValue == "text", let text = object["text"]?.stringValue {
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
