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
/// The coordinator cannot execute anything on the desktop host: the only client
/// it builds exposes read-only routes (`health`, `sessions`, `messages`,
/// `export`, `stream`), and the follow supervisor never posts.
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

    func importAll(
        progress: @Sendable (BridgeImportProgress) async -> Void = { _ in }
    ) async throws -> (outcomes: [BridgeImportOutcome], failures: [String: String]) {
        let importer = try activeImporter()
        let entries = try await activeClient()
            .listSessions(includeArchived: settings.includesArchivedSessions)
        return await importer.importSessions(entries, progress: progress)
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
            refresher: importer,
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
