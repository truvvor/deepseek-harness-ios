import Foundation
import UserNotifications

enum BackgroundNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case unavailable
}

enum BackgroundCompletionNotificationError: Error, Equatable, Sendable {
    case notAuthorized
}

struct BackgroundCompletionNotifier: Sendable {
    func authorizationStatus() async -> BackgroundNotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.authorization(from: settings.authorizationStatus)
    }

    func requestAuthorization() async throws -> BackgroundNotificationAuthorization {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        }
        return await authorizationStatus()
    }

    func deliverCompletion(
        runID: UUID,
        succeeded: Bool,
        taskTitle: String?,
        privacyModeEnabled: Bool
    ) async throws {
        guard await authorizationStatus() == .authorized else {
            throw BackgroundCompletionNotificationError.notAuthorized
        }

        let content = UNMutableNotificationContent()
        content.title = succeeded ? "Background Task Completed" : "Background Task Not Completed"
        content.body = Self.body(
            succeeded: succeeded,
            taskTitle: taskTitle,
            privacyModeEnabled: privacyModeEnabled
        )
        // This is an ordinary user-visible notification sound, not an audio
        // session or a background keep-alive mechanism.
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "background-completion.\(runID.uuidString.lowercased())",
            content: content,
            trigger: nil
        )
        try await UNUserNotificationCenter.current().add(request)
    }

    private static func authorization(
        from status: UNAuthorizationStatus
    ) -> BackgroundNotificationAuthorization {
        switch status {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized, .provisional, .ephemeral:
            .authorized
        @unknown default:
            .unavailable
        }
    }

    private static func body(
        succeeded: Bool,
        taskTitle: String?,
        privacyModeEnabled: Bool
    ) -> String {
        guard !privacyModeEnabled,
              let taskTitle,
              !taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Open the app to view task status."
        }
        return succeeded
            ? "\"\(taskTitle)\" completed."
            : "\"\(taskTitle)\" stopped. Open the app to view details."
    }
}
