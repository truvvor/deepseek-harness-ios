import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppModel.self) private var model

    @State private var conversationMode = ConversationMode.chat
    @State private var trajectoryState = TrajectoryViewState()
    @State private var draft = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isCameraPresented = false
    @State private var isFileImporterPresented = false
    @State private var triggerSuggestions: InputTriggerSuggestionSnapshot?
    @State private var editingQueuedInput: QueuedAgentInput?
    @State private var queuedEditText = ""
    @State private var editingUserMessage: AgentMessage?
    @State private var userMessageEditText = ""
    @State private var isSettingsPresented = false
    @State private var isJobsPresented = false
    @State private var isSessionOptionsPresented = false
    @State private var isSchedulePanelPresented = false
    @State private var isExportFormatPresented = false
    @State private var isFileExporterPresented = false
    @State private var exportDocument: ConversationExportFileDocument?
    @State private var exportContentType = UTType.json
    @State private var exportFilename = "Harness-Conversation"
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            switch conversationMode {
            case .chat:
                chatSurface
            case .trajectory:
                TrajectoryView(
                    navigationTitle: activeSessionTitle,
                    state: trajectoryState
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.visibleSessionPath.count > 1 {
                SessionBreadcrumbBar(
                    path: model.visibleSessionPath,
                    onOpen: { node in
                        Task { await model.openVisibleSessionPathNode(node) }
                    }
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    model.isSessionModelPickerRequested = true
                } label: {
                    VStack(spacing: 1) {
                            Text(activeSessionTitle)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(model.isRunning ? Color.green : Color.secondary.opacity(0.45))
                                .frame(width: 5, height: 5)
                            Text("\(model.effectiveConfiguration.model) · \(model.interactionMode.title)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 220)
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning)
                .accessibilityLabel("Choose model, current: \(model.effectiveConfiguration.model)")
            }

            ToolbarItem(placement: .topBarTrailing) {
                sessionOptionsButton
            }

        }
        .sheet(isPresented: $isSessionOptionsPresented) {
            NavigationStack {
                sessionOptionsPanel
                    // The session controls are deliberately entered through the
                    // compact top-right ellipsis. Repeating a four-character
                    // title in the sheet made it look like an in-content button
                    // on compact iPhone navigation bars.
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task {
            consumePendingDraft()
            await model.refreshVisibleJobs()
        }
        .onChange(of: model.pendingDraft) {
            consumePendingDraft()
        }
        .onChange(of: model.activeSessionID) {
            consumePendingDraft()
            Task { await model.refreshVisibleJobs() }
        }
        .task(id: selectedPhoto) {
            guard let selectedPhoto else { return }
            do {
                guard let data = try await selectedPhoto.loadTransferable(type: Data.self) else {
                    throw CameraPickerError.noImageData
                }
                await model.stageImage(data)
            } catch is CancellationError {
                return
            } catch {
                model.presentError(error)
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.pdf, .audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else {
                    model.presentError(
                        NSError(
                            domain: "HarnessMobile",
                            code: 400,
                            userInfo: [
                                NSLocalizedDescriptionKey: "There are no files to import."
                            ]
                        )
                    )
                    return
                }
                Task { await model.stageFileAttachment(from: url) }
            case let .failure(error):
                model.presentError(error)
            }
        }
        .task(id: draft) {
            let requestedDraft = draft
            let snapshot = await model.inputTriggerSuggestions(
                for: requestedDraft,
                draftRevision: 0
            )
            guard !Task.isCancelled, requestedDraft == draft else { return }
            triggerSuggestions = snapshot
        }
        .sheet(isPresented: $isCameraPresented) {
            CameraPicker { data in
                isCameraPresented = false
                guard let data else { return }
                Task {
                    await model.stageImage(data)
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                SettingsView()
            }
        }
        .sheet(isPresented: $isJobsPresented) {
            JobsPanelView()
        }
        .sheet(isPresented: $isSchedulePanelPresented) {
            HarnessSchedulePanel(
                store: model.scheduleStore,
                sessionID: model.activeSessionID?.uuidString ?? ""
            ) {
                isSchedulePanelPresented = false
            }
        }
        .sheet(isPresented: agentPresetPickerPresented) {
            AgentPresetPickerView()
        }
        .sheet(isPresented: modelPickerPresented) {
            SessionModelPickerView()
        }
        .sheet(item: pendingUserQuestion) { pending in
            UserQuestionSheet(pending: pending)
        }
        .sheet(item: commandOutput) { output in
            DirectCommandOutputView(output: output)
        }
        .sheet(item: pendingCommandInteraction) { pending in
            SlashCommandInteractionSheet(pending: pending) { response in
                model.resolveSlashCommandInteraction(response)
            }
        }
        .sheet(item: $editingQueuedInput) { input in
            EditQueuedInputView(
                text: $queuedEditText,
                disposition: input.disposition,
                onSave: {
                    model.updateQueuedInput(id: input.id, text: queuedEditText)
                    editingQueuedInput = nil
                }
            )
        }
        .sheet(item: $editingUserMessage) { message in
            EditUserMessageView(
                text: $userMessageEditText,
                onRerun: {
                    model.editAndRerunUserMessage(
                        id: message.id,
                        text: userMessageEditText
                    )
                    editingUserMessage = nil
                }
            )
        }
        .confirmationDialog(
            "Export Redacted Conversation",
            isPresented: $isExportFormatPresented,
            titleVisibility: .visible
        ) {
            Button("JSON") { prepareExport(.json) }
            Button("Markdown") { prepareExport(.markdown) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Export removes raw tool arguments and masks common API tokens. The file is created only in the location you choose.")
        }
        .fileExporter(
            isPresented: $isFileExporterPresented,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            exportDocument = nil
            if case let .failure(error) = result {
                model.presentError(error)
            }
        }
        .confirmationDialog(
            "Allow Local Tool?",
            isPresented: approvalPresented,
            titleVisibility: .visible
        ) {
            Button("Deny", role: .cancel) {
                model.resolveApproval(.deny)
            }
            if model.pendingApproval != nil {
                Button("Allow Once") {
                    model.resolveApproval(.allowOnce)
                }
                Button("Always Allow This Scope") {
                    model.resolveApproval(.trustScope)
                }
                if model.pendingApproval?.risk != .destructive {
                    Button("Always Allow On-Device Tools") {
                        model.resolveApproval(.trustDevice)
                    }
                }
            }
        } message: {
            if let approval = model.pendingApproval {
                Text(
                    "\(approval.summary)\n\nCurrent scope: \(approval.scope.chatResourceSummary)\n\nThe tool runs only on this device; its text output will be sent to \(approval.modelHost) for further reasoning. \(approval.risk == .destructive ? "Destructive operations can only be permanently allowed for this exact scope, not with a device-wide grant." : "You can permanently allow this scope or routine on-device tools.") Persistent Harness grants can be revoked in Settings and never bypass iOS system permissions such as Photos, Contacts, or Location."
                )
            }
        }
    }

    @ViewBuilder
    private var sessionOptionsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    conversationMode = .chat
                    isSessionOptionsPresented = false
                } label: {
                    optionLabel("Chat", systemImage: "bubble.left.and.bubble.right", selected: conversationMode == .chat)
                }
                .accessibilityIdentifier("Chat")

                Button {
                    conversationMode = .trajectory
                    isSessionOptionsPresented = false
                } label: {
                    optionLabel("Trajectory", systemImage: "point.3.connected.trianglepath.dotted", selected: conversationMode == .trajectory)
                }
                .accessibilityIdentifier("Trajectory")

                Divider()

                Button {
                    model.isSessionAgentPresetPickerRequested = true
                    isSessionOptionsPresented = false
                } label: {
                    Label(
                        "Agent Preset: \(model.activeAgentPreset?.displayName ?? model.controlState.agentPresetID)",
                        systemImage: "switch.2"
                    )
                }
                .disabled(model.isRunning)

                Divider()

                Picker("Run Mode", selection: modeBinding) {
                    ForEach(ConversationInteractionMode.allCases) { mode in
                        Label(mode.title, systemImage: mode == .agent ? "sparkles" : "list.bullet.clipboard")
                            .tag(mode)
                    }
                }
                .disabled(model.isRunning)

                Picker("Tool Permissions", selection: permissionModeBinding) {
                    ForEach(ToolPermissionMode.allCases) { permission in
                        Label(permission.title, systemImage: permission.systemImage)
                            .tag(permission)
                    }
                }
                .disabled(model.isRunning)

                Divider()

                Button {
                    model.isSessionModelPickerRequested = true
                    isSessionOptionsPresented = false
                } label: {
                    Label("Switch Model", systemImage: "cpu")
                }
                .disabled(model.isRunning)

                Button {
                    isSettingsPresented = true
                    isSessionOptionsPresented = false
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }

                Button {
                    isJobsPresented = true
                    isSessionOptionsPresented = false
                } label: {
                    Label("Background Jobs", systemImage: "list.bullet.rectangle")
                }

                Button {
                    isSessionOptionsPresented = false
                    isSchedulePanelPresented = true
                } label: {
                    Label("Scheduled Reminders", systemImage: "clock.badge.checkmark")
                }
                .accessibilityIdentifier("Scheduled Reminders")

                Button {
                    isExportFormatPresented = true
                    isSessionOptionsPresented = false
                } label: {
                    Label("Export Conversation", systemImage: "square.and.arrow.up")
                }
                .disabled(model.messages.isEmpty)
            }
            .padding(16)
            .frame(minWidth: 260, alignment: .leading)
        }
    }

    private var sessionOptionsButton: some View {
        Button {
            isSessionOptionsPresented = true
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Session Options")
        .accessibilityHint("Opens chat, trajectory, model, and tool permission options")
        .accessibilityIdentifier("Session Options")
    }

    private func optionLabel(_ title: String, systemImage: String, selected: Bool) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 16)
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    private var chatSurface: some View {
        ConversationScroller(
            model: model,
            onStartInput: { isInputFocused = true },
            onEditUserMessage: beginEditingUserMessage
        )
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                ConversationWorkStateDock()

                ChatInputBar(
                    draft: $draft,
                    selectedPhoto: $selectedPhoto,
                    isRunning: model.isChatBusy,
                    isSubmitting: model.isSubmitting,
                    submissionStatus: model.submissionStatus,
                    hasStagedImage: model.hasStagedImage,
                    hasStagedFile: model.hasStagedFile,
                    queuedInputs: model.queuedInputs,
                    triggerGroups: triggerSuggestions?.groups ?? [],
                    onCamera: {
                        isCameraPresented = true
                    },
                    onPickFile: {
                        isFileImporterPresented = true
                    },
                    onShowCommands: showCommands,
                    onSelectSuggestion: selectSuggestion,
                    onSend: send,
                    onCancel: model.cancelActiveTurn,
                    onEditQueuedInput: beginEditingQueuedInput,
                    onRemoveQueuedInput: model.removeQueuedInput,
                    onSteerQueuedInput: model.steerQueuedInput,
                    onSteerAll: model.steerAllQueuedInputs
                )
                .focused($isInputFocused)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = model.errorMessage {
                ChatErrorBanner(message: errorMessage) {
                    model.errorMessage = nil
                }
            }
        }
    }

    private var approvalPresented: Binding<Bool> {
        Binding(
            get: { model.pendingApproval != nil },
            set: { presented in
                if !presented, model.pendingApproval != nil {
                    model.resolveApproval(approved: false)
                }
            }
        )
    }

    private var modeBinding: Binding<ConversationInteractionMode> {
        Binding(
            get: { model.interactionMode },
            set: { model.setInteractionMode($0) }
        )
    }

    private var permissionModeBinding: Binding<ToolPermissionMode> {
        Binding(
            get: { model.permissionMode },
            set: { model.setPermissionMode($0) }
        )
    }

    private var modelPickerPresented: Binding<Bool> {
        Binding(
            get: { model.isSessionModelPickerRequested },
            set: { model.isSessionModelPickerRequested = $0 }
        )
    }

    private var agentPresetPickerPresented: Binding<Bool> {
        Binding(
            get: { model.isSessionAgentPresetPickerRequested },
            set: { model.isSessionAgentPresetPickerRequested = $0 }
        )
    }

    private var commandOutput: Binding<DirectCommandOutput?> {
        Binding(
            get: { model.directCommandOutput },
            set: { model.directCommandOutput = $0 }
        )
    }

    private var pendingCommandInteraction: Binding<PendingSlashCommandInteraction?> {
        Binding(
            get: { model.pendingSlashCommandInteraction },
            set: { value in
                if value == nil, model.pendingSlashCommandInteraction != nil {
                    model.resolveSlashCommandInteraction(.cancelled)
                }
            }
        )
    }

    private var pendingUserQuestion: Binding<ContinuationUserQuestionProvider.Pending?> {
        Binding(
            get: { model.pendingUserQuestion },
            set: { value in
                if value == nil, model.pendingUserQuestion != nil {
                    model.cancelPendingUserQuestion()
                }
            }
        )
    }

    private func send(disposition: QueuedInputDisposition) {
        let text = draft
        guard !model.isSubmitting,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { @MainActor in
            let accepted = await model.submit(text, disposition: disposition)
            guard accepted, draft == text else { return }
            draft = ""
        }
    }

    private func beginEditingUserMessage(_ message: AgentMessage) {
        guard !model.isRunning, !model.isSubmitting else { return }
        userMessageEditText = message.content
        editingUserMessage = message
    }

    private func showCommands() {
        if draft.isEmpty {
            draft = "/"
        } else if draft.last?.isWhitespace == true {
            draft.append("/")
        } else {
            draft.append(" /")
        }
        isInputFocused = true
    }

    private func selectSuggestion(_ suggestion: InputTriggerSuggestion) {
        guard let snapshot = triggerSuggestions,
              snapshot.draft == draft,
              let updated = InputTriggerDetector.replacing(
                  draft,
                  span: snapshot.hit.span,
                  with: suggestion.replacementText,
                  currentRevision: snapshot.hit.span.draftRevision
              ) else { return }
        draft = updated
        triggerSuggestions = nil

        if snapshot.hit.position == .leading,
           case let .command(command) = suggestion.kind {
            switch command.name {
            case "model":
                draft = ""
                model.isSessionModelPickerRequested = true
            case "agent":
                draft = ""
                model.isSessionAgentPresetPickerRequested = true
            default:
                break
            }
        }
        isInputFocused = true
    }

    private func beginEditingQueuedInput(_ input: QueuedAgentInput) {
        queuedEditText = input.text
        editingQueuedInput = input
    }

    private var activeSessionTitle: String {
        model.sessions.first(where: { $0.id == model.activeSessionID })?.title ?? "Harness"
    }

    private func prepareExport(_ format: ConversationExportFormat) {
        guard let sessionID = model.activeSessionID else {
            model.errorMessage = "There is no session to export."
            return
        }
        do {
            let configuration = model.effectiveConfiguration
            let data = try ConversationExportBuilder.makeData(
                input: ConversationExportInput(
                    sessionID: sessionID,
                    title: activeSessionTitle,
                    providerID: configuration.providerID.rawValue,
                    model: configuration.model,
                    messages: model.messages
                ),
                format: format
            )
            exportDocument = ConversationExportFileDocument(data: data)
            exportContentType = format == .json
                ? .json
                : ConversationExportFileDocument.markdownContentType
            exportFilename = sanitizedExportFilename(
                "\(activeSessionTitle)-\(sessionID.uuidString.prefix(8))"
            )
            isFileExporterPresented = true
        } catch {
            model.presentError(error)
        }
    }

    private func sanitizedExportFilename(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "-")
        return String(cleaned.prefix(120))
    }

    private func consumePendingDraft() {
        guard let pendingDraft = model.pendingDraft else { return }
        draft = pendingDraft
        model.pendingDraft = nil
        isInputFocused = true
    }
}

