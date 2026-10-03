import Foundation

enum BridgeFollowError: Error, LocalizedError, Sendable, Equatable {
    case mirrorNotFound(UUID)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case let .mirrorNotFound(sessionID):
            return "Session \(sessionID.uuidString) is not a desktop mirror, so it cannot be followed."
        case .notConfigured:
            return "The desktop bridge is not configured."
        }
    }
}

/// Refreshes one mirror from the canonical desktop export. Implemented by
/// `BridgeSessionImporter`; a protocol so the follow loop can be tested without
/// a live bridge.
protocol BridgeMirrorRefreshing: Sendable {
    func refreshMirror(bridgeSessionID: String) async throws
}

extension BridgeSessionImporter: BridgeMirrorRefreshing {
    func refreshMirror(bridgeSessionID: String) async throws {
        _ = try await importSession(bridgeSessionID: bridgeSessionID, listTitle: nil, indexesSearch: false)
    }
}

/// Live signal from a followed mirror's SSE stream, delivered to the UI as it
/// arrives (D-014). Durable history still comes through the importer.
enum BridgeLiveUpdate: Sendable, Equatable {
    case turnStarted
    /// Streamed assistant text, appended to what came before in this turn.
    case delta(String)
    /// Streamed reasoning text.
    case reasoning(String)
    /// A durable message was written on the desktop; the refresh that follows
    /// carries it.
    case messageCommitted
    case turnEnded
}

typealias BridgeLiveHandler = @Sendable (UUID, BridgeLiveUpdate) async -> Void

/// What one follow connection observed, which drives the reconnect pacing.
struct BridgeFollowPass: Sendable, Equatable {
    /// Durable desktop events were announced during this connection.
    var sawEvents = false
    /// The mirror was refreshed from the export at least once.
    var refreshed = false
}

