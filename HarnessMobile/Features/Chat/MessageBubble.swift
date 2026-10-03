import SwiftUI
import UIKit

struct MessageBubble: View, Equatable {
    nonisolated let message: AgentMessage
    let canRerunUserMessage: Bool
    let retryUserMessageID: UUID?
    let onRetryUserMessage: (UUID) -> Void
    let onEditUserMessage: (AgentMessage) -> Void
    let onToggleFeedback: (UUID, MessageFeedbackRating) -> Void
    let onUpdateFeedbackNote: (UUID, String) -> Void

    @State private var feedbackNoteEditor: FeedbackNoteEditor?
    @State private var visibleToolCallLimit = 4
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            VStack(alignment: .leading, spacing: 8) {
                if message.role == .assistant {
                    HStack(spacing: 7) {
                        HarnessIconTile(systemImage: "sparkles", tint: .accentColor, size: 28)
                        Text("DeepSeek Harness")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }

                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    ReasoningDisclosure(
                        reasoning: reasoning,
                        isStreaming: false,
                        presentationID: .reasoning(messageID: message.id)
                    )
                }

                if message.role == .assistant, !message.toolEvents.isEmpty {
                    ToolEventTreeView(events: message.toolEvents, isLive: false)
                } else if message.role == .assistant, !message.toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        if hiddenToolCallCount > 0 {
                            Button {
                                visibleToolCallLimit = min(
                                    message.toolCalls.count,
                                    visibleToolCallLimit + Self.toolCallPageSize
                                )
                            } label: {
                                Label(
                                    "Show \(min(hiddenToolCallCount, Self.toolCallPageSize)) earlier tool calls",
                                    systemImage: "arrow.up.circle"
                                )
                            }
                            .font(.caption.weight(.medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("load-earlier-tool-calls")
                            .accessibilityValue("\(hiddenToolCallCount) earlier tool calls remaining")
                        }

                        ForEach(visibleToolCalls) { call in
                            DisclosureGroup {
                                ConversationMeasuredBlock(
                                    itemID: .toolCall(messageID: message.id, callID: call.id),
                                    kind: "tool-arguments",
                                    content: call.arguments
                                ) {
                                    Text(call.arguments)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.top, 4)
                                }
                            } label: {
                                Label(call.name, systemImage: "wrench.and.screwdriver")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                            }
                        }
                    }
                }

                if !message.content.isEmpty, message.role != .tool {
                    // The durable message is the source of truth. Do not cap,
                    // elide, or append a synthetic end marker to model output.
                    // Long-chat performance belongs to the list window, not the
                    // contents of an individual message.
                    NativeMarkdownText(
                        source: message.content,
                        documentID: "message-\(message.id.uuidString)"
                    )
                }

                if message.role == .tool {
                    ToolEventCard(event: legacyToolEvent, isLive: false) {}
                }

