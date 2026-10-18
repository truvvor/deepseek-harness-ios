import SwiftUI
import WidgetKit

struct HarnessSessionWidget: Widget {
    static let kind = "HarnessSessionWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: HarnessSessionWidgetProvider()) { entry in
            HarnessSessionWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Harness Status")
        .description("Shows Harness sessions running on this device (read-only).")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct HarnessSessionWidgetEntry: TimelineEntry {
    let date: Date
    let projection: HarnessWidgetProjection
}

private struct HarnessSessionWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> HarnessSessionWidgetEntry {
        HarnessSessionWidgetEntry(
            date: .now,
            projection: HarnessWidgetProjection(
                activeRunCount: 1,
                privacyModeEnabled: false,
                sessions: [
                    HarnessWidgetSessionProjection(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                        runID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                        status: .running,
                        queuedInputCount: 0
                    )
                ]
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (HarnessSessionWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<HarnessSessionWidgetEntry>) -> Void
    ) {
        let entry = currentEntry()
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date)
            ?? entry.date.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func currentEntry() -> HarnessSessionWidgetEntry {
        HarnessSessionWidgetEntry(
            date: .now,
            projection: HarnessWidgetProjectionStore.read()
        )
    }
}

private struct HarnessSessionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HarnessSessionWidgetEntry

    private var visibleSessions: ArraySlice<HarnessWidgetSessionProjection> {
        let limit: Int
        switch family {
        case .systemSmall: limit = 2
        case .systemMedium: limit = 3
        default: limit = 8
        }
        return entry.projection.sessions.prefix(limit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.blue)
                Text("Harness")
                    .font(.headline)
                Spacer(minLength: 4)
                Text("\(entry.projection.activeRunCount)")
                    .font(.headline.monospacedDigit())
            }

            if entry.projection.privacyModeEnabled {
                Label("Privacy Mode On", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if visibleSessions.isEmpty {
                Label("No Running Tasks", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleSessions) { session in
                    Link(destination: HarnessWidgetProjectionStore.deepLink(for: session.id)) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(session.status.tint)
                                .frame(width: 7, height: 7)
                            Text("Session \(shortID(session.id))")
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(session.status.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Harness Status")
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(4))
    }
}

private extension HarnessWidgetRunStatus {
    var label: String {
        switch self {
        case .preparing: "Preparing"
        case .running: "Running"
        case .cancelling: "Cancelling"
        }
    }

    var tint: Color {
        switch self {
        case .preparing: .orange
        case .running: .blue
        case .cancelling: .red
        }
    }
}