/// Live, read-only follow of one mirrored desktop session.
///
/// The SSE stream is used only as a change signal. Its `event` frames carry a
/// flattened `{role, content: String}` projection that cannot reproduce the
/// canonical event (content blocks, tool calls, reasoning), so this type never
/// writes frames into the trajectory. Whenever the desktop reports new durable
/// events, the mirror is refreshed through `BridgeSessionImporter`, which reads
/// `/export` and appends exactly the missing suffix. History is therefore
/// always lossless, dense and identical to an import, and a reconnect can
/// neither duplicate nor skip events.
///
/// Nothing is ever sent to the desktop host from here: the only requests are
/// `GET …/stream` and, through the importer, `GET …/export`.
actor BridgeSessionSync {
    /// Refresh at most this often while a long desktop turn keeps producing
    /// events, so the mirror stays live without re-reading the export per frame.
    static let minimumRefreshInterval: TimeInterval = 1

    /// Desktop event types that are a chat message; their `event` frame
    /// refreshes the mirror at once instead of waiting for the throttle.
    static let messageEventTypes: Set<String> = [
        SessionEventVocabulary.userMessage,
        SessionEventVocabulary.assistantMessage,
        SessionEventVocabulary.toolResult
    ]

    private let client: BridgeClient
    private let refresher: any BridgeMirrorRefreshing
    private let mappings: BridgeSessionMirrorStore
    private let liveHandler: BridgeLiveHandler?

    private var rootTasks: [UUID: Task<Void, Never>] = [:]

    init(
        client: BridgeClient,
        refresher: any BridgeMirrorRefreshing,
        mappings: BridgeSessionMirrorStore,
        liveHandler: BridgeLiveHandler? = nil
    ) {
        self.client = client
        self.refresher = refresher
        self.mappings = mappings
        self.liveHandler = liveHandler
    }

    var followedSessionIDs: [UUID] {
        rootTasks.keys.sorted { $0.uuidString < $1.uuidString }
    }

    /// Starts following `localSessionID`. Repeated calls replace the existing
    /// subscription so only one stream per mirror can ever be open.
    func startFollowing(localSessionID: UUID) async throws {
        let mapping = try await mappings.mapping(localSessionID: localSessionID)
        guard let mapping else {
            throw BridgeFollowError.mirrorNotFound(localSessionID)
        }
        stopFollowing(localSessionID: localSessionID)
        let bridgeSessionID = mapping.bridgeSessionID
        rootTasks[localSessionID] = Task { [weak self] in
            guard let self else { return }
            await self.runSupervised(bridgeSessionID: bridgeSessionID)
        }
    }

    func stopFollowing(localSessionID: UUID) {
        rootTasks.removeValue(forKey: localSessionID)?.cancel()
    }

    func stopAll() {
        for task in rootTasks.values { task.cancel() }
        rootTasks.removeAll()
    }

    // MARK: - Supervision

    /// Delay before the next connection.
    ///
    /// Failures back off from 1 s to 16 s. A connection that ended cleanly
    /// without any new event (an idle or finished desktop session, which the
    /// bridge closes after the snapshot) backs off from 2 s to 8 s: the open
    /// mirror must notice a turn the desktop starts within seconds, and a
    /// reconnect against the idle bridge costs one small request. Any
    /// announced event resets both.
    static func reconnectDelay(consecutiveFailures: Int, consecutiveIdlePasses: Int) -> TimeInterval {
        if consecutiveFailures > 0 {
            return pow(2, Double(min(consecutiveFailures, 5) - 1))
        }
        if consecutiveIdlePasses > 0 {
            return 2 * pow(2, Double(min(consecutiveIdlePasses, 3) - 1))
        }
        return 0.5
    }

    private func runSupervised(bridgeSessionID: String) async {
        var consecutiveFailures = 0
        var consecutiveIdlePasses = 0
        while !Task.isCancelled {
            do {
                let pass = try await followOnce(bridgeSessionID: bridgeSessionID)
                consecutiveFailures = 0
                consecutiveIdlePasses = pass.sawEvents ? 0 : consecutiveIdlePasses + 1
            } catch is CancellationError {
                return
            } catch BridgeClientError.cancelled {
                return
            } catch {
                consecutiveFailures += 1
            }
            if Task.isCancelled { return }
            let delay = Self.reconnectDelay(
                consecutiveFailures: consecutiveFailures,
                consecutiveIdlePasses: consecutiveIdlePasses
            )
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    /// One follow connection. Returns when the stream ends.
    func followOnce(bridgeSessionID: String) async throws -> BridgeFollowPass {
        let mapping = try await mappings.mapping(bridgeSessionID: bridgeSessionID)
        let importedThrough = mapping?.importedThroughBridgeSeq ?? -1
        let stream = await client.stream(
            sessionID: bridgeSessionID,
            since: importedThrough >= 0 ? importedThrough : nil
        )
        return try await consume(
            stream,
            bridgeSessionID: bridgeSessionID,
            importedThrough: importedThrough,
            localSessionID: mapping?.localSessionID
        )
    }

    /// Applies one stream's frames. Split out so the pacing and refresh rules can
    /// be exercised with an in-process frame sequence.
    func consume(
        _ frames: AsyncThrowingStream<BridgeStreamFrame, Error>,
        bridgeSessionID: String,
        importedThrough: Int64,
        localSessionID: UUID? = nil,
        now: @Sendable () -> Date = { .now }
    ) async throws -> BridgeFollowPass {
        var pass = BridgeFollowPass()
        var pending = false
        var lastRefresh: Date?

        func live(_ update: BridgeLiveUpdate) async {
            guard let localSessionID, let liveHandler else { return }
            await liveHandler(localSessionID, update)
        }

        for try await frame in frames {
            try Task.checkCancellation()
            var shouldRefresh = false
            var isFinal = false
            switch frame.kind {
            case .snapshot:
                // The desktop is already ahead of the mirror (for example after a
                // reconnect gap): catch up from the export immediately.
                if let through = frame.throughSeq, through > importedThrough {
                    pass.sawEvents = true
                    shouldRefresh = true
                }
            case .event:
                pass.sawEvents = true
                pending = true
                let eventType = frame.eventType ?? ""
                if eventType == SessionEventVocabulary.turnStart {
                    await live(.turnStarted)
                }
                if Self.messageEventTypes.contains(eventType) {
                    // A chat message landed on the desktop: show it now.
                    await live(.messageCommitted)
                    shouldRefresh = true
                } else if let lastRefresh {
                    shouldRefresh = now().timeIntervalSince(lastRefresh) >= Self.minimumRefreshInterval
                } else {
                    shouldRefresh = true
                }
            case .delta:
                if let text = frame.text ?? frame.content, !text.isEmpty {
                    await live(.delta(text))
                }
            case .reasoning:
                if let text = frame.text ?? frame.content, !text.isEmpty {
                    await live(.reasoning(text))
                }
            case .turnEnd:
                await live(.turnEnded)
                shouldRefresh = pending
            case .closed:
                shouldRefresh = pending
                isFinal = true
            case .error:
                throw BridgeClientError.streamEnded(frame.message)
            case .unknown, .usage:
                break
            }
            if shouldRefresh {
                try await refresher.refreshMirror(bridgeSessionID: bridgeSessionID)
                pending = false
                pass.refreshed = true
                lastRefresh = now()
            }
            if isFinal { return pass }
        }
        if pending {
            try await refresher.refreshMirror(bridgeSessionID: bridgeSessionID)
            pass.refreshed = true
        }
        return pass
    }
}
