import SwiftUI

struct BackgroundSettingsView: View {
    @Environment(BackgroundPreferencesModel.self) private var preferences
    @State private var notificationAuthorization: BackgroundNotificationAuthorization = .notDetermined
    @State private var notificationErrorDescription: String?

    let runtimeStatus: BackgroundRuntimeStatus
    let locationSnapshot: BackgroundLocationKeepAliveSnapshot
    let systemProjection: BackgroundSystemProjection
    let requestLocationAuthorization: () -> Void

    private let notifier = BackgroundCompletionNotifier()

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            BackgroundExecutionSettingsSection(
                isEnabled: $preferences.isEnhancedBackgroundEnabled,
                isSystemSupported: isContinuedProcessingSupported
            )
            BackgroundLocationKeepAliveSettingsSection(
                isEnabled: $preferences.isBackgroundLocationKeepAliveEnabled,
                snapshot: locationSnapshot,
                requestAuthorization: requestLocationAuthorization
            )
            BackgroundLiveActivitySettingsSection(
                isEnabled: $preferences.isLiveActivityEnabled,
                isSystemSupported: isLiveActivitySupported,
                areActivitiesEnabled: areLiveActivitiesEnabled
            )
            BackgroundNotificationSettingsSection(
                isEnabled: $preferences.areTaskNotificationsEnabled,
                authorization: notificationAuthorization,
                errorDescription: notificationErrorDescription
            )
            BackgroundPrivacySettingsSection(
                isEnabled: $preferences.isPrivacyModeEnabled
            )
            BackgroundRuntimeStatusSection(
                status: runtimeStatus,
                privacyModeEnabled: preferences.isPrivacyModeEnabled,
                isContinuedProcessingSupported: isContinuedProcessingSupported,
                isLiveActivitySupported: isLiveActivitySupported,
                isLiveActivityEnabled: preferences.isLiveActivityEnabled
            )
            BackgroundSystemProjectionSection(projection: systemProjection)
            BackgroundSafetyBoundarySection()

            if let persistenceErrorDescription = preferences.persistenceErrorDescription {
                Section {
                    Text(persistenceErrorDescription)
                        .foregroundStyle(.red)
                } header: {
                    Text("Preference Storage")
                } footer: {
                    Text("This setting could not be saved on this device.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(HarnessTheme.pageBackground)
        .navigationTitle("Background Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            notificationAuthorization = await notifier.authorizationStatus()
        }
        .onChange(of: preferences.areTaskNotificationsEnabled) { _, isEnabled in
            guard isEnabled else { return }
            Task {
                await requestNotificationAuthorization()
            }
        }
        .onChange(of: preferences.isLiveActivityEnabled) { _, isEnabled in
            guard !isEnabled else { return }
            Task {
                await HarnessLiveActivityManager.shared.endAll()
            }
        }
        .onChange(of: preferences.isPrivacyModeEnabled) { _, isEnabled in
            Task {
                await HarnessLiveActivityManager.shared.applyPrivacyMode(isEnabled)
            }
        }
    }

    private var isContinuedProcessingSupported: Bool {
        if #available(iOS 26.0, *) {
            true
        } else {
            false
        }
    }

    private var isLiveActivitySupported: Bool {
        HarnessLiveActivityManager.isSystemSupported
    }

    private var areLiveActivitiesEnabled: Bool {
        HarnessLiveActivityManager.shared.areActivitiesEnabled
    }

    private func requestNotificationAuthorization() async {
        do {
            notificationAuthorization = try await notifier.requestAuthorization()
            notificationErrorDescription = nil
        } catch {
            notificationAuthorization = await notifier.authorizationStatus()
            notificationErrorDescription = error.localizedDescription
        }
    }
}

private struct BackgroundSystemProjectionSection: View {
    let projection: BackgroundSystemProjection

