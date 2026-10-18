import SwiftUI

struct WorkStateView: View {
    @Environment(AppModel.self) private var model
    @State private var goalEditor: GoalEditorRequest?
    @State private var isClearGoalConfirmationPresented = false

    var body: some View {
        List {
            if let errorMessage = model.errorMessage {
                WorkStateErrorSection(message: errorMessage)
            }

            if model.hasResumableRun {
                ResumeRunSection()
            }

            if model.isRunning {
                CurrentRunSection(
                    step: model.currentStep,
                    activeToolStatus: model.activeToolStatus
                )
            }

            if let goal = model.workState.goal {
                Section {
                    WorkStateGoalRow(
                        goal: goal,
                        onEdit: {
                            goalEditor = GoalEditorRequest(
                                mode: .edit,
                                initialTitle: goal.title
                            )
                        },
                        onCreateReplacement: {
                            goalEditor = GoalEditorRequest(mode: .create)
                        },
                        onTransition: { status in
                            Task {
                                await model.applyGoalAction(.transition(to: status))
                            }
                        },
                        onClear: {
                            isClearGoalConfirmationPresented = true
                        }
                    )
                } header: { Label("Goal", systemImage: "scope") }
            } else {
                Section {
                    Button {
                        goalEditor = GoalEditorRequest(mode: .create)
                    } label: {
                        Label("Create Session Goal", systemImage: "scope")
                    }
                } header: { Label("Goal", systemImage: "scope") }
            }

            if !model.workState.plan.isEmpty {
                Section {
                    ForEach(model.workState.plan) { step in
                        WorkStateItemRow(title: step.title, status: step.status)
                    }
                } header: { Label("Plan", systemImage: "list.bullet.clipboard") }
            }

            if !model.workState.todos.isEmpty {
                Section {
                    ForEach(model.workState.todos) { item in
                        WorkStateItemRow(title: item.title, status: item.status)
                    }
                } header: { Label("To-Dos", systemImage: "checklist") }
            }

            if model.omittedContextMessages > 0 {
                Section {
                    Label {
                        Text(
                            "\(model.omittedContextMessages) earlier messages were omitted before sending to the model; a local task-state summary was kept."
                        )
                    } icon: {
                        Image(systemName: "internaldrive")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: { Label("Context Management", systemImage: "internaldrive") }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(HarnessTheme.pageBackground)
        .navigationTitle("Task State")
        .sheet(item: $goalEditor) { request in
            GoalEditorSheet(request: request)
        }
        .confirmationDialog(
            "Clear Current Goal?",
            isPresented: $isClearGoalConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Clear Goal", role: .destructive) {
                Task {
                    await model.applyGoalAction(.clear)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The goal will be removed from the current session. Chat history, plan, and to-dos won't be deleted.")
        }
    }

}

private struct WorkStateGoalRow: View {
    let goal: ConversationGoal
    let onEdit: () -> Void
    let onCreateReplacement: () -> Void
    let onTransition: (ConversationItemStatus) -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HarnessIconTile(systemImage: goal.status.systemImage, tint: goal.status.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(goal.title)
                    .fixedSize(horizontal: false, vertical: true)
                HarnessStatusPill(
                    title: goal.status.title,
                    systemImage: goal.status.systemImage,
                    tint: goal.status.tint
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button(action: onEdit) {
                    Label("Edit Goal", systemImage: "pencil")
                }

                ForEach(goal.status.allowedGoalTransitions, id: \.rawValue) { status in
                    Button {
                        onTransition(status)
                    } label: {
                        Label(status.actionTitle, systemImage: status.systemImage)
                    }
                }

                if goal.status == .completed {
                    Button(action: onCreateReplacement) {
                        Label("Create New Goal", systemImage: "plus")
                    }
                }

                Divider()

                Button(role: .destructive, action: onClear) {
                    Label("Clear Goal", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Goal Actions")
            .accessibilityIdentifier("work-state-goal-menu")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct GoalEditorRequest: Identifiable {
    enum Mode {
        case create
        case edit
    }

    let id = UUID()
    let mode: Mode
    let initialTitle: String

    init(mode: Mode, initialTitle: String = "") {
        self.mode = mode
        self.initialTitle = initialTitle
    }
}

@MainActor
private struct GoalEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var isSaving = false

    let request: GoalEditorRequest

    init(request: GoalEditorRequest) {
        self.request = request
        _title = State(initialValue: request.initialTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Desired outcome", text: $title, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("goal-editor-field")
                } header: {
                    Label("Goal", systemImage: "scope")
                }
            }
            .navigationTitle(request.mode == .create ? "Create Goal" : "Edit Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(
                        isSaving
                            || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .presentationDetents([.medium])
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        let action: ConversationGoalAction = switch request.mode {
        case .create:
            .create(title: title)
        case .edit:
            .edit(title: title)
        }
        Task { @MainActor in
            if await model.applyGoalAction(action) {
                dismiss()
            } else {
                isSaving = false
            }
        }
    }
}

private struct ResumeRunSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Button {
                model.errorMessage = nil
                model.resumePendingRun()
            } label: {
                Label("Continue from Local Checkpoint", systemImage: "arrow.clockwise.circle.fill")
                    .font(.headline)
            }
            .disabled(model.isRunning)
        } header: {
            Text("Resumable Task")
        } footer: {
            Text("Continues the last unfinished turn of the current session. Recovery and the Agent Loop both run on the phone; no server task is started.")
        }
    }
}

private struct CurrentRunSection: View {
    let step: Int
    let activeToolStatus: String?

    var body: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent Step")
                    Text("Step \(step)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HarnessStatusPill(title: "Running", systemImage: "bolt.fill", tint: .green)
            }

            if let activeToolStatus {
                Label(activeToolStatus, systemImage: "wrench.and.screwdriver")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: { Label("Current Run", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") }
    }
}

private struct WorkStateItemRow: View {
    let title: String
    let status: ConversationItemStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HarnessIconTile(systemImage: status.systemImage, tint: status.tint, size: 28)

            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HarnessStatusPill(
                title: status.title,
                systemImage: status.systemImage,
                tint: status.tint
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(status.title)
    }
}

private struct WorkStateErrorSection: View {
    @Environment(AppModel.self) private var model

    let message: String

    var body: some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

            Button("Close") {
                model.errorMessage = nil
            }
        } header: {
            Label("Run Failed", systemImage: "exclamationmark.triangle")
        }
    }
}

extension ConversationItemStatus {
    var title: String {
        switch self {
        case .pending:
            "Pending"
        case .active:
            "In Progress"
        case .paused:
            "Paused"
        case .completed:
            "Completed"
        case .blocked:
            "Blocked"
        }
    }

    var actionTitle: String {
        switch self {
        case .pending:
            "Mark as Pending"
        case .active:
            "Start or Resume"
        case .paused:
            "Pause Goal"
        case .completed:
            "Mark as Completed"
        case .blocked:
            "Mark as Blocked"
        }
    }

    var systemImage: String {
        switch self {
        case .pending:
            "circle"
        case .active:
            "play.circle.fill"
        case .paused:
            "pause.circle.fill"
        case .completed:
            "checkmark.circle.fill"
        case .blocked:
            "exclamationmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending:
            .secondary
        case .active:
            .blue
        case .paused:
            .orange
        case .completed:
            .green
        case .blocked:
            .red
        }
    }
}