private struct ChatErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: HarnessTheme.Spacing.medium) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: HarnessTheme.Spacing.xSmall) {
                Text("Task Incomplete")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.leading, HarnessTheme.Spacing.large)
        .padding(.trailing, HarnessTheme.Spacing.small)
        .padding(.vertical, HarnessTheme.Spacing.small)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-error-banner")
    }
}

private struct SessionBreadcrumbBar: View {
    let path: [HarnessSessionPathNode]
    let onOpen: (HarnessSessionPathNode) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(path.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }

                    Button {
                        onOpen(node)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: index == 0 ? "house" : statusIcon(node.status))
                            Text(node.label)
                                .lineLimit(1)
                        }
                        .font(.caption.weight(node.isCurrent ? .semibold : .regular))
                        .foregroundStyle(node.isCurrent ? Color.primary : Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            node.isCurrent ? Color.secondary.opacity(0.12) : Color.clear,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(node.isCurrent)
                    .accessibilityLabel(
                        node.isCurrent
                            ? "Current subagent, \(node.label), depth \(node.depth)"
                            : "Back to \(node.label), depth \(node.depth)"
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-breadcrumb")
    }

    private func statusIcon(_ status: HarnessJobStatus?) -> String {
        switch status {
        case .running: "bolt.horizontal.circle.fill"
        case .stopping: "hourglass.circle"
        case .completed: "checkmark.circle.fill"
        case .killed: "stop.circle"
        case .failed: "exclamationmark.triangle.fill"
        case nil: "circle"
        }
    }
}

