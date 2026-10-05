import SwiftUI

struct ToolEventTreeView: View {
    let events: [AgentToolEvent]
    let isLive: Bool

    @State private var showsAllEvents = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hiddenEventCount > 0 {
                Button {
                    showsAllEvents = true
                } label: {
                    Label("Show \(hiddenEventCount) earlier tool calls", systemImage: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ForEach(visibleEvents) { event in
                ToolEventNodeView(event: event, isLive: isLive)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isLive ? "Running tool" : "Tool call")
    }

    private var visibleEvents: ArraySlice<AgentToolEvent> {
        showsAllEvents ? events[...] : events.suffix(isLive ? 5 : 4)
    }

    private var hiddenEventCount: Int {
        showsAllEvents ? 0 : max(0, events.count - visibleEvents.count)
    }
}

private struct ToolEventNodeView: View {
    let event: AgentToolEvent
    let isLive: Bool

    @State private var selectedEvent: AgentToolEvent?
    @State private var showsAllChildren = false

    var body: some View {
        let displayEvent = presentedEvent
        VStack(alignment: .leading, spacing: 8) {
            ToolEventCard(event: displayEvent, isLive: isLive) {
                selectedEvent = displayEvent
            }

            if !displayEvent.children.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if hiddenChildCount > 0 {
                        Button {
                            showsAllChildren = true
                        } label: {
                            Text("Show \(hiddenChildCount) earlier subtools")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(visibleChildren) { child in
                        ToolEventNodeView(event: child, isLive: isLive)
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1)
                        .accessibilityHidden(true)
                }
            }
        }
        .sheet(item: $selectedEvent) { selectedEvent in
            ToolEventInspectorView(event: selectedEvent)
        }
    }

    private var presentedEvent: AgentToolEvent {
        guard !isLive else { return event }
        var presented = event
        presented.finishNonterminalRecursively(
            status: .interrupted,
            message: "The tool did not report a final status before the task ended.",
            at: event.finishedAt ?? .now
        )
        return presented
    }

    private var visibleChildren: ArraySlice<AgentToolEvent> {
        showsAllChildren
            ? presentedEvent.children[...]
            : presentedEvent.children.suffix(3)
    }

    private var hiddenChildCount: Int {
        showsAllChildren ? 0 : max(0, presentedEvent.children.count - visibleChildren.count)
    }
}

/// Shared compact tool row for durable events and legacy orphaned results.
struct ToolEventCard: View {
    let event: AgentToolEvent
    let isLive: Bool
    let onInspect: () -> Void

    @State private var isExpanded = false

    var body: some View {
        let presentation = NativeToolEventPresentation.derive(for: event)
        let summary = NativeToolEventRowSummary.make(
            event: event,
            presentation: presentation
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    ConversationMeasuredBlock(
                        itemID: .toolEvent(eventID: event.id, callID: event.callID),
                        kind: "tool-summary",
                        content: measurementContent(summary: summary)
                    ) {
                        ToolEventSummaryRow(
                            event: event,
                            isLive: isLive,
                            isExpanded: isExpanded,
                            summary: summary,
                            terminalExitCode: presentation.terminalExitCode
                        )
                        .contentShape(.rect)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(ToolEventPresentation.title(for: event.name))，\(summary.text)，\(ToolEventPresentation.statusTitle(event.status))"
                )
                .accessibilityHint(isExpanded ? "Collapse tool content" : "Expand tool content")

                Button(action: onInspect) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View tool details")
            }

            if isExpanded {
                NativeToolEventBody(presentation: presentation, event: event)
                    .padding(.leading, 22)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func measurementContent(summary: NativeToolEventRowSummary) -> String {
        [
            event.callID,
            event.name,
            event.status.rawValue,
            summary.text,
            summary.suffix ?? "",
            isLive ? "live" : "settled"
        ].joined(separator: "\u{1f}")
    }
}

private struct ToolEventSummaryRow: View {
    let event: AgentToolEvent
    let isLive: Bool
    let isExpanded: Bool
    let summary: NativeToolEventRowSummary
    let terminalExitCode: Int?

    var body: some View {
        HStack(spacing: 6) {
            HarnessIconTile(
                systemImage: isExpanded
                    ? "chevron.down"
                    : ToolEventPresentation.icon(for: event.name),
                tint: summary.isError ? .red : ToolEventPresentation.tint(for: event.status),
                size: 28
            )

            Text(ToolEventPresentation.title(for: event.name))
                .font(.footnote.weight(.medium))
                .lineLimit(1)

            if !summary.text.isEmpty {
                Circle()
                    .fill(.tertiary)
                    .frame(width: 2, height: 2)
                    .accessibilityHidden(true)

                Text(summary.text)
                    .font(.caption)
                    .foregroundStyle(summary.isError ? .red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let suffix = summary.suffix {
                    Text(suffix)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Spacer(minLength: 6)
            ToolEventStatusView(
                status: event.status,
                isLive: isLive,
                terminalExitCode: terminalExitCode
            )
        }
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolEventStatusView: View {
    let status: AgentToolEventStatus
    let isLive: Bool
    let terminalExitCode: Int?

    var body: some View {
        HStack(spacing: 5) {
            if isLive, status == .pending || status == .awaitingApproval || status == .running {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusTint)
            }
            Text(statusTitle)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var hasFailingExit: Bool {
        status == .succeeded && (terminalExitCode ?? 0) != 0
    }

    private var statusTitle: String {
        if hasFailingExit, let terminalExitCode {
            return "Exit \(terminalExitCode)"
        }
        return ToolEventPresentation.statusTitle(status)
    }

    private var statusIcon: String {
        hasFailingExit ? "xmark.circle.fill" : ToolEventPresentation.statusIcon(status)
    }

    private var statusTint: Color {
        hasFailingExit ? .red : ToolEventPresentation.tint(for: status)
    }
}

private struct ToolEventOutputView: View {
    let event: AgentToolEvent
    let maximumCharacters: Int

    var body: some View {
        if !event.output.isEmpty {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(event.output) { chunk in
                        Text(limited(chunk.text))
                            .font(.caption.monospaced())
                            .foregroundStyle(ToolEventPresentation.outputTint(chunk.channel))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 180)
            .padding(8)
            .background(.black.opacity(0.86), in: .rect(cornerRadius: 6))
            .accessibilityLabel("Tool output")
        } else if let result = event.result, !result.isEmpty {
            Text(limited(result))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func limited(_ text: String) -> String {
        guard text.count > maximumCharacters else { return text }
        return String(text.prefix(maximumCharacters)) + "\n[UI output truncated]"
    }
}

private struct ToolEventInspectorView: View {
    @Environment(\.dismiss) private var dismiss

    let event: AgentToolEvent

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Tool", value: ToolEventPresentation.title(for: event.name))
                    LabeledContent("Status", value: ToolEventPresentation.statusTitle(event.status))
                    if !event.summary.isEmpty {
                        Text(event.summary)
                            .textSelection(.enabled)
                    }
                    if let startedAt = event.startedAt {
                        LabeledContent("Started") {
                            Text(startedAt, format: .dateTime.hour().minute().second())
                        }
                    }
                    if let finishedAt = event.finishedAt {
                        LabeledContent("Ended") {
                            Text(finishedAt, format: .dateTime.hour().minute().second())
                        }
                    }
                } header: {
                    Label("Status", systemImage: "waveform.path.ecg")
                }

                Section {
                    Text(event.arguments)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Label("Arguments", systemImage: "slider.horizontal.3")
                }

                if !event.output.isEmpty {
                    Section {
                        ToolEventOutputView(event: event, maximumCharacters: 64 * 1_024)
                    } header: {
                        Label("Output", systemImage: "arrow.up.doc")
                    }
                }

                if let result = event.result, !result.isEmpty {
                    Section {
                        Text(result)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    } header: {
                        Label("Return Value", systemImage: "return")
                    }
                }

                if let errorMessage = event.errorMessage, !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } header: {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    }
                }

                if !event.children.isEmpty {
                    Section {
                        ForEach(event.children) { child in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ToolEventPresentation.title(for: child.name))
                                    .font(.headline)
                                Text(child.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Label("Subtools", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
            }
            .navigationTitle("Tool Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

enum ToolEventPresentation {
    static func title(for name: String) -> String {
        switch name {
        case "shell_execute": "iSH Terminal"
        case "run_code": "Code Mode"
        case "code_execute": "Local Code"
        case "read": "Read File"
        case "write": "Write File"
        case "edit": "Edit File"
        case "job_output": "Background Job Output"
        case "job_list": "Background Jobs"
        case "job_kill": "Stop Background Job"
        case "schedule_create": "Create Scheduled Task"
        case "schedule_list": "Scheduled Tasks"
        case "schedule_delete": "Cancel Scheduled Task"
        case "workspace_list_files": "List Files"
        case "workspace_read_text": "Read File"
        case "workspace_write_text": "Write File"
        case "camera_ocr": "Camera OCR"
        case "vision_analyze": "On-Device Vision"
        case "natural_language_analyze": "On-Device Text Analysis"
        case "speech_synthesize": "Speak Text"
        case "speech_transcribe": "Speech to Text"
        case "maps_search": "Maps Search"
        case "maps_route": "Maps Route"
        case "system_open": "Open System Target"
        case "photo_library_list": "Photo Library"
        case "media_library_search": "Media Search"
        case "media_playback": "Media Playback"
        case "health_query": "Health Data"
        case "bluetooth_scan": "Bluetooth Scan"
        case "calendar_events": "Calendar Events"
        case "reminders_list": "Reminders"
        case "clipboard_read": "Read Clipboard"
        case "clipboard_write": "Write Clipboard"
        case "device_status": "Device Status"
        case "ask_user_question": "Ask User"
        case "exit_plan_mode": "Plan Review"
        case "work_state_set_goal": "Update Goal"
        case "work_state_replace_plan": "Update Plan"
        case "work_state_replace_todos": "Update To-Dos"
        case "contacts_search": "Search Contacts"
        case "location_current": "Current Location"
        case "motion_activity": "Motion Activity"
        case "notification_schedule": "Local Notification"
        case "secure_authenticate": "Device Authentication"
        case "device_time": "Device Time"
        case "device_capabilities": "Device Capabilities"
        case "web_fetch": "Web Fetch"
        case "plugin_marketplace": "Plugin Marketplace"
        case "cordis_inspect_list": "Inspect Cordis Plugins"
        case "cordis_inspect_query": "Query Cordis Capabilities"
        case "cordis_inspect_self": "Inspect Current Cordis Plugin"
        case "cordis_define": "Define Cordis Plugin"
        case "cordis_run": "Run Cordis Plugin"
        case "cordis_stop": "Stop Cordis Plugin"
        case "cordis_undefine": "Remove Cordis Plugin"
        default: name.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func icon(for name: String) -> String {
        switch name {
        case "shell_execute": "terminal"
        case "run_code": "curlybraces.square"
        case "code_execute": "chevron.left.forwardslash.chevron.right"
        case "read": "doc.text.magnifyingglass"
        case "write": "doc.badge.plus"
        case "edit": "square.and.pencil"
        case "job_output": "text.append"
        case "job_list": "list.bullet.rectangle"
        case "job_kill": "stop.circle"
        case "schedule_create": "calendar.badge.plus"
        case "schedule_list": "calendar"
        case "schedule_delete": "calendar.badge.minus"
        case "workspace_list_files": "folder"
        case "workspace_read_text": "doc.text.magnifyingglass"
        case "workspace_write_text": "square.and.pencil"
        case "camera_ocr": "text.viewfinder"
        case "vision_analyze": "viewfinder"
        case "natural_language_analyze": "text.magnifyingglass"
        case "speech_synthesize": "speaker.wave.2"
        case "speech_transcribe": "waveform.badge.mic"
        case "maps_search": "map"
        case "maps_route": "point.topleft.down.to.point.bottomright.curvepath"
        case "system_open": "arrow.up.forward.app"
        case "photo_library_list": "photo.on.rectangle.angled"
        case "media_library_search": "music.note.list"
        case "media_playback": "play.circle"
        case "health_query": "heart.text.square"
        case "bluetooth_scan": "antenna.radiowaves.left.and.right"
        case "calendar_events": "calendar"
        case "reminders_list": "checklist"
        case "clipboard_read", "clipboard_write": "clipboard"
        case "device_status": "iphone.gen3"
        case "ask_user_question": "questionmark.bubble"
        case "exit_plan_mode": "checkmark.rectangle.stack"
        case "work_state_set_goal": "scope"
        case "work_state_replace_plan": "list.bullet.clipboard"
        case "work_state_replace_todos": "checklist"
        case "contacts_search": "person.crop.circle.badge.magnifyingglass"
        case "location_current": "location"
        case "motion_activity": "figure.walk.motion"
        case "notification_schedule": "bell.badge"
        case "secure_authenticate": "faceid"
        case "device_time": "clock"
        case "device_capabilities": "iphone.gen3"
        case "web_fetch": "network"
        case "plugin_marketplace": "puzzlepiece.extension"
        case "cordis_inspect_list", "cordis_inspect_query", "cordis_inspect_self":
            "point.3.connected.trianglepath.dotted"
        case "cordis_define": "plus.square.dashed"
        case "cordis_run": "play.circle"
        case "cordis_stop": "stop.circle"
        case "cordis_undefine": "arrow.uturn.backward.circle"
        default: "wrench.and.screwdriver"
        }
    }

    static func statusTitle(_ status: AgentToolEventStatus) -> String {
        switch status {
        case .pending: "Pending"
        case .awaitingApproval: "Awaiting Approval"
        case .running: "Running"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .denied: "Denied"
        case .interrupted: "Interrupted"
        }
    }

    static func statusIcon(_ status: AgentToolEventStatus) -> String {
        switch status {
        case .pending: "clock"
        case .awaitingApproval: "hand.raised"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .denied: "hand.raised.slash.fill"
        case .interrupted: "stop.circle.fill"
        }
    }

    static func tint(for status: AgentToolEventStatus) -> Color {
        switch status {
        case .pending: .secondary
        case .awaitingApproval: .orange
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
        case .denied: .orange
        case .interrupted: .secondary
        }
    }

    static func background(for status: AgentToolEventStatus) -> Color {
        switch status {
        case .pending, .interrupted: Color(uiColor: .tertiarySystemBackground)
        case .awaitingApproval, .denied: .orange.opacity(0.10)
        case .running: .blue.opacity(0.08)
        case .succeeded: .green.opacity(0.07)
        case .failed: .red.opacity(0.08)
        }
    }

    static func outputTint(_ channel: AgentToolOutputChannel) -> Color {
        switch channel {
        case .stdout: Color(white: 0.92)
        case .stderr: .red.opacity(0.92)
        case .progress: .cyan.opacity(0.92)
        case .system: .yellow.opacity(0.92)
        }
    }
}
