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
    private let transcripts: BridgeMirrorTranscriptStore
    private var inFlight: [String: Task<BridgeImportOutcome, Error>] = [:]

    init(
        client: BridgeClient,
        sessionStore: SessionStore,
        trajectory: SessionTrajectoryRepository,
        queryModel: SessionQueryReadModel?,
        mappings: BridgeSessionMirrorStore,
        transcripts: BridgeMirrorTranscriptStore = BridgeMirrorTranscriptStore()
    ) {
        self.client = client
        self.sessionStore = sessionStore
        self.trajectory = trajectory
        self.queryModel = queryModel
        self.mappings = mappings
        self.transcripts = transcripts
    }

    /// Imports (or refreshes) every listed desktop session.
    ///
    /// A per-session failure is reported through `failures` and does not abort
    /// the remaining sessions, so one unmappable session cannot block the rest.
    func importSessions(
        _ entries: [BridgeSessionListEntry],
        indexesSearch: Bool = true,
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
                outcomes.append(try await importSession(entry, indexesSearch: indexesSearch))
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
    func importSession(_ entry: BridgeSessionListEntry, indexesSearch: Bool = true) async throws -> BridgeImportOutcome {
        try await importSession(bridgeSessionID: entry.sessionID, listTitle: entry.title, indexesSearch: indexesSearch)
    }

    /// Re-reads the canonical desktop export and appends whatever the local
    /// mirror does not hold yet. The live follow calls this when the stream
    /// reports new events, so live history is always the lossless export and
    /// never a reconstruction of the lossy SSE `event` frame.
    @discardableResult
    /// `indexesSearch` refreshes the SQLite search projection after the
    /// import. That reads the whole local log, so the live follow and the
    /// silent foreground catch-up skip it; a manual Sync indexes.
    func importSession(
        bridgeSessionID: String,
        listTitle: String?,
        indexesSearch: Bool = true
    ) async throws -> BridgeImportOutcome {
        try await serialized(bridgeSessionID: bridgeSessionID) {
            let outcome = try await self.importPaged(bridgeSessionID: bridgeSessionID, listTitle: listTitle)
            if indexesSearch, let queryModel = self.queryModel {
                switch outcome {
                case .created, .refreshed:
                    try await queryModel.refresh(sessionID: outcome.localSessionID, persistence: self.trajectory)
                case .unchanged:
                    break
                }
            }
            return outcome
        }
    }

    /// Removes the mirror's projected transcript (the local log is the
    /// coordinator's concern).
    func forgetTranscript(sessionID: UUID) async throws {
        try await transcripts.delete(sessionID: sessionID)
    }

    /// Events per `export?since=&limit=` page.
    static let exportPageSize = 1_000

    /// Imports or refreshes one mirror page by page from the desktop cursor.
    ///
    /// The mapping (and with it the cursor) is recorded after every page, so a
    /// failure part-way through a 30 MB session keeps the pages already
    /// admitted and the next sync resumes after them instead of re-reading the
    /// whole log and failing at the same place forever. A bridge without
    /// incremental export answers with the full log, which is imported in one
    /// pass as before.
    private func importPaged(bridgeSessionID: String, listTitle: String?) async throws -> BridgeImportOutcome {
        var cursor = try await resumeCursor(bridgeSessionID: bridgeSessionID)
        var createdSessionID: UUID?
        var localSessionID: UUID?
        var appendedTotal = 0
        var rebuiltAfterRewind = false

        while true {
            try Task.checkCancellation()
            let page = try await client.exportLog(
                sessionID: bridgeSessionID,
                since: cursor,
                limit: Self.exportPageSize
            )
            guard page.isIncremental else {
                return try await importFullLog(
                    page.data,
                    bridgeSessionID: bridgeSessionID,
                    listTitle: listTitle
                )
            }
            // The desktop log is shorter than the mirror (rolled back or
            // restored). Appending from the stale cursor would skip everything
            // the desktop writes until it passes that number again, so rebuild
            // the same mirror from the start of the log.
            if cursor >= 0, let head = page.desktopHead, head < cursor {
                guard !rebuiltAfterRewind else {
                    throw BridgeImportError.notMirrorable("the desktop log moved backwards during the import")
                }
                rebuiltAfterRewind = true
                if let mapping = try await mappings.mapping(bridgeSessionID: bridgeSessionID) {
                    try await resetMirrorLog(mapping)
                }
                cursor = -1
                continue
            }

            let report = try BridgeSessionEventConverter.decodeLog(
                page.data,
                firstSequence: UInt64(cursor + 1)
            )
            if localSessionID == nil,
               try await mappings.mapping(bridgeSessionID: bridgeSessionID) == nil {
                // A desktop session that carries no user/assistant messages is
                // an empty shell; mirroring it produced a zero-message row.
                if report.events.isEmpty
                    || (!page.hasMore
                        && SessionTrajectoryConversationProjection.transcriptMessages(from: report.events).isEmpty) {
                    throw BridgeImportError.notMirrorable("the desktop session has no messages yet")
                }
            }

            let outcome = try await importConverted(
                bridgeSessionID: bridgeSessionID,
                listTitle: listTitle,
                header: report.header,
                events: report.events,
                lastBridgeSequence: max(report.lastBridgeSequence, cursor),
                isSuffix: true
            )
            localSessionID = outcome.localSessionID
            switch outcome {
            case let .created(id):
                createdSessionID = id
            case let .refreshed(_, appended):
                appendedTotal += appended
            case .unchanged:
                break
            }
            cursor = max(report.lastBridgeSequence, cursor)
            if !page.hasMore || report.events.isEmpty { break }
        }

        if let createdSessionID {
            return .created(localSessionID: createdSessionID)
        }
        guard let localSessionID else {
            throw BridgeImportError.notMirrorable("the desktop export returned no pages")
        }
        return appendedTotal > 0
            ? .refreshed(localSessionID: localSessionID, appendedEvents: appendedTotal)
            : .unchanged(localSessionID: localSessionID)
    }

    /// Where the next page starts: the stored desktop cursor when the local log
    /// ends exactly there, otherwise -1 (full rebuild) for a log that diverged.
    private func resumeCursor(bridgeSessionID: String) async throws -> Int64 {
        guard let mapping = try await mappings.mapping(bridgeSessionID: bridgeSessionID),
              (try? await sessionStore.session(id: mapping.localSessionID)) != nil else {
            // No mirror yet, or a stale mapping that `importConverted` clears.
            return -1
        }
        // Mirrors written before the append-only marker existed may have been
        // "repaired" on open: the store appended synthetic turn closers that
        // occupy the slots of the desktop's next events.
        let wasMarked = await trajectory.isAppendOnlyMirror(sessionID: mapping.localSessionID)
        try await trajectory.markAppendOnlyMirror(sessionID: mapping.localSessionID)
        let next = try await trajectory.nextSequence(sessionID: mapping.localSessionID)
        let head = Int64(next) - 1
        let cursor = mapping.importedThroughBridgeSeq
        if head == cursor {
            return cursor
        }
        if wasMarked, head > cursor {
            // A marked mirror never gets synthetic events, so the extra local
            // events are desktop events whose page failed before its mapping
            // was recorded. Continue after them.
            return head
        }
        try await resetMirrorLog(mapping)
        return -1
    }

    /// One-pass import of a complete log, for a bridge without incremental
    /// export.
    private func importFullLog(
        _ data: Data,
        bridgeSessionID: String,
        listTitle: String?
    ) async throws -> BridgeImportOutcome {
        let report = try BridgeSessionEventConverter.decodeLog(data)
        if let mapping = try await mappings.mapping(bridgeSessionID: bridgeSessionID) {
            if report.lastBridgeSequence < mapping.importedThroughBridgeSeq {
                try await resetMirrorLog(mapping)
            }
        } else if SessionTrajectoryConversationProjection.transcriptMessages(from: report.events).isEmpty {
            throw BridgeImportError.notMirrorable("the desktop session has no messages yet")
        }
        return try await importConverted(
            bridgeSessionID: bridgeSessionID,
            listTitle: listTitle,
            header: report.header,
            events: report.events,
            lastBridgeSequence: report.lastBridgeSequence
        )
    }

    /// Drops the mirror's local log and cursor but keeps its session and
    /// mapping identity, so the following full import rebuilds the same mirror
    /// (same local id, still selectable) from the desktop's current log.
    private func resetMirrorLog(_ mapping: BridgeSessionMapping) async throws {
        try await trajectory.delete(sessionID: mapping.localSessionID)
        try await trajectory.markAppendOnlyMirror(sessionID: mapping.localSessionID)
        try await transcripts.delete(sessionID: mapping.localSessionID)
        var reset = mapping
        reset.importedThroughBridgeSeq = -1
        reset.importedEventCount = 0
        reset.updatedAt = .now
        try await mappings.record(reset)
    }

    /// Runs imports of one desktop session strictly one after another. A manual
    /// import and the live follow may both refresh the same mirror; without this
    /// the actor's suspension points would let them interleave and race on the
    /// local log head.
    private func serialized(
        bridgeSessionID: String,
        _ operation: @escaping @Sendable () async throws -> BridgeImportOutcome
    ) async throws -> BridgeImportOutcome {
        let previous = inFlight[bridgeSessionID]
        let task = Task<BridgeImportOutcome, Error> {
            _ = await previous?.result
            return try await operation()
        }
        inFlight[bridgeSessionID] = task
        defer {
            if inFlight[bridgeSessionID] == task {
                inFlight[bridgeSessionID] = nil
            }
        }
        return try await task.value
    }

    /// Applies an already-converted desktop log. Split out so the conversion and
    /// the write path can each be exercised without a live bridge.
    @discardableResult
    func importConverted(
        bridgeSessionID: String,
        listTitle: String?,
        header: BridgeSessionLogHeader?,
        events: [SessionEvent],
        lastBridgeSequence: Int64,
        isSuffix: Bool = false
    ) async throws -> BridgeImportOutcome {
        var existing = try await mappings.mapping(bridgeSessionID: bridgeSessionID)
        // The mirror's local session may have been deleted from the session list
        // while its mapping survived. Re-import such a desktop session from
        // scratch instead of failing on the missing session forever.
        if let stale = existing, (try? await sessionStore.session(id: stale.localSessionID)) == nil {
            try? await trajectory.delete(sessionID: stale.localSessionID)
            if let queryModel {
                try? await queryModel.remove(sessionID: stale.localSessionID)
            }
            try await mappings.forget(bridgeSessionID: bridgeSessionID)
            existing = nil
        }
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
                appended: appended,
                isNew: isNew,
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
                    importedEventCount: isSuffix
                        ? (existing?.importedEventCount ?? 0) + appended.count
                        : events.count
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
    /// The converter numbers desktop events densely from 0, and a mirror log is
    /// only ever written by this importer, so local sequence `n` always holds
    /// desktop event `n`. Only the suffix past the local head is admitted,
    /// chunked to `HarnessSyncEnvelope.maximumEvents`. `UInt64.max` is the
    /// virtual "before seq 0" base for an empty log, as `HarnessSyncEnvelope`
    /// documents. A local log that is already at or past the desktop head is
    /// left untouched, which keeps a re-import idempotent.
    private func admit(_ events: [SessionEvent], sessionID: UUID) async throws -> [SessionEvent] {
        // Mark before the log is first opened so the store never appends
        // synthetic turn closers to a mirror.
        try await trajectory.markAppendOnlyMirror(sessionID: sessionID)
        let localNext = try await trajectory.nextSequence(sessionID: sessionID)
        let suffix = events.filter { $0.seq >= localNext }
        guard !suffix.isEmpty else { return [] }
        guard suffix[0].seq == localNext else {
            throw BridgeImportError.notMirrorable(
                "the desktop log does not continue the local mirror at sequence \(localNext)"
            )
        }

        var admitted: [SessionEvent] = []
        var baseSequence = localNext == 0 ? UInt64.max : localNext - 1
        var startIndex = 0
        while startIndex < suffix.count {
            let endIndex = min(startIndex + Self.maximumEventsPerEnvelope, suffix.count)
            let chunk = Array(suffix[startIndex..<endIndex])
            let envelope = try HarnessSyncEnvelope(
                sessionID: sessionID,
                baseSequence: baseSequence,
                events: chunk,
                metadata: ["transport": "dsh-api-bridge"]
            )
            admitted.append(contentsOf: try await trajectory.admitSyncEnvelope(envelope))
            baseSequence = chunk[chunk.count - 1].seq
            startIndex = endIndex
        }
        return admitted
    }

    /// Projects only the admitted suffix into the mirror's transcript store and
    /// hands the session its newest tail plus the total count. Nothing here
    /// re-reads the local log: a refresh costs the page it imported.
    private func refreshDerivedState(
        sessionID: UUID,
        appended: [SessionEvent],
        isNew: Bool,
        events: [SessionEvent],
        header: BridgeSessionLogHeader?,
        listTitle: String?,
        bridgeSessionID: String,
        titleIsFinal: Bool
    ) async throws {
        if isNew {
            try await transcripts.delete(sessionID: sessionID)
        }
        let session = try await sessionStore.session(id: sessionID)
        var total = try await transcripts.count(sessionID: sessionID)
        var tailChanged = isNew
        // A mirror written before the transcript store existed holds its whole
        // transcript in the session; seed the store from it once.
        if !isNew, total == 0, session.bridgeMirror?.transcriptMessageCount == nil, !session.messages.isEmpty {
            total = try await transcripts.append(session.messages, sessionID: sessionID)
            tailChanged = true
        }
        if !appended.isEmpty {
            let seedTail = try await transcripts.tail(
                sessionID: sessionID,
                limit: BridgeMirrorTranscriptStore.sessionTailLimit
            )
            let fresh = SessionTrajectoryConversationProjection.transcriptMessages(
                from: appended,
                knownToolNames: SessionTrajectoryConversationProjection.toolNames(in: seedTail)
            )
            if !fresh.isEmpty {
                total = try await transcripts.append(fresh, sessionID: sessionID)
                tailChanged = true
            }
        }
        if tailChanged || session.bridgeMirror?.transcriptMessageCount != total {
            let tail = try await transcripts.tail(
                sessionID: sessionID,
                limit: BridgeMirrorTranscriptStore.sessionTailLimit
            )
            _ = try await sessionStore.checkpointSession(
                id: sessionID,
                checkpoint: ConversationCheckpoint(
                    messages: tail,
                    workState: ConversationWorkState(),
                    bridgeMirror: BridgeSessionMirror(
                        bridgeSessionID: bridgeSessionID,
                        transcriptMessageCount: total
                    )
                )
            )
        }
        // A new mirror takes its title from the first page; an existing one
        // follows a desktop rename, which arrives through the list title.
        if let title = titleIsFinal ? listTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            : Self.resolvedTitle(events: events, listTitle: listTitle, header: header, bridgeSessionID: bridgeSessionID),
           !title.isEmpty,
           title != session.title {
            _ = try await sessionStore.renameSession(id: sessionID, title: title, source: .user)
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
        // The bridge list title is what the desktop sidebar shows (a fork is
        // "Title (1)" there while its log still carries the parent's title
        // event), so the phone list matches the desktop one.
        if let listTitle {
            let trimmed = listTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        }
        if let explicit = events.reversed().first(where: { $0.type == "session/title" })?
            .data.objectValue?["title"]?.stringValue {
            let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        }
        for event in events where event.type == SessionEventVocabulary.userMessage {
            let text = SessionQueryText.firstText(in: event.data.objectValue?["content"])
            if !text.isEmpty { return String(text.prefix(80)) }
        }
        if let cwd = header?.cwd, !cwd.isEmpty {
            // The desktop host may be Windows: split on both separators so a
            // backslash-only path yields its last component instead of the whole
            // path ("Desktop · C:\Users\…").
            let leaf = cwd
                .split(whereSeparator: { $0 == "/" || $0 == "\\" })
                .last
                .map(String.init)
            return "Desktop · " + (leaf.flatMap { $0.isEmpty ? nil : $0 } ?? "Session")
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