private extension ToolApprovalScope {
    var chatResourceSummary: String {
        resources.map { resource in
            switch resource {
            case "tool":
                "Entire \(toolName) tool"
            case "workspace:root":
                "App workspace"
            case "ish-sandbox:/workspace":
                "iSH /workspace sandbox"
            default:
                resource.replacingOccurrences(of: "workspace:file:", with: "Workspace file: ")
            }
        }
        .joined(separator: ", ")
    }
}

private enum ConversationMode: String, CaseIterable, Identifiable {
    case chat
    case trajectory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .trajectory: "Trajectory"
        }
    }
}

private struct ConversationViewportHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ConversationBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// `minY` of the conversation's first row in the scroll coordinate space:
/// 0 when the top is at the viewport top, negative while scrolled down.
private struct ConversationTopPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = -.greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ConversationScroller: View {
    let model: AppModel
    let onStartInput: () -> Void
    let onEditUserMessage: (AgentMessage) -> Void

    @State private var renderedMessageLimit = 80
    @State private var renderedMessages: [AgentMessage] = []
    @State private var hiddenMessageCount = 0
    @State private var availableMessageCount = 0
    @State private var followsConversationTail = true
    @State private var automaticScrollTask: Task<Void, Never>?
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var isLoadingEarlier = false
    @State private var lastTopSample: (y: CGFloat, at: TimeInterval)?
    @State private var scrollVelocity: CGFloat = 0
    /// `minY` of the conversation's end in the scroll coordinate space; the
    /// end is on screen while it is below `scrollViewportHeight`.
    @State private var lastBottomOffset: CGFloat = .greatestFiniteMagnitude