    var body: some View {
        Section {
            HStack(spacing: HarnessTheme.Spacing.medium) {
                HarnessIconTile(systemImage: "bolt.horizontal.circle", tint: .accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Active Tasks")
                    Text("\(projection.activeRunCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HarnessStatusPill(title: tierLabel, systemImage: tierIcon, tint: tierTint)
            }
            statusRow("Notification Permission", value: projection.notificationAuthorization, icon: "bell.badge")
            statusRow("Location Permission", value: projection.locationAuthorization, icon: "location.fill")
            statusRow(
                "Live Activity Permission",
                value: projection.liveActivitySupported
                    ? (projection.liveActivityEnabled ? "Enabled" : "Off")
                    : "Unavailable",
                icon: "rectangle.topthird.inset.filled"
            )
            if !projection.degradedReasons.isEmpty {
                statusRow("Current Degradation", value: degradedLabel, icon: "exclamationmark.triangle", tint: .orange)
            }
            if !projection.degradedDetails.isEmpty {
                LabeledContent("Failure Evidence", value: projection.degradedDetails.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            BackgroundDetailsRow(
                title: "Projection Scope",
                text: "Shows the aggregate status of all parallel tasks. Prompts, tool arguments, tool output, and model text are never shown; degraded only means the corresponding system capability is currently unavailable."
            )
        } header: {
            Label("Current System Projection", systemImage: "waveform.path.ecg")
        }
    }

    private var tierLabel: String {
        switch projection.survivalTier {
        case .foreground: "Foreground"
        case .finiteBackgroundTask: "Short Background"
        case .continuedProcessing: "Continued Processing"
        case .extendedAudio: "Audio Extension"
        case .extendedLocation: "Location Extension"
        case .degraded: "Degraded"
        }
    }

    private var tierIcon: String {
        switch projection.survivalTier {
        case .foreground: "iphone"
        case .finiteBackgroundTask: "timer"
        case .continuedProcessing: "arrow.clockwise.icloud"
        case .extendedAudio: "speaker.wave.2"
        case .extendedLocation: "location.fill"
        case .degraded: "exclamationmark.triangle"
        }
    }

    private var tierTint: Color {
        switch projection.survivalTier {
        case .foreground: .secondary
        case .finiteBackgroundTask, .continuedProcessing: .blue
        case .extendedAudio, .extendedLocation: .green
        case .degraded: .orange
        }
    }

    private func statusRow(
        _ title: String,
        value: String,
        icon: String,
        tint: Color = .secondary
    ) -> some View {
        HStack(spacing: HarnessTheme.Spacing.medium) {
            HarnessIconTile(systemImage: icon, tint: tint, size: 28)
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var degradedLabel: String {
        projection.degradedReasons.map {
            switch $0 {
            case .lowPowerMode: "Low Power Mode"
            case .thermalPressure: "Thermal Pressure"
            case .audioUnavailable: "Audio Unavailable"
            case .locationUnavailable: "Location Unavailable"
            }
        }.sorted().joined(separator: ", ")
    }
}

private struct BackgroundLiveActivitySettingsSection: View {
    @Binding var isEnabled: Bool
    let isSystemSupported: Bool
    let areActivitiesEnabled: Bool

    var body: some View {
        Section {
            if isSystemSupported {
                Toggle("Live Activities", isOn: $isEnabled)
                LabeledContent(
                    "System Permission",
                    value: areActivitiesEnabled ? "Allowed" : "Turned Off in Settings"
                )
            } else {
                Toggle("Live Activities", isOn: .constant(false))
                    .disabled(true)
            }
            BackgroundDetailsRow(
                title: "About Live Activities",
                text: isSystemSupported
                    ? "Shows the current session, step, tool, and real progress. It only projects task status and does not give the app permanent background execution; turning it off removes the current Live Activity immediately."
                    : "This device does not support ActivityKit Live Activities."
            )
        } header: {
            Label("Lock Screen & Dynamic Island", systemImage: "rectangle.topthird.inset.filled")
        }
    }
}

private struct BackgroundExecutionSettingsSection: View {
    @Binding var isEnabled: Bool
    let isSystemSupported: Bool

    var body: some View {
        Section {
            if isSystemSupported {
                Toggle("Enhanced Background Processing", isOn: $isEnabled)
            } else {
                Toggle("Enhanced Background Processing", isOn: .constant(false))
                    .disabled(true)
            }
            BackgroundDetailsRow(
                title: "How It Works & Limits",
                text: isSystemSupported
                    ? "Combines iOS 26 Continued Processing with audio/location extension while a task runs. When the system background time quota expires and the extension layer is still healthy, the old lease ends and a new finite lease is acquired, continuing the same task and context. This is not a provider quota renewal; the system can still terminate the app due to resources, temperature, or user action."
                    : "This system does not support Continued Processing. On iOS 18–25, only the short background time provided by the system is used, with no guarantee of continued running."
            )
        } header: {
            Label("Background Execution", systemImage: "arrow.clockwise.icloud")
        }
    }
}

private struct BackgroundLocationKeepAliveSettingsSection: View {
    @Binding var isEnabled: Bool
    let snapshot: BackgroundLocationKeepAliveSnapshot
    let requestAuthorization: () -> Void

    var body: some View {
        Section {
            Toggle("Background Coarse Location Keep-Alive", isOn: $isEnabled)
            LabeledContent("Location Permission", value: authorizationLabel)
            if isEnabled && (snapshot.authorization == .notDetermined || snapshot.authorization == .whenInUse) {
                Button("Request Always Location Access", action: requestAuthorization)
            }
            LabeledContent("Current Status", value: phaseLabel)
            BackgroundDetailsRow(
                title: "Location Use & Privacy",
                text: "Location services at roughly 3 km accuracy are used only when this switch is on, Always location is allowed, the app has been in the background for about 15 seconds, and a task is still running. Coordinates are never saved, shown, or uploaded; the one-time location tool does not trigger this authorization."
            )
        } header: {
            Label("Optional Location Keep-Alive", systemImage: "location.fill")
        }
    }

    private var authorizationLabel: String {
        switch snapshot.authorization {
        case .notDetermined: "Not Requested"
        case .whenInUse: "While Using"
        case .always: "Always"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .unavailable: "Unavailable"
        }
    }

    private var phaseLabel: String {
        switch snapshot.phase {
        case .idle: "Not Running"
        case .waitingForDelay: "Waiting for Background Delay"
        case .waitingForPermission: "Waiting for Permission"
        case .running: "Running"
        case .degraded: "Unavailable"
        }
    }
}

private struct BackgroundNotificationSettingsSection: View {
    @Binding var isEnabled: Bool
    let authorization: BackgroundNotificationAuthorization
    let errorDescription: String?

    var body: some View {
        Section {
            Toggle("Task Notifications", isOn: $isEnabled)
            LabeledContent("System Permission", value: authorizationLabel)
            if let errorDescription {
                Text("Notification authorization failed: \(errorDescription)")
                    .foregroundStyle(.red)
            } else if authorization == .denied {
                Text("Notification preference saved, but system permission was denied. Allow notifications in Settings to receive task completion alerts.")
                    .foregroundStyle(.orange)
            }
            BackgroundDetailsRow(
                title: "About Notifications",
                text: "Sends a local notification only when a task ends. System notification permission is requested only when you turn this on."
            )
        } header: {
            Label("Task Notifications", systemImage: "bell.badge")
        }
    }

    private var authorizationLabel: String {
        switch authorization {
        case .notDetermined:
            "Not Requested"
        case .denied:
            "Denied"
        case .authorized:
            "Allowed"
        case .unavailable:
            "Unavailable"
        }
    }
}

private struct BackgroundPrivacySettingsSection: View {
    @Binding var isEnabled: Bool

    var body: some View {
        Section {
            Toggle("Task Status Privacy", isOn: $isEnabled)
            BackgroundDetailsRow(
                title: "About Private Display",
                text: "When on, the Lock Screen, Dynamic Island, and completion notifications show only a generic task status, without session titles, tool names, or reply content."
            )
        } header: {
            Label("Private Display", systemImage: "eye.slash")
        }
    }
}

private struct BackgroundRuntimeStatusSection: View {
    let status: BackgroundRuntimeStatus
    let privacyModeEnabled: Bool
    let isContinuedProcessingSupported: Bool
    let isLiveActivitySupported: Bool
    let isLiveActivityEnabled: Bool

    var body: some View {
        Section {
            LabeledContent(
                "Continued Processing",
                value: isContinuedProcessingSupported ? "Available on iOS 26" : "Currently Unavailable"
            )
            LabeledContent(
                "Live Activities",
                value: liveActivityStatus
            )
            runtimeContent
            BackgroundDetailsRow(
                title: "About Status",
                text: "Continued Processing and Live Activities are both managed by iOS. Live Activities show only real task status; neither guarantees unlimited background time or a resident process."
            )
        } header: {
            Label("Status", systemImage: "chart.bar.xaxis")
        }
    }

    private var liveActivityStatus: String {
        guard isLiveActivitySupported else { return "Currently Unavailable" }
        return isLiveActivityEnabled ? "Enabled" : "Off"
    }

    @ViewBuilder
    private var runtimeContent: some View {
        switch status {
        case .idle:
            HarnessStatusPill(title: "Idle", systemImage: "pause.circle", tint: .secondary)
        case let .running(progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Current Task")
                    Spacer()
                    HarnessStatusPill(title: "Running", systemImage: "bolt.fill", tint: .green)
                    Text("\(progress.completedUnitCount)/\(progress.totalUnitCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(
                    value: Double(progress.completedUnitCount),
                    total: Double(progress.totalUnitCount)
                )
                if privacyModeEnabled {
                    Text("Task in Progress")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(progress.title)
                        .font(.footnote)
                    Text(progress.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        case let .completed(success):
            HarnessStatusPill(
                title: success ? "Completed" : "Not Completed",
                systemImage: success ? "checkmark.circle.fill" : "xmark.circle.fill",
                tint: success ? .green : .red
            )
        case .interrupted:
            HarnessStatusPill(title: "Interrupted by System", systemImage: "pause.circle", tint: .orange)
        }
    }
}

private struct BackgroundDetailsRow: View {
    let title: String
    let text: String

    var body: some View {
        DisclosureGroup(title) {
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, HarnessTheme.Spacing.xSmall)
        }
        .font(.footnote)
    }
}

private struct BackgroundSafetyBoundarySection: View {
    var body: some View {
        Section {
            Label("Silent audio runs only when enabled, a task is running, and the app is in the background", systemImage: "speaker.wave.2")
            Label("Background location must be enabled separately with Always permission; coordinates are never saved or uploaded", systemImage: "location")
            Label("Never uses Bluetooth or VoIP to fake background work", systemImage: "checkmark.shield")
        } header: {
            Label("Execution Boundaries", systemImage: "checkmark.shield")
        }
    }
}
