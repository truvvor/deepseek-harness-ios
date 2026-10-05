import PhotosUI
import SwiftUI
import UIKit

struct ChatInputBar: View {
    @Binding var draft: String
    @Binding var selectedPhoto: PhotosPickerItem?

    let isRunning: Bool
    let isSubmitting: Bool
    let submissionStatus: String?
    let hasStagedImage: Bool
    let hasStagedFile: Bool
    let queuedInputs: [QueuedAgentInput]
    let triggerGroups: [InputTriggerSuggestionGroup]
    let onCamera: () -> Void
    let onPickFile: () -> Void
    let onShowCommands: () -> Void
    let onSelectSuggestion: (InputTriggerSuggestion) -> Void
    let onSend: (QueuedInputDisposition) -> Void
    let onCancel: () -> Void
    let onEditQueuedInput: (QueuedAgentInput) -> Void
    let onRemoveQueuedInput: (UUID) -> Void
    let onSteerQueuedInput: (UUID) -> Void
    let onSteerAll: () -> Void

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        hasDraft || hasStagedImage || hasStagedFile
    }

    var body: some View {
        VStack(spacing: 8) {
            if !queuedInputs.isEmpty {
                QueuedInputList(
                    inputs: queuedInputs,
                    onEdit: onEditQueuedInput,
                    onRemove: onRemoveQueuedInput,
                    onSteer: onSteerQueuedInput,
                    onSteerAll: onSteerAll
                )
            }

            if !triggerGroups.isEmpty {
                InputTriggerPalette(
                    groups: triggerGroups,
                    onSelect: onSelectSuggestion
                )
            }

            if hasStagedImage {
                HarnessStatusPill(
                    title: "Image ready for the on-device OCR tool",
                    systemImage: "text.viewfinder",
                    tint: .accentColor
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if hasStagedFile {
                HarnessStatusPill(
                    title: "File ready; only its type, name, and size will be sent",
                    systemImage: "doc.badge.plus",
                    tint: .orange
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isSubmitting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(submissionStatus ?? "Preparing request")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(submissionStatus ?? "Preparing request")
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.08), in: Capsule())
            }

            inputRow
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: -2)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Menu {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Choose Photo", systemImage: "photo")
                }

                Button(action: onCamera) {
                    Label("Take Photo", systemImage: "camera")
                }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                Button(action: onPickFile) {
                    Label("Choose PDF, Audio, or Video", systemImage: "doc")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 44)
                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
            }
            .accessibilityLabel("Add Content")

            // Commands are a high-frequency developer action. Keep the
            // standalone entry visible at large Dynamic Type and in VoiceOver.
            Button(action: onShowCommands) {
                Image(systemName: "slash.circle")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 44)
                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Commands")
            .accessibilityHint("Opens developer commands")

            TextField(
                isRunning ? "Type to add to queue" : "Enter a task",
                text: $draft,
                axis: .vertical
            )
            .accessibilityIdentifier("chat-input")
            .accessibilityLabel(isRunning ? "Queued Message" : "Task Input")
            .lineLimit(1...6)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.quaternary, lineWidth: 0.5)
            }
            .submitLabel(.send)
            .onSubmit {
                guard canSend, !isSubmitting else { return }
                onSend(.queued)
            }

            if isRunning {
                Button {
                    onSend(.steer)
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                        .frame(width: 44, height: 44)
                        .background(Color.orange.opacity(0.12), in: Circle())
                }
                .disabled(!hasDraft || isSubmitting)
                .accessibilityLabel("Send as Steer")
                .accessibilityHint("Redirects the current task at the next safe step")
                .accessibilityIdentifier("chat-steer-button")
            }

            Button {
                onSend(.queued)
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.headline)
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    canSend && !isSubmitting
                        ? Color.accentColor
                        : Color.secondary.opacity(0.28),
                    in: Circle()
                )
            }
            .disabled(!canSend || isSubmitting)
            .accessibilityLabel(isRunning ? "Add to Queue" : "Send")
            .accessibilityIdentifier("chat-send-button")

            if isRunning {
                Button(action: onCancel) {
                    Image(systemName: "stop.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.red, in: Circle())
                }
                .accessibilityLabel("Stop Current Run")
                .accessibilityIdentifier("chat-stop-button")
            }
        }
    }
}

private struct InputTriggerPalette: View {
    let groups: [InputTriggerSuggestionGroup]
    let onSelect: (InputTriggerSuggestion) -> Void