    private let bottomID = "conversation-bottom"
    /// Rows added per load, from the in-memory window first, then from the
    /// mirror's transcript store.
    private let earlierPageSize = 80

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ConversationTimeline(
                    hasResumableRun: model.hasResumableRun,
                    isRunning: model.isChatBusy,
                    omittedContextMessages: model.omittedContextMessages,
                    messages: renderedMessages,
                    hiddenMessageCount: hiddenMessageCount
                        + (model.activeDesktopMirrorHasOlderMessages ? model.desktopMirrorLoadedStart : 0),
                    contextInjections: model.activeContextInjections,
                    activeRunID: model.activeRunID,
                    streamingReasoning: model.streamingReasoning,
                    streamingText: model.streamingText,
                    activeToolStatus: model.activeToolStatus,
                    activeToolEvents: model.activeToolEvents,
                    runStartedAt: model.chatRunStartedAt,
                    pendingQuestionCount: model.pendingUserQuestion?.request.questions.count ?? 0,
                    pendingQuestionTitle: model.pendingUserQuestion?.request.questions.first?.question,
                    metrics: model.trajectoryMetrics,
                    bottomID: bottomID,
                    onResume: model.resumePendingRun,
                    onLoadEarlierMessages: { loadEarlierMessages(proxy) },
                    onStartInput: onStartInput,
                    onRetryUserMessage: model.retryFromUserMessage,
                    onEditUserMessage: onEditUserMessage,
                    onToggleFeedback: model.toggleMessageFeedback,
                    onUpdateFeedbackNote: model.updateMessageFeedbackNote
                )
                .padding(.horizontal)
                .padding(.top, 12)
            }
            .coordinateSpace(.named("conversation-scroll"))
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ConversationViewportHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        followsConversationTail = false
                        automaticScrollTask?.cancel()
                        automaticScrollTask = nil
                    }
            )
            .onPreferenceChange(ConversationViewportHeightPreferenceKey.self) {
                scrollViewportHeight = $0
            }
            .onPreferenceChange(ConversationTopPreferenceKey.self) { top in
                handleTopOffset(top, proxy: proxy)
            }
            .onPreferenceChange(ConversationBottomPreferenceKey.self) { bottom in
                lastBottomOffset = bottom
                guard !followsConversationTail,
                      scrollViewportHeight > 0,
                      bottom <= scrollViewportHeight + 72 else {
                    return
                }
                followsConversationTail = true
            }
            .task(id: model.activeSessionID) {
                renderedMessageLimit = 80
                followsConversationTail = true
                refreshRenderedMessages()
                scheduleAutomaticScroll(proxy)
            }
            .onChange(of: model.messagesRevision) {
                // While the reader is back in history, rows arriving at the end
                // must not push the oldest rendered rows out of the window: that
                // moved the content under the viewport. Grow the window instead.
                if !followsConversationTail {
                    let total = ConversationMessageWindow.project(model.messages, limit: .max).totalCount
                    if total > availableMessageCount {
                        renderedMessageLimit += total - availableMessageCount
                    }
                }
                refreshRenderedMessages()
                scheduleAutomaticScroll(proxy)
            }
            .onChange(of: model.streamingPresentationRevision) {
                scheduleAutomaticScroll(proxy)
            }
            .onDisappear {
                automaticScrollTask?.cancel()
                automaticScrollTask = nil
            }
        }
    }

    /// Prefetches earlier rows while the user scrolls back. The trigger
    /// distance grows with the upward scroll velocity, so a fast flick has
    /// the next page in place before the top of the loaded rows is reached.
    private func handleTopOffset(_ top: CGFloat, proxy: ScrollViewProxy) {
        let now = ProcessInfo.processInfo.systemUptime
        if let sample = lastTopSample, now > sample.at {
            // Positive while the content moves down, i.e. scrolling toward
            // older rows.
            let instantaneous = (top - sample.y) / CGFloat(now - sample.at)
            scrollVelocity = scrollVelocity * 0.5 + instantaneous * 0.5
        }
        lastTopSample = (top, now)
        guard !followsConversationTail, !isLoadingEarlier, scrollViewportHeight > 0 else { return }
        // Only a reader who has left the live end by more than a screen wants
        // older rows; near the end, a short loaded window must never trigger a
        // load that re-anchors the viewport up into history.
        guard lastBottomOffset - scrollViewportHeight > scrollViewportHeight else { return }
        let hasEarlier = hiddenMessageCount > 0 || model.activeDesktopMirrorHasOlderMessages
        guard hasEarlier else { return }
        let lead = 1 + min(3, max(0, scrollVelocity) / 1_000)
        let threshold = max(scrollViewportHeight, 400) * lead
        guard top > -threshold else { return }
        loadEarlierMessages(proxy)
    }

    private func loadEarlierMessages(_ proxy: ScrollViewProxy) {
        guard !isLoadingEarlier else { return }
        isLoadingEarlier = true
        followsConversationTail = false
        let anchorID = renderedMessages.first.map { ConversationPresentationItem.message($0).id }
        Task { @MainActor in
            defer {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    isLoadingEarlier = false
                }
            }
            if hiddenMessageCount > 0 {
                renderedMessageLimit = min(availableMessageCount, renderedMessageLimit + earlierPageSize)
            } else if model.activeDesktopMirrorHasOlderMessages {
                let added = await model.loadOlderDesktopMirrorMessages(limit: earlierPageSize)
                guard added > 0 else { return }
                renderedMessageLimit += added
            } else {
                return
            }
            refreshRenderedMessages()
            // Keep the previously first row where it was so the prepended rows
            // appear above it instead of shifting the viewport.
            if let anchorID {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(anchorID, anchor: .top)
                }
            }
        }
    }

    private func refreshRenderedMessages() {
        let window = ConversationMessageWindow.project(
            model.messages,
            limit: renderedMessageLimit
        )
        renderedMessages = window.messages
        hiddenMessageCount = window.hiddenCount
        availableMessageCount = window.totalCount
    }

    /// Keep at most one pending scroll. Continuous model deltas then produce a
    /// bounded 8 Hz scroll cadence instead of cancelling and reallocating a task
    /// for every presentation update.
    private func scheduleAutomaticScroll(_ proxy: ScrollViewProxy) {
        guard followsConversationTail, automaticScrollTask == nil else { return }
        automaticScrollTask = Task { @MainActor in
            defer { automaticScrollTask = nil }
            do {
                try await Task.sleep(for: .milliseconds(125))
            } catch {
                return
            }
            guard !Task.isCancelled, followsConversationTail else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            // Lazy rows are measured as they render, so the first scroll can
            // land short of the end; settle once more after they have.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, followsConversationTail else { return }
            withTransaction(transaction) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }
}

