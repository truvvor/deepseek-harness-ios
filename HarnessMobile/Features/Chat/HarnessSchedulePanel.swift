import SwiftUI
import Observation

/// Mirrors the desktop `ui-schedule` surface (a read-only catalog of the
/// session's Schedule reminders with cancel for pending rows) as a native
/// panel. Data comes from the same `HarnessScheduleStore` the Schedule tools
/// and the background controller use; the panel never mutates anything but a
/// user-initiated cancel.
@MainActor
struct HarnessSchedulePanel: View {
    let store: any HarnessScheduleManaging
    let sessionID: String
    let dismiss: () -> Void

    @State private var schedules: [HarnessScheduleSnapshot] = []
    @State private var loadError: String?
    @State private var refreshTask: Task<Void, Never>?

    static func relativeTime(_ epochMilliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochMilliseconds) / 1_000)
        return timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Unable to Load Scheduled Reminders",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if schedules.isEmpty {
                    ContentUnavailableView(
                        "No Scheduled Reminders",
                        systemImage: "clock.badge.checkmark",
                        description: Text("The model can create scheduled reminders for this session with the schedule tool.")
                    )
                } else {
                    List {
                        pendingSection
                        if hasFinished {
                            finishedSection
                        }
                    }
                }
            }
            .navigationTitle("Scheduled Reminders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: dismiss)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh Reminders")
                }
            }
        }
        .task {
            refresh()
        }
        .onDisappear {
            refreshTask?.cancel()
        }
    }

    private var pendingSection: some View {
        Section("Pending") {
            ForEach(pending, id: \.id) { schedule in
                ScheduleRow(schedule: schedule, store: store) { id in
                    await cancel(scheduleID: id)
                }
            }
        }
    }

    @ViewBuilder
    private var finishedSection: some View {
        Section("Completed or Cancelled") {
            ForEach(finished, id: \.id) { schedule in
                ScheduleRow(schedule: schedule, store: nil) { _ in }
            }
        }
    }

    private var pending: [HarnessScheduleSnapshot] {
        // Claimed rows are mid-execution: they stay in the active section
        // with their own badge instead of disappearing between groups.
        schedules
            .filter { $0.status == .pending || $0.status == .claimed }
            .sorted { $0.runAt < $1.runAt }
    }

    private var finished: [HarnessScheduleSnapshot] {
        schedules.filter { $0.status == .completed || $0.status == .cancelled }
    }

    private var hasFinished: Bool { !finished.isEmpty }

    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                let loaded = await store.list(ownerSession: sessionID)
                guard !Task.isCancelled else { return }
                schedules = loaded
                loadError = nil
            }
        }
    }

    private func cancel(scheduleID: String) async {
        do {
            _ = try await store.delete(id: scheduleID, ownerSession: sessionID)
            refresh()
        } catch {
            loadError = "Cancel failed: \(error.localizedDescription)"
        }
    }
}

@MainActor
private struct ScheduleRow: View {
    let schedule: HarnessScheduleSnapshot
    let store: (any HarnessScheduleManaging)?
    let onCancel: (String) async -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: schedule.status == .completed ? "checkmark.circle.fill" : "clock")
                .foregroundStyle(tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.label.isEmpty ? "Untitled Reminder" : schedule.label)
                    .font(.body.weight(.medium))
                Text(HarnessSchedulePanel.relativeTime(schedule.runAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !schedule.prompt.isEmpty {
                    Text(schedule.prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let lastError = schedule.lastError, schedule.status == .pending {
                    Text("Last run failed: \(lastError)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            if schedule.status == .pending, let store {
                Button("Cancel", role: .destructive) {
                    Task { await onCancel(schedule.id) }
                }
                .font(.caption)
            } else {
                Text(statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        switch schedule.status {
        case .pending: .orange
        case .claimed: .blue
        case .completed: .green
        case .cancelled: .secondary
        }
    }

    private var statusLabel: String {
        switch schedule.status {
        case .pending: "Pending"
        case .claimed: "Running"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        }
    }
}
