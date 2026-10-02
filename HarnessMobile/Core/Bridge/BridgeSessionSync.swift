import Foundation

/// Outcome of one follow connection.
enum BridgeFollowOutcome: Sendable, Equatable {
    /// The desktop session stream ended normally (`closed` frame or socket EOF).
    case ended
}

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

/// Live, read-only follow of one mirrored desktop session.
///
/// New events are appended to the local trajectory idempotently by sequence
/// number: an event at or below the highest admitted sequence is skipped, so a
/// reconnect with `since=<last>` can never duplicate or reorder history. Nothing
/// is ever sent to the desktop host from here — this type owns no request other
/// than `GET …/stream`.
actor BridgeSessionSync {
    private struct FollowPosition {
        /// Highest desktop sequence number already represented locally.
        var throughSequence: Int64
        /// Sequences that exist in the local log, so a replacement can be
        /// checked against events this device actually holds.
        var retainedSequences: Set<UInt64>
    }

    private let client: BridgeClient
    private let trajectory: SessionTrajectoryRepository
    private let queryModel: SessionQueryReadModel?
    private let mappings: BridgeSessionMirrorStore

    private var rootTasks: [UUID: Task<Void, Never>] = [:]

    init(
        client: BridgeClient,
        trajectory: SessionTrajectoryRepository,
        queryModel: SessionQueryReadModel?,
        mappings: BridgeSessionMirrorStore
    ) {
        self.client = client
        self.trajectory = trajectory
        self.queryModel = queryModel
        self.mappings = mappings
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
            await self.runSupervised(
                localSessionID: localSessionID,
                bridgeSessionID: bridgeSessionID
            )
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

    private func runSupervised(localSessionID: UUID, bridgeSessionID: String) async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            do {
                try await followOnce(
                    localSessionID: localSessionID,
                    bridgeSessionID: bridgeSessionID
                )
                consecutiveFailures = 0
            } catch is CancellationError {
                return
            } catch BridgeClientError.cancelled {
                return
            } catch {
                consecutiveFailures += 1
            }
            if Task.isCancelled { return }
            // Bounded reconnect backoff. A disconnect is an expected state
            // (tunnel drops, desktop sleep), so the mirror resumes with `since`
            // instead of failing permanently.
            let delay = min(30, 0.5 * pow(2, Double(min(consecutiveFailures, 6))))
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    /// One follow connection. Returns when the stream ends.
    func followOnce(localSessionID: UUID, bridgeSessionID: String) async throws {
        var position = try await currentPosition(
            localSessionID: localSessionID,
            bridgeSessionID: bridgeSessionID
        )
        let stream = await client.stream(
            sessionID: bridgeSessionID,
            since: position.throughSequence >= 0 ? position.throughSequence : nil
        )

        for try await frame in stream {
            try Task.checkCancellation()
            switch frame.kind {
            case .snapshot:
                if let through = frame.throughSeq, through > position.throughSequence {
                    position.throughSequence = through
                }
            case .event:
                if let sequence = frame.seq, let eventType = frame.eventType {
                    try await apply(
                        eventType: eventType,
                        sequence: sequence,
                        time: frame.time,
                        content: frame.content,
                        role: frame.role,
                        localSessionID: localSessionID,
                        position: &position
                    )
                }
            case .closed:
                try await persistPosition(position, bridgeSessionID: bridgeSessionID)
                try await refreshIndex(localSessionID: localSessionID)
                return
            case .error:
                throw BridgeClientError.streamEnded(frame.message)
            case .unknown, .delta, .reasoning, .usage, .turnEnd:
                // Streaming deltas are already carried by durable
                // `assistant/chunk` events; only durable `event` frames change
                // the mirrored history.
                continue
            }
        }
        try await persistPosition(position, bridgeSessionID: bridgeSessionID)
        try await refreshIndex(localSessionID: localSessionID)
    }

    private func currentPosition(
        localSessionID: UUID,
        bridgeSessionID: String
    ) async throws -> FollowPosition {
        let events = try await trajectory.allEvents(sessionID: localSessionID)
        let mapping = try await mappings.mapping(bridgeSessionID: bridgeSessionID)
        if let mapping {
            return FollowPosition(
                throughSequence: mapping.importedThroughBridgeSeq,
                retainedSequences: Set(events.map(\.seq))
            )
        }
        return FollowPosition(
            throughSequence: Int64(events.last?.seq ?? 0) - 1,
            retainedSequences: Set(events.map(\.seq))
        )
    }

    private func apply(
        eventType: String,
        sequence: UInt64,
        time: Int64?,
        content: String?,
        role: String?,
        localSessionID: UUID,
        position: inout FollowPosition
    ) async throws {
        guard Int64(sequence) > position.throughSequence else { return }
        let event = try BridgeSessionEventConverter.makeEvent(
            type: eventType,
            seq: sequence,
            time: time.map { max(0, $0) } ?? SessionEventTimestamp.nowMilliseconds(),
            data: Self.eventData(content: content, role: role, eventType: eventType),
            isKnown: BridgeSessionEventConverter.isKnownEventType(eventType),
            surfaceStart: nil,
            surfaceEnd: nil
        )
        try await appendIdempotently(event, sessionID: localSessionID)
        position.throughSequence = Int64(sequence)
        position.retainedSequences.insert(sequence)
    }

    /// Appends one live event without ever duplicating or reordering history.
    ///
    /// Live frames carry no `surfaceOp`, so a live mirror grows strictly
    /// append-only: a mid-turn desktop replacement cannot make an already-shown
    /// message disappear on this device. The authoritative replacement is applied
    /// by the next `importSession` pass, which reads the full canonical export.
    /// `invalidSequence` therefore means "already present", not a failure.
    private func appendIdempotently(_ event: SessionEvent, sessionID: UUID) async throws {
        do {
            _ = try await trajectory.append(event, sessionID: sessionID)
        } catch SessionEventLogError.invalidSequence {
            return
        }
    }

    private func persistPosition(
        _ position: FollowPosition,
        bridgeSessionID: String
    ) async throws {
        try await mappings.updateFollowPosition(
            bridgeSessionID: bridgeSessionID,
            importedThroughBridgeSeq: position.throughSequence,
            importedEventCount: position.retainedSequences.count
        )
    }

    private func refreshIndex(localSessionID: UUID) async throws {
        guard let queryModel else { return }
        try await queryModel.refresh(sessionID: localSessionID, persistence: trajectory)
    }

    private static func eventData(
        content: String?,
        role: String?,
        eventType: String
    ) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let role { object["role"] = .string(role) }
        if let content { object["content"] = .string(content) }
        if eventType == SessionEventVocabulary.turnEnd, let content {
            object["reason"] = .object(["kind": .string(content)])
        }
        return .object(object)
    }
}
