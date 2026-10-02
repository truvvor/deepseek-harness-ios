import Foundation

/// Which half of the mirror an operation needs.
///
/// Reading a desktop log and following one both require the append-only
/// admission seam (`SessionTrajectoryRepository.admitSyncEnvelope`), not the
/// `SessionPersistence` protocol the app usually talks to. Availability is
/// therefore reported explicitly instead of failing later inside the store.
enum BridgeMirrorAvailability: Error, LocalizedError, Sendable, Equatable {
    case missingTrajectoryStore
    case disabled
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .missingTrajectoryStore:
            return "Desktop session import needs the canonical trajectory store, which this build did not provide."
        case .disabled:
            return "The desktop bridge is turned off. Enable it in Settings before reading desktop sessions."
        case .notConfigured:
            return "The desktop bridge needs both an address and a bearer token before it can read sessions."
        }
    }
}

/// Composition root for the desktop session mirror.
///
/// Holds the bridge client, the importer, the follow supervisor and the
/// `localUUID ↔ bridgeSessionId` map, so `AppModel` only has to project UI state
/// and never owns bridge transport itself.
///
/// The only writes it issues are `prompt` and `cancel` for an already mirrored
/// desktop session (D-014): the desktop agent runs the turn and writes its log,
/// and the mirror picks the result up through the normal follow/import path.
/// The follow supervisor itself never posts.
actor BridgeMirrorCoordinator {
    private let tokenStore: CredentialStore
    private let mappings: BridgeSessionMirrorStore
    private let sessionStore: SessionStore
    private let trajectory: SessionTrajectoryRepository?
    private let queryModel: SessionQueryReadModel?

    private var settings: BridgeSettings
    private var client: BridgeClient?
    private var importer: BridgeSessionImporter?
    private var sync: BridgeSessionSync?
    private var mirrorUpdateHandler: (@Sendable (UUID) async -> Void)?

    init(
        settings: BridgeSettings,
        tokenStore: CredentialStore,
        mappings: BridgeSessionMirrorStore,
        sessionStore: SessionStore,
        trajectory: SessionTrajectoryRepository?,
        queryModel: SessionQueryReadModel?
    ) {
        self.settings = settings
        self.tokenStore = tokenStore
        self.mappings = mappings
        self.sessionStore = sessionStore
        self.trajectory = trajectory
        self.queryModel = queryModel
    }

    var currentSettings: BridgeSettings { settings }

    var isConfigured: Bool { client != nil }

    var availability: BridgeMirrorAvailability? {
        guard trajectory != nil else { return .missingTrajectoryStore }
        guard settings.isEnabled else { return .disabled }
        return nil
    }

    /// Applies new settings. A change to the address or a timeout rebuilds the
    /// client and cancels every open stream, because an in-flight SSE connection
    /// bound to the previous origin must not keep feeding the mirror.
    func update(settings newSettings: BridgeSettings) async throws {
        let validated = try newSettings.validated()
        let previous = settings
        settings = validated

        let needsRebuild = previous.activeBaseURL != validated.activeBaseURL
            || previous.requestTimeoutSeconds != validated.requestTimeoutSeconds
            || previous.streamIdleTimeoutSeconds != validated.streamIdleTimeoutSeconds
        guard needsRebuild else { return }

        await sync?.stopAll()
        client = nil
        importer = nil
        sync = nil
        try await makeClientIfPossible()
    }

    /// Builds the client from the persisted settings and Keychain token. Called
    /// once at launch; without it a configured mirror would report
    /// `notConfigured` until the user re-saved the settings.
    func connectIfConfigured() async {
        guard client == nil else { return }
        try? await makeClientIfPossible()
    }

    func tokenConfigured() async -> Bool {
        await tokenStore.bridgeTokenConfigured()
    }

    func saveToken(_ token: String) async throws {
        try await tokenStore.saveBridgeToken(token)
        await rebuildClient()
    }

    func deleteToken() async throws {
        try await tokenStore.deleteBridgeToken()
        await sync?.stopAll()
        client = nil
        importer = nil
        sync = nil
    }

    func resetConnections() async {
        await client?.resetConnections()
    }

    // MARK: - Import

    /// A cheap reachability probe so the settings screen can report a real state
    /// instead of assuming the address works.
    func probeHealth() async throws -> BridgeSessionHealth {
        try await activeClient().health()
    }

    func listDesktopSessions(includeArchived: Bool) async throws -> [BridgeSessionListEntry] {
        try await activeClient().listSessions(includeArchived: includeArchived)
    }

    /// Brings the local mirrors in line with the desktop session list: imports
    /// or refreshes every listed session, then removes the local mirrors whose
    /// desktop session is no longer listed (archived, deleted, or hidden by the
    /// bridge's sidebar rules). Pruning only drops local copies; the desktop is
    /// never touched, and a later import restores anything listed again.
    func importAll(
        progress: @Sendable (BridgeImportProgress) async -> Void = { _ in }
    ) async throws -> (outcomes: [BridgeImportOutcome], failures: [String: String], pruned: [UUID]) {
        let importer = try activeImporter()
        let entries = try await activeClient()
            .listSessions(includeArchived: settings.includesArchivedSessions)
        let result = await importer.importSessions(entries, progress: progress)
        let listed = Set(entries.map(\.sessionID))
        var pruned: [UUID] = []
        for mapping in try await mappings.allMappings() where !listed.contains(mapping.bridgeSessionID) {
            do {
                try await removeMirror(localSessionID: mapping.localSessionID)
                pruned.append(mapping.localSessionID)
            } catch {
                continue
            }
        }
        return (result.outcomes, result.failures, pruned)
    }

    /// Removes every local mirror and its correspondence, including mappings
    /// whose local session was already deleted. The desktop is never touched.
    func removeAllMirrors() async throws -> [UUID] {
        var removed: [UUID] = []
        for mapping in try await mappings.allMappings() {
            try await removeMirror(localSessionID: mapping.localSessionID)
            removed.append(mapping.localSessionID)
        }
        return removed
    }

    func importOne(_ entry: BridgeSessionListEntry) async throws -> BridgeImportOutcome {
        try await activeImporter().importSession(entry)
    }

    func mirrorMappings() async throws -> [BridgeSessionMapping] {
        try await mappings.allMappings()
    }

    func mapping(localSessionID: UUID) async throws -> BridgeSessionMapping? {
        try await mappings.mapping(localSessionID: localSessionID)
    }

    /// Deletes the local mirror and its correspondence. The desktop session is
    /// untouched: removal is one-directional and read-only, exactly like import.
    func removeMirror(localSessionID: UUID) async throws {
        guard let mapping = try await mappings.mapping(localSessionID: localSessionID) else {
            return
        }
        await sync?.stopFollowing(localSessionID: localSessionID)
        if let trajectory {
            try await trajectory.delete(sessionID: mapping.localSessionID)
        }
        if let queryModel {
            try? await queryModel.remove(sessionID: mapping.localSessionID)
        }
        _ = try? await sessionStore.deleteSession(id: mapping.localSessionID)
        try await mappings.forget(bridgeSessionID: mapping.bridgeSessionID)
    }

    // MARK: - Desktop turns (D-014)

    static let followRestartDelayNanoseconds: UInt64 = 400_000_000

    /// Called with the local mirror id whenever a refresh admitted new desktop
    /// events, so the UI can reload an open mirror while a desktop turn runs.
    func setMirrorUpdateHandler(_ handler: (@Sendable (UUID) async -> Void)?) {
        mirrorUpdateHandler = handler
    }

    /// Sends `text` to the desktop agent of the mirrored session and returns
    /// after the desktop turn ends. The mirror is followed for the duration of
    /// the turn so intermediate desktop events (tool calls, partial answers)
    /// land on the phone, and is caught up from the export once more at the end.
    func sendPrompt(
        localSessionID: UUID,
        text: String,
        mode: BridgePromptMode = .queue
    ) async throws -> BridgePromptResult {
        let client = try activeClient()
        let importer = try activeImporter()
        guard let mapping = try await mappings.mapping(localSessionID: localSessionID) else {
            throw BridgeFollowError.mirrorNotFound(localSessionID)
        }
        async let response = client.prompt(
            sessionID: mapping.bridgeSessionID,
            text: text,
            mode: mode
        )
        // An idle mirror's follow loop may be sleeping in its idle backoff
        // (up to 32 s). Reconnect it once the desktop has had a moment to start
        // the turn, so intermediate events stream in instead of arriving at the end.
        if let sync {
            try? await Task.sleep(nanoseconds: Self.followRestartDelayNanoseconds)
            try? await sync.startFollowing(localSessionID: localSessionID)
        }
        let result: BridgePromptResult
        do {
            result = try await response
        } catch {
            // A rejected or interrupted turn may still have written events
            // (the user message, a partial answer); show what the desktop holds.
            try? await refresh(importer: importer, bridgeSessionID: mapping.bridgeSessionID)
            throw error
        }
        try await refresh(importer: importer, bridgeSessionID: mapping.bridgeSessionID)
        return result
    }

    /// Asks the desktop to stop the running turn of the mirrored session.
    func cancelPrompt(localSessionID: UUID) async throws {
        let client = try activeClient()
        guard let mapping = try await mappings.mapping(localSessionID: localSessionID) else {
            throw BridgeFollowError.mirrorNotFound(localSessionID)
        }
        try await client.cancel(sessionID: mapping.bridgeSessionID)
    }

    private func refresh(importer: BridgeSessionImporter, bridgeSessionID: String) async throws {
        let outcome = try await importer.importSession(bridgeSessionID: bridgeSessionID, listTitle: nil)
        await notifyIfChanged(outcome)
    }

    fileprivate func notifyIfChanged(_ outcome: BridgeImportOutcome) async {
        switch outcome {
        case .created, .refreshed:
            await mirrorUpdateHandler?(outcome.localSessionID)
        case .unchanged:
            break
        }
    }

    // MARK: - Follow

    func startFollowing(localSessionID: UUID) async throws {
        try await activeSync().startFollowing(localSessionID: localSessionID)
    }

    func stopFollowing(localSessionID: UUID) async {
        await sync?.stopFollowing(localSessionID: localSessionID)
    }

    func stopAllFollowing() async {
        await sync?.stopAll()
    }

    func followedSessionIDs() async -> [UUID] {
        await sync?.followedSessionIDs ?? []
    }

    // MARK: - Wiring

    private func rebuildClient() async {
        await sync?.stopAll()
        client = nil
        importer = nil
        sync = nil
        try? await makeClientIfPossible()
    }

    private func makeClientIfPossible() async throws {
        guard trajectory != nil else { return }
        guard settings.isEnabled, settings.activeBaseURL != nil else { return }
        guard await tokenStore.bridgeTokenConfigured() else { return }
        guard let trajectory else { return }

        let store = tokenStore
        let client = BridgeClient(
            configuration: try BridgeClientConfiguration(settings: settings),
            tokenProvider: { try? await store.readBridgeToken() }
        )
        let importer = BridgeSessionImporter(
            client: client,
            sessionStore: sessionStore,
            trajectory: trajectory,
            queryModel: queryModel,
            mappings: mappings
        )
        self.client = client
        self.importer = importer
        self.sync = BridgeSessionSync(
            client: client,
            refresher: NotifyingMirrorRefresher(importer: importer, coordinator: self),
            mappings: mappings
        )
    }

    private func activeClient() throws -> BridgeClient {
        if let availability { throw availability }
        guard let client else { throw BridgeMirrorAvailability.notConfigured }
        return client
    }

    private func activeImporter() throws -> BridgeSessionImporter {
        if let availability { throw availability }
        guard let importer else { throw BridgeMirrorAvailability.notConfigured }
        return importer
    }

    private func activeSync() throws -> BridgeSessionSync {
        if let availability { throw availability }
        guard let sync else { throw BridgeMirrorAvailability.notConfigured }
        return sync
    }
}

/// Follow-loop refresher that also tells the coordinator which local mirror
/// changed, so an open mirror reloads while the desktop turn is still running.
private struct NotifyingMirrorRefresher: BridgeMirrorRefreshing {
    let importer: BridgeSessionImporter
    weak var coordinator: BridgeMirrorCoordinator?

    func refreshMirror(bridgeSessionID: String) async throws {
        let outcome = try await importer.importSession(bridgeSessionID: bridgeSessionID, listTitle: nil)
        await coordinator?.notifyIfChanged(outcome)
    }
}