                if message.role != .tool {
                    messageActions
                }
            }
            .padding(message.role == .user ? 12 : 0)
            .background {
                if message.role == .user {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(background)
                }
            }
            .overlay {
                if message.role == .user {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.10), lineWidth: 0.5)
                }
            }
            .frame(
                maxWidth: message.role == .user ? 320 : 620,
                alignment: .leading
            )

            if message.role != .user {
                Spacer(minLength: 12)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message-\(message.role.rawValue)")
        .contextMenu {
            if message.role != .tool, !message.content.isEmpty {
                Button(action: copyMessage) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            if let retryUserMessageID {
                Button {
                    onRetryUserMessage(retryUserMessageID)
                } label: {
                    Label(
                        message.role == .assistant ? "Regenerate Response" : "Retry This Message",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(!canRerunUserMessage)
            }

            if message.role == .user {
                Button {
                    onEditUserMessage(message)
                } label: {
                    Label("Edit and Rerun", systemImage: "pencil")
                }
                .disabled(!canRerunUserMessage)
            }
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
        .sheet(item: $feedbackNoteEditor) { editor in
            MessageFeedbackNoteSheet(
                editor: editor,
                onSave: { note in
                    onUpdateFeedbackNote(message.id, note)
                }
            )
        }
    }

    private var messageActions: some View {
        HStack(spacing: 2) {
            actionButton(
                systemImage: copied ? "checkmark" : "doc.on.doc",
                label: copied ? "Copied" : "Copy",
                disabled: message.content.isEmpty,
                action: copyMessage
            )

            if let retryUserMessageID {
                actionButton(
                    systemImage: "arrow.clockwise",
                    label: message.role == .assistant ? "Regenerate Response" : "Retry This Message",
                    disabled: !canRerunUserMessage
                ) {
                    onRetryUserMessage(retryUserMessageID)
                }
            }

            if message.role == .user {
                actionButton(
                    systemImage: "pencil",
                    label: "Edit and Rerun",
                    disabled: !canRerunUserMessage
                ) {
                    onEditUserMessage(message)
                }
            }

            if message.role == .assistant {
                feedbackButton(
                    rating: .positive,
                    systemImage: "hand.thumbsup",
                    label: "Helpful"
                )
                feedbackButton(
                    rating: .negative,
                    systemImage: "hand.thumbsdown",
                    label: "Needs Improvement"
                )
            }

            if message.role == .assistant, let feedback = message.feedback {
                Button {
                    feedbackNoteEditor = FeedbackNoteEditor(note: feedback.note ?? "")
                } label: {
                    Image(systemName: feedback.note == nil ? "note.text.badge.plus" : "note.text")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(feedback.note == nil ? "Add feedback note" : "Edit feedback note")
                .help(feedback.note == nil ? "Add feedback note" : "Edit feedback note")
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, HarnessTheme.Spacing.xSmall)
        .background(HarnessTheme.subtleFill, in: Capsule())
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
    }

    private func actionButton(
        systemImage: String,
        label: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied && label == "Copied" ? Color.accentColor : Color.secondary)
        .disabled(disabled)
        .accessibilityLabel(label)
        .help(label)
    }

    private func copyMessage() {
        guard !message.content.isEmpty else { return }
        UIPasteboard.general.string = message.content
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            copied = false
            copyResetTask = nil
        }
    }

    private func feedbackButton(
        rating: MessageFeedbackRating,
        systemImage: String,
        label: String
    ) -> some View {
        let isSelected = message.feedback?.rating == rating
        return Button {
            onToggleFeedback(message.id, rating)
        } label: {
            Image(systemName: isSelected ? "\(systemImage).fill" : systemImage)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(label)
    }

    private var legacyToolEvent: AgentToolEvent {
        let call = AgentToolCall(
            id: message.toolCallID ?? message.id.uuidString,
            name: message.toolName ?? "local_tool",
            arguments: "{}"
        )
        let status: AgentToolEventStatus = message.isToolError == true ? .failed : .succeeded
        return AgentToolEvent(
            id: message.id,
            call: call,
            summary: firstResultLine,
            status: status,
            result: message.content,
            errorMessage: message.isToolError == true ? message.content : nil,
            createdAt: message.createdAt,
            startedAt: message.createdAt,
            finishedAt: message.createdAt
        )
    }

    private var firstResultLine: String {
        message.content
            .split(whereSeparator: \Character.isNewline)
            .first
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? ""
    }

    private var background: Color {
        switch message.role {
        case .user:
            return Color(uiColor: .secondarySystemBackground)
        case .assistant:
            return .clear
        case .tool:
            return Color(uiColor: .tertiarySystemBackground)
        }
    }

    private static let toolCallPageSize = 20

    private var visibleToolCalls: ArraySlice<AgentToolCall> {
        message.toolCalls.suffix(visibleToolCallLimit)
    }

    private var hiddenToolCallCount: Int {
        max(0, message.toolCalls.count - visibleToolCalls.count)
    }

    nonisolated static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message
            && lhs.canRerunUserMessage == rhs.canRerunUserMessage
            && lhs.retryUserMessageID == rhs.retryUserMessageID
    }
}

struct EditUserMessageView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let onRerun: () -> Void

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(.horizontal, 12)
                .navigationTitle("Edit Message")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Rerun") {
                            onRerun()
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct FeedbackNoteEditor: Identifiable {
    let id = UUID()
    let note: String
}

private struct MessageFeedbackNoteSheet: View {
    let editor: FeedbackNoteEditor
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note: String

    init(editor: FeedbackNoteEditor, onSave: @escaping (String) -> Void) {
        self.editor = editor
        self.onSave = onSave
        _note = State(initialValue: editor.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $note)
                        .frame(minHeight: 120)
                        .accessibilityLabel("Feedback Note")

                    Text("\(note.utf8.count) / \(MessageFeedback.maximumNoteUTF8Bytes) bytes")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(
                            note.utf8.count > MessageFeedback.maximumNoteUTF8Bytes
                                ? Color.red
                                : Color.secondary
                        )
                } header: {
                    Label("Note", systemImage: "note.text")
                }
            }
            .navigationTitle("Feedback Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(note)
                        dismiss()
                    }
                    .disabled(note.utf8.count > MessageFeedback.maximumNoteUTF8Bytes)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct StreamingMessageBubble: View {
    let runID: String
    let reasoning: String
    let text: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    HarnessIconTile(systemImage: "sparkles", tint: .accentColor, size: 28)
                    Text("DeepSeek Harness")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                if !reasoning.isEmpty {
                    ReasoningDisclosure(
                        reasoning: reasoning,
                        isStreaming: true,
                        presentationID: .streaming(runID: runID, kind: "reasoning")
                    )
                }
                if !text.isEmpty {
                    Text(text)
                        .id(ConversationPresentationItemID.streaming(runID: runID, kind: "text"))
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            Spacer(minLength: 12)
        }
    }
}

private struct ReasoningDisclosure: View {
    let reasoning: String
    let isStreaming: Bool
    let presentationID: ConversationPresentationItemID

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(.secondary)
                    Text("Thinking")
                        .fontWeight(.semibold)
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isStreaming ? "Thinking" : "Reasoning")
            .accessibilityValue(summary)
            .accessibilityHint(isExpanded ? "Collapse full reasoning" : "Expand full reasoning")

            if isExpanded {
                if isStreaming {
                    expandedReasoningText
                } else {
                    ConversationMeasuredBlock(
                        itemID: presentationID,
                        kind: "reasoning-expanded",
                        content: reasoning
                    ) {
                        expandedReasoningText
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }

    private var expandedReasoningText: some View {
        Text(reasoning)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 23)
    }

    private var summary: String {
        let sample = isStreaming
            ? String(reasoning.suffix(800))
            : String(reasoning.prefix(1_600))
        let lines = sample
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return isStreaming ? "Reasoning" : "Completed" }
        let value: String
        if isStreaming {
            value = lines.last ?? "Reasoning"
        } else {
            value = lines.first(where: { !$0.hasPrefix("[") }) ?? lines[0]
        }
        guard value.count > 160 else { return value }
        return String(value.prefix(160)) + "…"
    }
}