private struct ConversationTimeline: View {
    let hasResumableRun: Bool
    let isRunning: Bool
    let omittedContextMessages: Int
    let messages: [AgentMessage]
    let hiddenMessageCount: Int
    let contextInjections: [AgentContextInjection]
    let activeRunID: UUID?
    let streamingReasoning: String
    let streamingText: String
    let activeToolStatus: String?
    let activeToolEvents: [AgentToolEvent]
    let runStartedAt: Date?
    let pendingQuestionCount: Int
    let pendingQuestionTitle: String?
    let metrics: SessionTrajectoryMetrics?
    let bottomID: String
    let onResume: () -> Void
    let onLoadEarlierMessages: () -> Void
    let onStartInput: () -> Void
    let onRetryUserMessage: (UUID) -> Void
    let onEditUserMessage: (AgentMessage) -> Void
    let onToggleFeedback: (UUID, MessageFeedbackRating) -> Void
    let onUpdateFeedbackNote: (UUID, String) -> Void

    var body: some View {
        LazyVStack(spacing: 14) {
            Color.clear
                .frame(height: 1)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ConversationTopPreferenceKey.self,
                            value: proxy.frame(in: .named("conversation-scroll")).minY
                        )
                    }
                }

            if hiddenMessageCount > 0 {
                Button(action: onLoadEarlierMessages) {
                    Label(
                        "Show \(min(hiddenMessageCount, 80)) earlier messages",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("load-earlier-messages")
                .accessibilityValue("\(hiddenMessageCount) earlier messages remaining")
            }

            if hasResumableRun, !isRunning {
                Button(action: onResume) {
                    Label("Resume Unfinished Task", systemImage: "arrow.clockwise.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("resume-agent-run")
            }

            if omittedContextMessages > 0 {
                Label(
                    "Earlier context compacted on device (\(omittedContextMessages) omitted)",
                    systemImage: "archivebox"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if messages.isEmpty, streamingText.isEmpty, !isRunning {
                Button(action: onStartInput) {
                    VStack(spacing: 12) {
                        HarnessIconTile(systemImage: "sparkles", tint: .secondary, size: 40)
                        Text("What can I help with?")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 104)
            }

            ForEach(messages) { message in
                VStack(alignment: .leading, spacing: 14) {
                    MessageBubble(
                        message: message,
                        canRerunUserMessage: !isRunning,
                        retryUserMessageID: messageActionTargets[message.id],
                        onRetryUserMessage: onRetryUserMessage,
                        onEditUserMessage: onEditUserMessage,
                        onToggleFeedback: onToggleFeedback,
                        onUpdateFeedbackNote: onUpdateFeedbackNote
                    )
                    .equatable()

                    if message.id == latestUserMessageID, !contextInjections.isEmpty {
                        ContextInjectionList(injections: contextInjections)
                    }
                }
                .id(ConversationPresentationItem.message(message).id)
            }

            if !streamingReasoning.isEmpty || !streamingText.isEmpty {
                StreamingMessageBubble(
                    runID: activeRunID?.uuidString ?? "session-stream",
                    reasoning: streamingReasoning,
                    text: streamingText
                )
                .id(
                    ConversationPresentationItemID.streaming(
                        runID: activeRunID?.uuidString ?? "session-stream",
                        kind: "assistant"
                    )
                )
            }

            if !activeToolEvents.isEmpty {
                ToolEventTreeView(events: activeToolEvents, isLive: isRunning)
            } else if let activeToolStatus {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(activeToolStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            if pendingQuestionCount > 0 {
                PendingQuestionStatus(
                    count: pendingQuestionCount,
                    title: pendingQuestionTitle
                )
            }

            if isRunning {
                HarnessRunStatus(startedAt: runStartedAt)
            }

            if let metrics, metrics.steps > 0 || metrics.calls > 0 || metrics.outputTokens > 0 {
                ConversationMetricsStrip(metrics: metrics)
            }

            Color.clear
                .frame(height: 1)
                .id(bottomID)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ConversationBottomPreferenceKey.self,
                            value: proxy.frame(in: .named("conversation-scroll")).minY
                        )
                    }
                }
        }
    }

    private var latestUserMessageID: UUID? {
        messages.last(where: { $0.role == .user })?.id
    }

    private var messageActionTargets: [UUID: UUID] {
        ConversationMessageActionTargets.resolve(messages).retryUserMessageIDByMessageID
    }

}

private struct ContextInjectionList: View {
    let injections: [AgentContextInjection]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(injections) { injection in
                ContextInjectionRow(injection: injection)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Injected context")
    }
}

private struct ContextInjectionRow: View {
    let injection: AgentContextInjection

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    HarnessIconTile(
                        systemImage: injection.form == "catalog" ? "books.vertical" : "arrow.turn.down.right",
                        tint: .secondary,
                        size: 24
                    )
                    Text(injection.sourceLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let formLabel {
                        Text(formLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(injection.sourceLabel) context")
            .accessibilityHint(isExpanded ? "Collapse injected content" : "Expand injected content")

            if isExpanded {
                ScrollView {
                    Text(injection.content)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .padding(.leading, 23)
            }
        }
    }

    private var formLabel: String? {
        switch injection.form {
        case "catalog": "catalog"
        case "instructions": "instructions"
        case "opaque": nil
        case let value?: value
        case nil: nil
        }
    }
}

private struct PendingQuestionStatus: View {
    let count: Int
    let title: String?

    var body: some View {
        HStack(spacing: 9) {
            HarnessIconTile(systemImage: "questionmark.bubble.fill", tint: .orange, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Waiting for Your Answer")
                    .font(.caption.weight(.semibold))
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("\(count) questions")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waiting for your answer, \(count) questions")
    }
}

private struct HarnessRunStatus: View {
    let startedAt: Date?

    @State private var mountedAt = Date.now

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt ?? mountedAt))
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Working deeply…")
                    .font(.caption.weight(.medium))
                if elapsed >= 15 {
                    Text(Self.duration(elapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Working deeply, running for \(Self.duration(elapsed))")
        }
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 { return "\(minutes)m \(remainder)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

private struct ConversationMetricsStrip: View {
    let metrics: SessionTrajectoryMetrics

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                metric("Turns", String(metrics.turns))
                metric("Steps", String(metrics.steps))
                metric("Calls", String(metrics.calls))
                metric("LLM", duration(metrics.modelDurationMilliseconds))
                metric("Tools", duration(metrics.toolDurationMilliseconds))
                metric("TTFT", metrics.averageTTFTMilliseconds.map(duration) ?? "-")
                metric("Tok/s", tokensPerSecond)
                metric("Cache", CacheHitRateFormat.percent(metrics.cacheHitRate))
                metric("Input", count(metrics.uncachedInputTokens + metrics.cacheReadTokens))
                metric("Output", count(metrics.outputTokens))
            }
            .padding(.horizontal, 10)
        }
        .scrollIndicators(.hidden)
        .frame(height: 38)
        .background(HarnessTheme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation run statistics")
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private var tokensPerSecond: String {
        guard metrics.decodeDurationMilliseconds > 0 else { return "-" }
        let rate = Double(metrics.decodeTokens) / (metrics.decodeDurationMilliseconds / 1_000)
        return String(format: "%.1f", rate)
    }

    private func duration(_ milliseconds: Double) -> String {
        if milliseconds < 1_000 { return "\(Int(milliseconds.rounded()))ms" }
        return String(format: "%.1fs", milliseconds / 1_000)
    }

    private func count(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }
}

private struct AgentPresetPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.agentPresets) { preset in
                    Button {
                        model.selectAgentPresetFromUI(id: preset.id)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            HarnessIconTile(
                                systemImage: systemImage(for: preset),
                                tint: preset.isMountable ? .accentColor : .secondary,
                                size: 32
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(preset.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if preset.trust == .user {
                                        Text("User")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let description = preset.description {
                                    Text(description)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                if let broken = preset.broken {
                                    Label(broken, systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 8)
                            if selectedPresetID == preset.id {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            } else if !preset.isMountable {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!preset.isMountable || model.isRunning)
                    .accessibilityLabel(preset.displayName)
                    .accessibilityValue(preset.broken ?? (selectedPresetID == preset.id ? "Selected" : "Available"))
                }
            }
            .navigationTitle("Agent Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // All four presets must be reachable without a drag gesture; a medium
        // detent hides the lower half of the lazy list from the accessibility
        // tree as well as from the user.
        .presentationDetents([.large])
    }

    private var selectedPresetID: String {
        model.activeAgentPreset?.id ?? model.controlState.agentPresetID
    }

    private func systemImage(for preset: AgentPresetDefinition) -> String {
        switch preset.id {
        case "cordis": "wand.and.stars"
        case "minimal": "leaf"
        case "code": "chevron.left.forwardslash.chevron.right"
        default: "cpu"
        }
    }
}

private struct JobsPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedJobID: String?
    @State private var isOutputPresented = false
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            Group {
                if model.visibleJobs.isEmpty {
                    ContentUnavailableView(
                        "No Background Jobs",
                        systemImage: "checkmark.circle",
                        description: Text("Background tools and subagents stay here after they finish.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(HarnessTheme.pageBackground)
                } else {
                    List {
                        ForEach(model.visibleJobs, id: \.id) { job in
                            JobPanelRow(
                                job: job,
                                onOutput: {
                                    selectedJobID = job.id
                                    isOutputPresented = true
                                },
                                onStop: {
                                    Task {
                                        do {
                                            try await model.stopVisibleJob(job.id)
                                        } catch {
                                            model.presentError(error)
                                        }
                                    }
                                }
                            )
                        }
                    }
                    .listStyle(.insetGrouped)
                    .environment(\.defaultMinListRowHeight, 44)
                    .scrollContentBackground(.hidden)
                    .background(HarnessTheme.pageBackground)
                }
            }
            .safeAreaInset(edge: .top) {
                if !model.visibleSubagents.isEmpty {
                    SubagentTreeSection(
                        subagents: model.visibleSubagents,
                        onOpen: { subagent in
                            Task {
                                await model.openVisibleSubagent(subagent)
                                dismiss()
                            }
                        },
                        onStop: { subagent in
                            Task {
                                do {
                                    try await model.stopVisibleSubagent(subagent)
                                } catch {
                                    model.presentError(error)
                                }
                            }
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .navigationTitle("Background Jobs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: isRefreshing ? "progress.indicator" : "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("Refresh background jobs")
                }
            }
        }
        .task { await refresh() }
        .sheet(isPresented: $isOutputPresented) {
            if let selectedJobID {
                JobOutputPanelView(jobID: selectedJobID)
            }
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await model.refreshVisibleJobs()
        isRefreshing = false
    }
}

private struct SubagentTreeSection: View {
    let subagents: [HarnessSubagentSnapshot]
    let onOpen: (HarnessSubagentSnapshot) -> Void
    let onStop: (HarnessSubagentSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Subagent", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.subheadline.weight(.semibold))
            ForEach(subagents, id: \.id) { subagent in
                SubagentTreeRow(
                    subagent: subagent,
                    onOpen: { onOpen(subagent) },
                    onStop: { onStop(subagent) }
                )
            }
        }
    }
}

private struct SubagentTreeRow: View {
    let subagent: HarnessSubagentSnapshot
    let onOpen: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HarnessIconTile(systemImage: statusIcon, tint: statusColor, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(subagent.label)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text("Depth \(subagent.delegationDepth) · \(statusTitle)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward.app")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Open subagent")
            if !subagent.status.isTerminal {
                Button(role: .destructive, action: onStop) {
                    Image(systemName: "stop.circle")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop subagent")
            }
        }
        .padding(.leading, CGFloat(max(0, subagent.delegationDepth - 1)) * 16)
    }

    private var statusTitle: String {
        switch subagent.status {
        case .running: "Running"
        case .stopping: "Stopping"
        case .completed: "Completed"
        case .killed: "Stopped"
        case .failed: "Failed"
        }
    }

    private var statusIcon: String {
        switch subagent.status {
        case .running: "bolt.horizontal.circle"
        case .stopping: "hourglass"
        case .completed: "checkmark.circle"
        case .killed: "stop.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch subagent.status {
        case .running: .green
        case .stopping: .orange
        case .completed: .blue
        case .killed: .secondary
        case .failed: .red
        }
    }
}

private struct JobPanelRow: View {
    let job: HarnessJobSnapshot
    let onOutput: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HarnessIconTile(systemImage: statusIcon, tint: statusColor, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.label)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text("\(job.kind) · \(job.id.prefix(12))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            if let detail = job.detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 12) {
                Button(action: onOutput) {
                    Label("View Output", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                if !job.status.isTerminal {
                    Button(role: .destructive, action: onStop) {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .font(.footnote.weight(.medium))
        }
        .padding(.vertical, 4)
    }

    private var statusTitle: String {
        switch job.status {
        case .running: "Running"
        case .stopping: "Stopping"
        case .completed: "Completed"
        case .killed: "Stopped"
        case .failed: "Failed"
        }
    }

    private var statusIcon: String {
        switch job.status {
        case .running: "bolt.horizontal.circle"
        case .stopping: "hourglass"
        case .completed: "checkmark.circle"
        case .killed: "stop.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .running: .green
        case .stopping: .orange
        case .completed: .blue
        case .killed: .secondary
        case .failed: .red
        }
    }
}

private struct JobOutputPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let jobID: String
    @State private var read: HarnessJobRead?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let read {
                    ScrollView {
                        Text(read.text)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(16)
                    }
                } else if let errorMessage {
                    ContentUnavailableView("Unable to Read Output", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else {
                    ProgressView("Reading")
                }
            }
            .navigationTitle("Job Output")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            do {
                read = try await model.readVisibleJob(jobID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
