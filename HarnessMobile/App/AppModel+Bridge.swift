import Foundation
import UIKit

/// Finite UIKit background time for one blocking desktop prompt request. The
/// expiration handler ends the task synchronously, as UIKit requires.
@MainActor
final class DesktopTurnBackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Desktop turn") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// One desktop turn in flight for a mirrored session.
struct DesktopMirrorTurn: Sendable, Equatable {
    var startedAt: Date
    /// Prompts sent and not yet answered; `queue` mode lets several overlap.
    var pendingPrompts: Int
}

/// Desktop-bridge (session mirror) coordination.
///
/// Owned by `AppModel` because the composition root is where the private
/// `sessionStore`, `trajectoryRepository`, `sessionQueryReadModel` and
/// `credentialStore` seams live. The transport, import and follow algorithms stay
/// in `Core/Bridge/`, and `AppModel` only projects their outcome into UI state.
extension AppModel {
    /// True when the currently selected session is a desktop mirror: its turns
    /// run on the desktop agent and the local agent loop never runs for it.
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
            trajectory: (trajectoryRepository as? SessionTrajectoryRepository)
                ?? (trajectoryRepository as? TelemetrySessionPersistence)?.canonicalRepository,
            queryModel: sessionQueryReadModel
        )
        desktopBridgeCoordinator = coordinator
        followedMirrorSessionIDs = []
        await coordinator.setMirrorUpdateHandler { [weak self] localSessionID in
            await self?.reloadDesktopMirrorIfActive(localSessionID)
        }
        await coordinator.connectIfConfigured()
        await refreshDesktopMirrorProjection()
        await followDesktopMirrorIfSelected()
        await catchUpDesktopMirrorsInBackground()
    }

    /// Follows the selected session when it is a mirror and automatic follow
    /// is on, so a mirror opened from any list streams desktop events live.
    func followDesktopMirrorIfSelected() async {
        guard let activeSessionID, activeSessionIsDesktopMirror,
              desktopMirrorSettings.followsSelectedMirrorAutomatically,
              !followedMirrorSessionIDs.contains(activeSessionID) else { return }
        await startFollowingDesktopMirror(activeSessionID)
    }

    /// Minimum spacing between automatic catch-ups (launch, foreground).
    static let desktopMirrorCatchUpInterval: TimeInterval = 20

    /// Pulls every mirror's new desktop tail without any UI: a short
    /// `export?since=<cursor>` per session. Runs at launch and whenever the app
    /// returns to the foreground, so the phone shows what the desktop wrote
    /// while the app was away, without the user pressing Sync.
    func catchUpDesktopMirrorsInBackground() async {
        guard let coordinator = desktopBridgeCoordinator,
              await coordinator.availability == nil,
              await coordinator.isConfigured,
              !desktopMirrorCatchUpInFlight else { return }
        if let last = desktopMirrorLastCatchUp,
           Date.now.timeIntervalSince(last) < Self.desktopMirrorCatchUpInterval {
            return
        }
        desktopMirrorCatchUpInFlight = true
        defer { desktopMirrorCatchUpInFlight = false }
        desktopMirrorLastCatchUp = .now
        do {
            let result = try await coordinator.importAll(indexesSearch: false)
            await finishMirrorRemoval(result.pruned)
            if let activeSessionID, activeSessionIsDesktopMirror {
                await reloadDesktopMirrorIfActive(activeSessionID)
            }
        } catch {
            // Silent by design: the user did not ask for this sync. The next
            // manual Sync reports its errors in Settings.
            desktopMirrorLastError = error.localizedDescription
        }
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
            try await desktopBridgeCoordinator?.update(settings: validated)
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
        do {
            try await desktopBridgeCoordinator?.deleteToken()
            desktopMirrorLastError = nil
        } catch {
            desktopMirrorLastError = error.localizedDescription
            presentError(error)
        }
        followedMirrorSessionIDs = []
    }

    /// The single refusal used by every local agent-loop entry point.
    func refuseDesktopMirrorMutation() {
        presentError(DesktopMirrorReadOnlyError())
    }

    // MARK: - Desktop turns (D-014)

    /// True while a turn this iPhone sent to the desktop is still running in the
    /// selected mirror.
    var activeDesktopTurnInFlight: Bool {
        guard let activeSessionID else { return false }
        return desktopMirrorTurns[activeSessionID] != nil
    }

    /// Chat busy state: a local run or a desktop turn of the selected session.
    var isChatBusy: Bool { isRunning || activeDesktopTurnInFlight }

    var chatRunStartedAt: Date? {
        if let runStartedAt { return runStartedAt }
        guard let activeSessionID else { return nil }
        return desktopMirrorTurns[activeSessionID]?.startedAt
    }

    /// Sends composer text to the desktop agent of the selected mirror. The
    /// desktop runs the turn and writes the log; the reply reaches the phone
    /// through the follow/import path. Returns once the prompt is handed off so
    /// the composer clears; the turn keeps running in the background.
    func submitToDesktopMirror(_ text: String, disposition: QueuedInputDisposition) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !hasStagedImage, !hasStagedFile else {
            presentError(DesktopMirrorAttachmentError())
            return false
        }
        guard let sessionID = activeSessionID, let coordinator = desktopBridgeCoordinator else {
            presentError(BridgeMirrorAvailability.notConfigured)
            return false
        }
        if let availability = await coordinator.availability {
            presentError(availability)
            return false
        }
        guard await coordinator.isConfigured else {
            presentError(BridgeMirrorAvailability.notConfigured)
            return false
        }

        var turn = desktopMirrorTurns[sessionID] ?? DesktopMirrorTurn(startedAt: .now, pendingPrompts: 0)
        turn.pendingPrompts += 1
        desktopMirrorTurns[sessionID] = turn
        errorMessage = nil

        // The bridge aborts a desktop turn when its prompt request disconnects,
        // so keep the request alive through the short background grace period
        // iOS grants when the user leaves the app mid-turn.
        let lease = DesktopTurnBackgroundLease()
        lease.begin()
        let mode: BridgePromptMode = disposition == .steer ? .steer : .queue
        Task { @MainActor [weak self] in
            defer { lease.end() }
            do {
                _ = try await coordinator.sendPrompt(localSessionID: sessionID, text: text, mode: mode)
                self?.finishDesktopTurn(sessionID, error: nil)
            } catch {
                self?.finishDesktopTurn(sessionID, error: error)
            }
            await self?.reloadDesktopMirrorIfActive(sessionID)
            await self?.refreshDesktopMirrorProjection()
        }
        return true
    }

    /// Stop button: cancels the desktop turn in a mirror, the local run elsewhere.
    func cancelActiveTurn() {
        guard activeSessionIsDesktopMirror, let sessionID = activeSessionID else {
            cancelRun()
            return
        }
        guard desktopMirrorTurns[sessionID] != nil, let coordinator = desktopBridgeCoordinator else {
            return
        }
        Task { @MainActor [weak self] in
            do {
                try await coordinator.cancelPrompt(localSessionID: sessionID)
            } catch {
                self?.presentError(error)
            }
        }
    }

    /// Reloads the open mirror after the bridge admitted new desktop events.
    ///
    /// The session holds only the newest tail of the transcript. When the
    /// on-screen conversation already ends inside that tail, only the messages
    /// after it are appended, so older pages the user scrolled into stay
    /// loaded and the scroll position does not jump.
    func reloadDesktopMirrorIfActive(_ sessionID: UUID) async {
        await refreshSessionSummaries()
        guard sessionID == activeSessionID, activeSessionIsDesktopMirror else { return }
        guard let session = try? await sessionStore.session(id: sessionID) else { return }
        let tail = session.messages
        let total = session.bridgeMirror?.transcriptMessageCount ?? tail.count
        if let lastID = messages.last?.id,
           let index = tail.firstIndex(where: { $0.id == lastID }) {
            let fresh = tail[(index + 1)...]
            if !fresh.isEmpty { messages.append(contentsOf: fresh) }
        } else {
            messages = tail
            desktopMirrorLoadedStart = max(0, total - tail.count)
        }
        await refreshTrajectory()
    }

    var activeDesktopMirrorHasOlderMessages: Bool {
        activeSessionIsDesktopMirror && desktopMirrorLoadedStart > 0
    }

    /// Prepends up to `limit` older transcript messages to the open mirror.
    /// Returns how many were added.
    func loadOlderDesktopMirrorMessages(limit: Int) async -> Int {
        guard let sessionID = activeSessionID, activeSessionIsDesktopMirror,
              desktopMirrorLoadedStart > 0,
              let coordinator = desktopBridgeCoordinator else { return 0 }
        do {
            let page = try await coordinator.transcriptPage(
                localSessionID: sessionID,
                before: desktopMirrorLoadedStart,
                limit: limit
            )
            guard !page.isEmpty, sessionID == activeSessionID else { return 0 }
            messages.insert(contentsOf: page, at: 0)
            desktopMirrorLoadedStart = max(0, desktopMirrorLoadedStart - page.count)
            return page.count
        } catch {
            desktopMirrorLastError = error.localizedDescription
            return 0
        }
    }

    private func finishDesktopTurn(_ sessionID: UUID, error: Error?) {
        if var turn = desktopMirrorTurns[sessionID] {
            turn.pendingPrompts -= 1
            desktopMirrorTurns[sessionID] = turn.pendingPrompts > 0 ? turn : nil
        }
        guard let error else { return }
        if case BridgeClientError.cancelled = error { return }
        desktopMirrorLastError = error.localizedDescription
        if sessionID == activeSessionID {
            presentError(error)
        }
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

    /// Result of syncing the mirror list with the desktop.
    struct DesktopMirrorSyncSummary: Sendable, Equatable {
        var created = 0
        var refreshed = 0
        var removed = 0
        var failures: [String: String] = [:]
    }

    /// Syncs the local mirrors with the sessions the bridge lists: imports new
    /// ones, refreshes mapped ones with the desktop suffix, and removes local
    /// mirrors whose desktop session is no longer listed.
    @discardableResult
    func importDesktopMirrorSessions() async -> DesktopMirrorSyncSummary {
        guard let coordinator = desktopBridgeCoordinator else {
            return DesktopMirrorSyncSummary()
        }
        desktopMirrorProgress = BridgeImportProgress(completed: 0, total: 0, currentTitle: nil)
        defer { desktopMirrorProgress = nil }
        do {
            let result = try await coordinator.importAll { [weak self] progress in
                await MainActor.run { self?.desktopMirrorProgress = progress }
            }
            var summary = DesktopMirrorSyncSummary(removed: result.pruned.count, failures: result.failures)
            for outcome in result.outcomes {
                switch outcome {
                case .created: summary.created += 1
                case .refreshed: summary.refreshed += 1
                case .unchanged: break
                }
            }
            desktopMirrorLastError = result.failures.isEmpty
                ? nil
                : result.failures.values.sorted().first
            await finishMirrorRemoval(result.pruned)
            // The open mirror shows its in-memory copy; pick up what the sync
            // just wrote.
            if let activeSessionID, activeSessionIsDesktopMirror {
                await reloadDesktopMirrorIfActive(activeSessionID)
            }
            return summary
        } catch {
            desktopMirrorLastError = error.localizedDescription
            presentError(error)
            return DesktopMirrorSyncSummary()
        }
    }

    /// Deletes every local desktop mirror, including mirror sessions whose
    /// mapping was lost, so a following import starts from a clean list. The
    /// desktop sessions are never modified. Returns the number removed.
    @discardableResult
    func forgetAllDesktopMirrors() async -> Int {
        var removed = Set<UUID>()
        if let coordinator = desktopBridgeCoordinator {
            await coordinator.stopAllFollowing()
            do {
                removed.formUnion(try await coordinator.removeAllMirrors())
            } catch {
                desktopMirrorLastError = error.localizedDescription
                presentError(error)
            }
        }
        await refreshSessionSummaries()
        // Mirror sessions without a mapping (for example after a failed import)
        // are ordinary rows to the coordinator; delete them like any session.
        for orphan in sessions where orphan.isDesktopMirror && !removed.contains(orphan.id) {
            await deleteConversation(id: orphan.id)
            removed.insert(orphan.id)
        }
        desktopMirrorTurns = [:]
        await finishMirrorRemoval(Array(removed))
        return removed.count
    }

    private func finishMirrorRemoval(_ removed: [UUID]) async {
        for id in removed {
            followedMirrorSessionIDs.remove(id)
            desktopMirrorTurns[id] = nil
        }
        if let activeSessionID, removed.contains(activeSessionID) {
            await reconcileActiveSessionAfterMirrorRemoval()
        } else {
            await refreshSessionSummaries()
        }
        await refreshDesktopMirrorProjection()
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
            await finishMirrorRemoval([localSessionID])
        } catch {
            desktopMirrorLastError = error.localizedDescription
            presentError(error)
        }
    }

    func refreshDesktopMirrorProjection() async {
        let followed = await desktopBridgeCoordinator?.followedSessionIDs() ?? []
        followedMirrorSessionIDs = Set(followed)
    }
}

/// Raised when a local agent-loop or trajectory write is attempted on a desktop
/// mirror (DECISIONS D-012, D-014).
struct DesktopMirrorReadOnlyError: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        "This session lives on the desktop DeepSeek Harness. Send a new message to continue it on the desktop; editing or re-running earlier messages is not available from the iPhone."
    }
}

/// Attachments cannot be forwarded to a desktop turn yet.
struct DesktopMirrorAttachmentError: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        "Images and files cannot be sent to a desktop session yet. Remove the attachment and send text only."
    }
}
