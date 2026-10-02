import Foundation

/// Desktop-bridge (read-only session mirror) coordination.
///
/// Owned by `AppModel` because the composition root is where the private
/// `sessionStore`, `trajectoryRepository`, `sessionQueryReadModel` and
/// `credentialStore` seams live. The transport, import and follow algorithms stay
/// in `Core/Bridge/`, and `AppModel` only projects their outcome into UI state.
extension AppModel {
    /// True when the currently selected session is a desktop mirror and therefore
    /// read-only on this device.
    var activeSessionIsDesktopMirror: Bool {
        guard let activeSessionID else { return false }
        return sessions.first { $0.id == activeSessionID }?.isDesktopMirror == true
    }

    /// Restores the persisted preferences and, when the mirror is enabled and
    /// fully configured, builds the bridge client. A missing trajectory store
    /// leaves the bridge unavailable rather than reading a different log than the
    /// rest of the app.
    func bootstrapDesktopMirror() async {
        let settings = settingsStore.loadBridgeSettings()
        desktopMirrorSettings = settings
        let coordinator = BridgeMirrorCoordinator(
            settings: settings,
            tokenStore: credentialStore,
            mappings: BridgeSessionMirrorStore(),
            sessionStore: sessionStore,
            trajectory: trajectoryRepository as? SessionTrajectoryRepository,
            queryModel: sessionQueryReadModel
        )
        desktopBridgeCoordinator = coordinator
        followedMirrorSessionIDs = []
        await refreshDesktopMirrorProjection()
    }

    func desktopMirrorAvailability() async -> BridgeMirrorAvailability? {
        await desktopBridgeCoordinator?.availability
    }

    func desktopMirrorTokenConfigured() async -> Bool {
        await desktopBridgeCoordinator?.tokenConfigured() ?? false
    }

    /// True only when the address, the flag and the Keychain token are all
    /// present, i.e. a request can actually be attempted.
    func desktopMirrorIsReady() async -> Bool {
        guard let coordinator = desktopBridgeCoordinator else { return false }
        guard await coordinator.availability == nil else { return false }
        return await coordinator.tokenConfigured()
    }

    @discardableResult
    func saveDesktopMirrorSettings(_ settings: BridgeSettings) async -> Bool {
        do {
            let validated = try settings.validated()
            try settingsStore.saveBridgeSettings(validated)
            desktopMirrorSettings = validated
            desktopMirrorLastError = nil
            await desktopBridgeCoordinator?.update(settings: validated)
            return true
        } catch {
            desktopMirrorLastError = error.localizedDescription
            presentError(error)
            return false
        }
    }

    func saveDesktopMirrorToken(_ token: String) async -> Bool {
        guard let coordinator = desktopBridgeCoordinator else { return false }
        do {
            try await coordinator.saveToken(token)
            desktopMirrorLastError = nil
            return true
        } catch {
            desktopMirrorLastError = error.localizedDescription
            presentError(error)
            return false
        }
    }

    func deleteDesktopMirrorToken() async {
        await desktopBridgeCoordinator?.deleteToken()
        followedMirrorSessionIDs = []
    }

    func checkDesktopMirrorHealth() async -> BridgeSessionHealth? {
        do {
            let health = try await desktopBridgeCoordinator?.probeHealth()
            desktopMirrorLastError = nil
            return health
        } catch {
            desktopMirrorLastError = error.localizedDescription
            return nil
        }
    }

    /// Imports every desktop session the bridge lists. Local sessions that are
    /// already mapped are refreshed with the desktop suffix only.
    @discardableResult
    func importDesktopMirrorSessions() async -> (created: Int, refreshed: Int, failures: [String: String]) {
        guard let coordinator = desktopBridgeCoordinator else {
            return (0, 0, [:])
        }
        desktopMirrorProgress = BridgeImportProgress(completed: 0, total: 0, currentTitle: nil)
        defer { desktopMirrorProgress = nil }
        do {
            let result = try await coordinator.importAll { [weak self] progress in
                await MainActor.run { self?.desktopMirrorProgress = progress }
            }
            var created = 0
            var refreshed = 0
            for outcome in result.outcomes {
                switch outcome {
                case .created: created += 1
                case .refreshed: refreshed += 1
                case .unchanged: break
                }
            }
            desktopMirrorLastError = result.failures.isEmpty
                ? nil
                : result.failures.values.sorted().first
            await refreshSessionSummaries()
            await refreshDesktopMirrorProjection()
            return (created, refreshed, result.failures)
        } catch {
            desktopMirrorLastError = error.localizedDescription
            presentError(error)
            return (0, 0, [:])
        }
    }

    func desktopMirrorMappings() async -> [BridgeSessionMapping] {
        (try? await desktopBridgeCoordinator?.mirrorMappings()) ?? []
    }

    /// Opens a mirror: starts following it when automatic follow is enabled and
    /// selects it. A mirror never triggers the local agent loop.
    func openDesktopMirrorSession(_ localSessionID: UUID) async {
        if desktopMirrorSettings.followsSelectedMirrorAutomatically {
            await startFollowingDesktopMirror(localSessionID)
        }
        await switchConversation(to: localSessionID)
        await refreshSessionSummaries()
    }

    func startFollowingDesktopMirror(_ localSessionID: UUID) async {
        guard let coordinator = desktopBridgeCoordinator else { return }
        do {
            try await coordinator.startFollowing(localSessionID: localSessionID)
            followedMirrorSessionIDs.insert(localSessionID)
            desktopMirrorLastError = nil
        } catch {
            desktopMirrorLastError = error.localizedDescription
        }
    }

    func stopFollowingDesktopMirror(_ localSessionID: UUID) async {
        await desktopBridgeCoordinator?.stopFollowing(localSessionID: localSessionID)
        followedMirrorSessionIDs.remove(localSessionID)
    }

    func stopFollowingAllDesktopMirrors() async {
        await desktopBridgeCoordinator?.stopAllFollowing()
        followedMirrorSessionIDs = []
    }

    /// Deletes the local mirror and its correspondence. The desktop session is
    /// never modified.
    func removeDesktopMirrorSession(_ localSessionID: UUID) async {
        do {
            try await desktopBridgeCoordinator?.removeMirror(localSessionID: localSessionID)
            followedMirrorSessionIDs.remove(localSessionID)
            await refreshSessionSummaries()
            await refreshDesktopMirrorProjection()
        } catch {
            desktopMirrorLastError = error.localizedDescription
            presentError(error)
        }
    }

    private func refreshDesktopMirrorProjection() async {
        let followed = await desktopBridgeCoordinator?.followedSessionIDs() ?? []
        followedMirrorSessionIDs = Set(followed)
    }
}
