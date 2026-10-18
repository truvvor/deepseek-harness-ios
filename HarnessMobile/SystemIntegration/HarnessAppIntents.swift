import AppIntents
import Foundation
import Observation

@MainActor
@Observable
final class AppIntentInboxNotifier {
    static let shared = AppIntentInboxNotifier()

    /// This is a wake-up signal only. Intent payloads are durably stored by
    /// `AppIntentInboxStore`, so concurrent invocations cannot overwrite one
    /// another while the app is suspended or not yet running.
    private(set) var revision = 0

    private init() {}

    func signalWorkAvailable() {
        revision &+= 1
    }
}

private enum HarnessAppIntentInbox {
    static let store = AppIntentInboxStore()

    static func enqueue(_ request: AppIntentInboxRequest) async throws {
        _ = try await store.enqueue(request)
        await MainActor.run {
            AppIntentInboxNotifier.shared.signalWorkAvailable()
        }
    }
}

struct ComposeHarnessTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Task in Harness"
    static let description = IntentDescription(
        "Opens Harness and places the task in the input field. The model request starts only after you confirm sending."
    )
    static let openAppWhenRun = true

    @Parameter(
        title: "Task",
        description: "The task to hand to Harness",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var task: String?

    func perform() async throws -> some IntentResult {
        let request = try AppIntentInboxRequest(
            action: .sendPrompt,
            prompt: task
        )
        try await HarnessAppIntentInbox.enqueue(request)
        return .result()
    }
}

struct ListHarnessSessionsIntent: AppIntent {
    static let title: LocalizedStringResource = "List Harness Sessions"
    static let description = IntentDescription("Lists the title, ID, and update time of Harness sessions on this device.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let sessions = try await SessionStore().listSessions(includeArchived: false)
            .sorted { $0.updatedAt > $1.updatedAt }
        guard !sessions.isEmpty else {
            return .result(value: "No sessions available.")
        }
        let formatter = ISO8601DateFormatter()
        let output = sessions.map { session in
            "\(session.title) | \(session.id.uuidString) | \(formatter.string(from: session.updatedAt))"
        }.joined(separator: "\n")
        return .result(value: output)
    }
}

struct GetHarnessSessionStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Harness Session Status"
    static let description = IntentDescription("Reads the persisted state and current run projection of a Harness session on this device.")
    static let openAppWhenRun = false

    @Parameter(title: "Session ID")
    var sessionID: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let id = try Self.parseSessionID(sessionID)
        let session = try await SessionStore().session(id: id)
        let isRunning = try await HarnessAppIntentInbox.store.isSessionRunning(id)
        let state = isRunning ? "Running" : "Idle"
        return .result(
            value: "\(session.title) | \(id.uuidString) | \(state) | Messages \(session.summary.messageCount) | \(ISO8601DateFormatter().string(from: session.updatedAt))"
        )
    }

    fileprivate static func parseSessionID(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AppIntentInboxError.invalidRequest
        }
        return id
    }
}

struct OpenHarnessSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Harness Session"
    static let description = IntentDescription("Opens the specified on-device session in Harness.")
    static let openAppWhenRun = true

    @Parameter(title: "Session ID")
    var sessionID: String

    func perform() async throws -> some IntentResult {
        let id = try GetHarnessSessionStatusIntent.parseSessionID(sessionID)
        let session = try await SessionStore().session(id: id)
        guard !session.isArchived else { throw SessionStoreError.sessionArchived(id) }
        try await HarnessAppIntentInbox.enqueue(
            AppIntentInboxRequest(action: .openSession, sessionID: id)
        )
        return .result()
    }
}

struct RetryHarnessSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Retry Harness Session"
    static let description = IntentDescription("Reruns the specified on-device session from its last user message.")
    static let openAppWhenRun = true

    @Parameter(title: "Session ID")
    var sessionID: String

    func perform() async throws -> some IntentResult {
        let id = try GetHarnessSessionStatusIntent.parseSessionID(sessionID)
        let session = try await SessionStore().session(id: id)
        guard !session.isArchived else { throw SessionStoreError.sessionArchived(id) }
        try await HarnessAppIntentInbox.enqueue(
            AppIntentInboxRequest(action: .retryLatestUserMessage, sessionID: id)
        )
        return .result()
    }
}

struct SendHarnessPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Harness Task"
    static let description = IntentDescription("Creates a task in Harness and runs it under the existing permission and approval policy.")
    static let openAppWhenRun = true

    @Parameter(title: "Task")
    var prompt: String

    @Parameter(title: "Session ID", default: nil)
    var sessionID: String?

    func perform() async throws -> some IntentResult {
        let resolvedSessionID = try sessionID.map(GetHarnessSessionStatusIntent.parseSessionID)
        if let resolvedSessionID {
            let session = try await SessionStore().session(id: resolvedSessionID)
            guard !session.isArchived else { throw SessionStoreError.sessionArchived(resolvedSessionID) }
        }
        try await HarnessAppIntentInbox.enqueue(
            AppIntentInboxRequest(
                action: .sendPrompt,
                sessionID: resolvedSessionID,
                prompt: prompt
            )
        )
        return .result()
    }
}

struct HarnessAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ComposeHarnessTaskIntent(),
            phrases: [
                "Start a task with \(.applicationName)",
                "Write a task in \(.applicationName)"
            ],
            shortTitle: "Start Harness Task",
            systemImageName: "bolt.horizontal.circle"
        )
        AppShortcut(
            intent: SendHarnessPromptIntent(),
            phrases: [
                "Send a task with \(.applicationName)",
                "Run a task in \(.applicationName)"
            ],
            shortTitle: "Send Harness Task",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: ListHarnessSessionsIntent(),
            phrases: ["List \(.applicationName) sessions"],
            shortTitle: "List Harness Sessions",
            systemImageName: "list.bullet"
        )
        AppShortcut(
            intent: GetHarnessSessionStatusIntent(),
            phrases: ["Get \(.applicationName) session status"],
            shortTitle: "Session Status",
            systemImageName: "info.circle"
        )
        AppShortcut(
            intent: OpenHarnessSessionIntent(),
            phrases: ["Open \(.applicationName) session"],
            shortTitle: "Open Harness Session",
            systemImageName: "arrow.up.right.square"
        )
        AppShortcut(
            intent: RetryHarnessSessionIntent(),
            phrases: ["Retry \(.applicationName) session"],
            shortTitle: "Retry Harness Session",
            systemImageName: "arrow.clockwise"
        )
    }
}