    var body: some View {
        ScrollView(.vertical) {
            // Candidates are capped at ~20 rows; LazyVStack mis-estimates
            // height here and lets content spill past the 280pt frame.
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    Text(title(for: group.source))
                        .font(.caption2.weight(.semibold))
                        // UIKit semantic colors render reliably here; SwiftUI
                        // .secondary vibrancy text drops out on this
                        // secondarySystemBackground container in the simulator.
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    ForEach(group.suggestions.prefix(10)) { suggestion in
                        Button {
                            onSelect(suggestion)
                        } label: {
                            HStack(spacing: 10) {
                                HarnessIconTile(
                                    systemImage: suggestion.systemImage ?? "terminal",
                                    tint: .accentColor,
                                    size: 28
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayName(for: suggestion))
                                        .font(.body.weight(.medium))
                                    if let description = suggestion.description {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxHeight: 280)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 14))
        .accessibilityLabel("Input Suggestions")
    }

    private func title(for source: String) -> String {
        switch source {
        case "command": "Command"
        case "skill": "Skills"
        case "file": "File"
        case "history": "Past Session"
        case "subagent": "Subagent"
        case "model": "Model"
        case "agent": "Agent"
        case "plugin": "Plugin"
        case "session": "Session"
        default: source
        }
    }

    private func displayName(for suggestion: InputTriggerSuggestion) -> String {
        if case .completion = suggestion.kind { return suggestion.name }
        return "\(suggestion.trigger.rawValue)\(suggestion.name)"
    }
}

struct SlashCommandInteractionSheet: View {
    let pending: PendingSlashCommandInteraction
    let onResolve: (SlashCommandInteractionResponse) -> Void

    @State private var search = ""
    @State private var gatedOption: SlashCommandSelectOption?
    @State private var acknowledged = false

    var body: some View {
        NavigationStack {
            Group {
                switch pending.request {
                case let .popupSelect(title, options):
                    popup(title: title, options: options)
                case let .confirmation(confirmation):
                    confirmationView(confirmation)
                }
            }
            .navigationTitle("/\(pending.commandName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onResolve(.cancelled) }
                }
            }
        }
    }

    private func popup(
        title: String,
        options: [SlashCommandSelectOption]
    ) -> some View {
        List {
            Section {
                TextField("Search", text: $search)
            } header: {
                Text(title)
            }
            if let gatedOption, let confirmation = gatedOption.confirmation {
                Section(confirmation.title) {
                    Text(confirmation.description)
                    Toggle(confirmation.acknowledgeLabel, isOn: $acknowledged)
                    Button(confirmation.confirmLabel) {
                        onResolve(.selected(optionID: gatedOption.id))
                    }
                    .disabled(!acknowledged)
                    Button(confirmation.cancelLabel, role: .cancel) {
                        self.gatedOption = nil
                        acknowledged = false
                    }
                }
            } else {
                Section {
                    ForEach(filtered(options)) { option in
                        Button {
                            if option.confirmation == nil {
                                onResolve(.selected(optionID: option.id))
                            } else {
                                gatedOption = option
                                acknowledged = false
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.label)
                                    if let detail = option.detail {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if option.active {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func confirmationView(
        _ confirmation: SlashCommandConfirmation
    ) -> some View {
        Form {
            Section(confirmation.title) {
                Text(confirmation.description)
                Toggle(confirmation.acknowledgeLabel, isOn: $acknowledged)
            }
            Section {
                Button(confirmation.confirmLabel) { onResolve(.confirmed) }
                    .disabled(!acknowledged)
                Button(confirmation.cancelLabel, role: .destructive) {
                    onResolve(.denied)
                }
            }
        }
    }

    private func filtered(
        _ options: [SlashCommandSelectOption]
    ) -> [SlashCommandSelectOption] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return options }
        return options.filter {
            $0.label.lowercased().contains(needle)
                || ($0.detail?.lowercased().contains(needle) ?? false)
        }
    }
}

private struct QueuedInputList: View {
    let inputs: [QueuedAgentInput]
    let onEdit: (QueuedAgentInput) -> Void
    let onRemove: (UUID) -> Void
    let onSteer: (UUID) -> Void
    let onSteerAll: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label("Queued \(inputs.count)", systemImage: "text.line.last.and.arrowtriangle.forward")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(action: onSteerAll) {
                    Image(systemName: "arrow.triangle.branch")
                }
                .disabled(inputs.allSatisfy { $0.disposition == .steer })
                .accessibilityLabel("Convert All Queued Messages to Steer")
            }
            .foregroundStyle(.secondary)

            ForEach(inputs) { input in
                HStack(spacing: 8) {
                    Image(systemName: input.disposition == .steer ? "arrow.triangle.branch" : "clock")
                        .foregroundStyle(input.disposition == .steer ? .orange : .secondary)
                    Text(input.text)
                        .font(.callout)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Menu {
                        Button {
                            onEdit(input)
                        } label: {
                            Label("Edit Queued Message", systemImage: "pencil")
                        }

                        Button {
                            onSteer(input.id)
                        } label: {
                            Label("Convert Queued Message to Steer", systemImage: "arrow.triangle.branch")
                        }
                        .disabled(input.disposition == .steer)

                        Button(role: .destructive) {
                            onRemove(input.id)
                        } label: {
                            Label("Remove Queued Message", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Queued Message Actions")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: .rect(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(.quaternary, lineWidth: 0.5)
                }
            }
        }
        .padding(8)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.72), in: .rect(cornerRadius: 14))
    }
}

struct EditQueuedInputView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String

    let disposition: QueuedInputDisposition
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(disposition == .steer ? "Steer" : "Queued Message") {
                    TextField("Content", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                }
            }
            .navigationTitle("Edit Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct DirectCommandOutputView: View {
    @Environment(\.dismiss) private var dismiss
    let output: DirectCommandOutput

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(output.text)
                    .font(.body.monospaced())
                    .foregroundStyle(output.isError ? .red : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(output.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
