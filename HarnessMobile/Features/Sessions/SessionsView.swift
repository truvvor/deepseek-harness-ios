import SwiftUI

struct SessionsView: View {
    @Environment(AppModel.self) private var model

    private let onConversationOpened: () -> Void
    private let onOpenSettings: () -> Void
    private let onOpenTools: () -> Void

    @State private var sessionToRename: ConversationSessionSummary?
    @State private var sessionToDelete: ConversationSessionSummary?
    @State private var isDeleteConfirmationPresented = false
    @State private var operation: SessionOperation?
    @State private var searchText = ""
    @State private var searchResults: [ConversationSessionSearchResult] = []
    @State private var isSearching = false
    @State private var collectionScope = SessionCollectionScope.active
    @State private var sortOrder = SessionSortOrder.updatedNewest

    init(
        onConversationOpened: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onOpenTools: @escaping () -> Void = {}
    ) {
        self.onConversationOpened = onConversationOpened
        self.onOpenSettings = onOpenSettings
        self.onOpenTools = onOpenTools
    }

    var body: some View {
        List {
                if let errorMessage = model.errorMessage {
                    SessionErrorSection(message: errorMessage)
                }

                if visibleSessions.isEmpty {
                    emptyState
                        .listRowSeparator(.hidden)
                } else {
                    if collectionScope == .all {
                        if !activeSessions.isEmpty {
                            sessionSection("Projects", sessions: activeSessions)
                        }
                        if !archivedSessions.isEmpty {
                            sessionSection("Archived", sessions: archivedSessions)
                        }
                    } else {
                        sessionSection(collectionScope == .active ? "Projects" : collectionScope.sectionTitle, sessions: visibleSessions)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(HarnessTheme.pageBackground)
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            floatingControls
        }
        .navigationTitle("Harness")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search titles and messages"
        )
        .searchScopes($collectionScope) {
            ForEach(SessionCollectionScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Scope", selection: $collectionScope) {
                        ForEach(SessionCollectionScope.allCases) { scope in
                            Label(scope.title, systemImage: scope.systemImage)
                                .tag(scope)
                        }
                    }

                    Picker("Sort", selection: $sortOrder) {
                        ForEach(SessionSortOrder.allCases) { order in
                            Label(order.title, systemImage: order.systemImage)
                                .tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Filter and Sort")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenTools) {
                    Image(systemName: "square.grid.2x2")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Tools")
            }
        }
        .task(id: searchTaskID) {
            await refreshSearch()
        }
        .sheet(item: $sessionToRename) { session in
            RenameConversationSheet(session: session)
        }
        .confirmationDialog(
            "Delete Project?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible,
            presenting: sessionToDelete
        ) { session in
            Button("Delete '\(session.title)'", role: .destructive) {
                deleteConversation(session)
            }
            Button("Cancel", role: .cancel) {
                sessionToDelete = nil
            }
        } message: { session in
            if session.id == model.activeSessionID, model.isRunning {
                Text("The current run will stop first, then this project will be deleted. Workspace files will not be deleted.")
            } else {
                Text("This deletes the project's messages, task state, and recovery checkpoints stored on this device. Workspace files are not affected.")
            }
        }
    }

    private var floatingControls: some View {
        HStack(spacing: 10) {
            Button(action: createConversation) {
                Image(systemName: "folder.badge.plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            }
            .accessibilityLabel("New Project")
            .disabled(operation != nil)
        }
        .padding(.trailing, 16)
        .padding(.bottom, 12)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var activeSession: ConversationSessionSummary? {
        guard let activeSessionID = model.activeSessionID else { return nil }
        return model.sessions.first { $0.id == activeSessionID }
    }

    private var searchTaskID: SessionSearchTaskID {
        SessionSearchTaskID(
            query: normalizedSearchText,
            revisions: model.sessions.map {
                SessionSearchRevision(
                    id: $0.id,
                    revision: $0.revision,
                    archivedAt: $0.archivedAt
                )
            }
        )
    }

    private var sourceSessions: [ConversationSessionSummary] {
        normalizedSearchText.isEmpty
            ? model.sessions
            : searchResults.map(\.session)
    }

    private var visibleSessions: [ConversationSessionSummary] {
        sort(
            sourceSessions.filter { session in
                switch collectionScope {
                case .active:
                    !session.isArchived
                case .archived:
                    session.isArchived
                case .all:
                    true
                }
            }
        )
    }

    private var activeSessions: [ConversationSessionSummary] {
        visibleSessions.filter { !$0.isArchived }
    }

    private var archivedSessions: [ConversationSessionSummary] {
        visibleSessions.filter(\.isArchived)
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            HStack {
                Spacer()
                ProgressView("Searching…")
                Spacer()
            }
        } else if !normalizedSearchText.isEmpty {
            ContentUnavailableView.search(text: normalizedSearchText)
        } else if collectionScope == .archived {
            ContentUnavailableView(
                "No Archived Projects",
                systemImage: "archivebox",
                description: Text("Archived projects keep their messages and task state and can be restored at any time.")
            )
        } else {
            ContentUnavailableView {
                Label("No Projects Yet", systemImage: "folder")
            } description: {
                Text("After you create a project, its messages, task state, and recovery checkpoints are saved on this device.")
            } actions: {
                Button("New Project", action: createConversation)
                    .disabled(operation != nil)
            }
        }
    }

    private func sessionSection(
        _ title: String,
        sessions: [ConversationSessionSummary]
    ) -> some View {
        Section {
            ForEach(sessions) { session in
                sessionRow(session)
                    .harnessCardListRow()
            }
        } header: {
            Label(title, systemImage: title == "Archived" ? "archivebox" : "folder.fill")
        }
    }

    private func sessionRow(_ session: ConversationSessionSummary) -> some View {
        Button {
            openConversation(session)
        } label: {
            SessionRow(
                session: session,
                matchSnippet: searchResult(for: session.id)?.titleMatched == false
                    ? searchResult(for: session.id)?.matchSnippet
                    : nil,
                status: status(for: session),
                isBusy: operation?.sessionID == session.id
            )
        }
        .buttonStyle(.plain)
        .disabled(operation != nil)
        .accessibilityHint(accessibilityHint(for: session))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if session.isArchived {
                Button {
                    restoreConversation(session)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .tint(.green)
            } else {
                Button {
                    archiveConversation(session)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.orange)
            }

            Button {
                forkConversation(session)
            } label: {
                Label("Fork", systemImage: "arrow.triangle.branch")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", role: .destructive) {
                requestDeletion(of: session)
            }

            Button {
                sessionToRename = session
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                regenerateConversationTitle(session)
            } label: {
                Label("Regenerate Title", systemImage: "text.badge.star")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                forkConversation(session)
            } label: {
                Label("Fork Project", systemImage: "arrow.triangle.branch")
            }

            if session.isArchived {
                Button {
                    restoreConversation(session)
                } label: {
                    Label("Restore Project", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button {
                    archiveConversation(session)
                } label: {
                    Label("Archive Project", systemImage: "archivebox")
                }
            }

            Button {
                sessionToRename = session
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                regenerateConversationTitle(session)
            } label: {
                Label("Regenerate Title", systemImage: "text.badge.star")
            }

            Button(role: .destructive) {
                requestDeletion(of: session)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func regenerateConversationTitle(_ session: ConversationSessionSummary) {
        operation = .titling(session.id)
        Task { @MainActor in
            await model.regenerateConversationTitle(id: session.id)
            operation = nil
        }
    }

    private func createConversation() {
        guard operation == nil else { return }
        model.errorMessage = nil
        operation = .creating
        Task { @MainActor in
            await model.createConversation()
            if model.activeSessionID != nil, model.errorMessage == nil {
                onConversationOpened()
            }
            if operation == .creating {
                operation = nil
            }
        }
    }

    private func openConversation(_ session: ConversationSessionSummary) {
        if session.isArchived {
            restoreConversation(session, openAfterRestore: true)
        } else {
            switchConversation(to: session)
        }
    }

    private func switchConversation(to session: ConversationSessionSummary) {
        guard operation == nil else { return }
        if session.id == model.activeSessionID {
            onConversationOpened()
            return
        }
        model.errorMessage = nil
        operation = .switching(session.id)
        Task { @MainActor in
            await model.switchConversation(to: session.id)
            if model.activeSessionID == session.id, model.errorMessage == nil {
                onConversationOpened()
            }
            if operation == .switching(session.id) {
                operation = nil
            }
        }
    }

    private func forkConversation(_ session: ConversationSessionSummary) {
        guard operation == nil else { return }
        model.errorMessage = nil
        operation = .forking(session.id)
        Task { @MainActor in
            await model.forkConversation(id: session.id)
            if model.activeSessionID != session.id, model.errorMessage == nil {
                onConversationOpened()
            }
            if operation == .forking(session.id) {
                operation = nil
            }
        }
    }

    private func archiveConversation(_ session: ConversationSessionSummary) {
        guard operation == nil else { return }
        model.errorMessage = nil
        operation = .archiving(session.id)
        Task { @MainActor in
            await model.archiveConversation(id: session.id)
            if operation == .archiving(session.id) {
                operation = nil
            }
        }
    }

    private func restoreConversation(
        _ session: ConversationSessionSummary,
        openAfterRestore: Bool = false
    ) {
        guard operation == nil else { return }
        model.errorMessage = nil
        operation = .restoring(session.id)
        Task { @MainActor in
            await model.restoreConversation(id: session.id)
            if openAfterRestore,
               model.sessions.first(where: { $0.id == session.id })?.isArchived == false {
                await model.switchConversation(to: session.id)
                if model.activeSessionID == session.id, model.errorMessage == nil {
                    onConversationOpened()
                }
            }
            if operation == .restoring(session.id) {
                operation = nil
            }
        }
    }

    private func requestDeletion(of session: ConversationSessionSummary) {
        guard operation == nil else { return }
        sessionToDelete = session
        isDeleteConfirmationPresented = true
    }

    private func deleteConversation(_ session: ConversationSessionSummary) {
        guard operation == nil else { return }
        sessionToDelete = nil
        model.errorMessage = nil
        operation = .deleting(session.id)
        Task { @MainActor in
            await model.deleteConversation(id: session.id)
            if operation == .deleting(session.id) {
                operation = nil
            }
        }
    }

    private func refreshSearch() async {
        let query = normalizedSearchText
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        isSearching = true
        let results = await model.searchConversations(query: query)
        guard !Task.isCancelled else { return }
        searchResults = results
        isSearching = false
    }

    private func searchResult(for id: UUID) -> ConversationSessionSearchResult? {
        searchResults.first { $0.id == id }
    }

    private func sort(
        _ sessions: [ConversationSessionSummary]
    ) -> [ConversationSessionSummary] {
        switch sortOrder {
        case .updatedNewest:
            sessions.sorted { $0.updatedAt > $1.updatedAt }
        case .createdNewest:
            sessions.sorted { $0.createdAt > $1.createdAt }
        case .title:
            sessions.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    private func status(for session: ConversationSessionSummary) -> SessionDisplayStatus {
        if session.isArchived {
            return .archived
        }
        if let run = model.sessionRunSnapshots[session.id] {
            switch run.phase {
            case .idle, .maintenance, .running, .cancelling:
                return .running
            case .terminal:
                if !run.presentation.queuedInputs.isEmpty {
                    return .waiting(run.presentation.queuedInputs.count)
                }
            }
        }
        if session.queuedInputCount > 0 {
            return .waiting(session.queuedInputCount)
        }
        if session.isResumable {
            return .resumable
        }
        if session.id == model.activeSessionID {
            return .current
        }
        return session.messageCount == 0 ? .ready : .completed
    }

    private func accessibilityHint(for session: ConversationSessionSummary) -> String {
        if session.isDesktopMirror {
            return "Read-only mirror of a DeepSeek Harness desktop session"
        }
        if session.isArchived {
            return "Restore and open this project"
        }
        return session.id == model.activeSessionID ? "Current project" : "Switch to this project"
    }
}

private struct WorkspaceHierarchySection: View {
    @Binding var isExpanded: Bool
    let files: [WorkspaceStore.FileEntry]
    let mounts: [WorkspaceStore.MountSnapshot]
    let activeSessionTitle: String?
    let isRunning: Bool
    let onOpenWorkspace: () -> Void

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                if let activeSessionTitle {
                    hierarchyRow(
                        title: activeSessionTitle,
                        detail: isRunning ? "Current session · Agent running" : "Current session · Waiting for input",
                        systemImage: isRunning ? "waveform" : "bubble.left",
                        tint: isRunning ? .green : .blue,
                        depth: 1
                    )
                }

                Button(action: onOpenWorkspace) {
                    hierarchyRow(
                        title: "Files",
                        detail: "\(files.count) local files",
                        systemImage: "folder",
                        tint: .orange,
                        depth: 1,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("workspace-hierarchy-files")

                ForEach(mounts.prefix(4)) { mount in
                    hierarchyRow(
                        title: mount.name,
                        detail: "\(mount.effectiveWritable ? "Read-write" : "Read-only") · \(mountStatusTitle(mount.status))",
                        systemImage: mountStatusIcon(mount.status),
                        tint: mountStatusColor(mount.status),
                        depth: 2
                    )
                }

                if mounts.count > 4 {
                    Text("\(mounts.count - 4) more mounted folders")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 52)
                }

                Button(action: onOpenWorkspace) {
                    Label("Open Full Workspace", systemImage: "arrow.up.forward.app")
                        .font(.subheadline.weight(.medium))
                        .padding(.leading, 28)
                }
                .accessibilityIdentifier("workspace-hierarchy-open")
            } label: {
                HStack(spacing: 12) {
                    HarnessIconTile(systemImage: "folder.fill", tint: .orange, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("/workspace")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("\(files.count) files · \(mounts.count) mounts · \(isRunning ? "Running" : "Ready on device")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("workspace-hierarchy-root")
            }
        } header: {
            Label("Workspace", systemImage: "folder")
        }
    }

    private func hierarchyRow(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color,
        depth: Int,
        showsChevron: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            HarnessIconTile(systemImage: systemImage, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, CGFloat(depth) * 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func mountStatusTitle(_ status: WorkspaceStore.MountStatus) -> String {
        switch status {
        case .active: "Connected"
        case .staleBookmark: "Needs reauthorization"
        case .permissionDenied: "Permission denied"
        case .unavailable: "Unavailable"
        }
    }

    private func mountStatusIcon(_ status: WorkspaceStore.MountStatus) -> String {
        switch status {
        case .active: "externaldrive.badge.checkmark"
        case .staleBookmark: "externaldrive.badge.exclamationmark"
        case .permissionDenied, .unavailable: "externaldrive.badge.xmark"
        }
    }

    private func mountStatusColor(_ status: WorkspaceStore.MountStatus) -> Color {
        switch status {
        case .active: .green
        case .staleBookmark: .orange
        case .permissionDenied, .unavailable: .red
        }
    }
}

private enum SessionOperation: Equatable {
    case creating
    case switching(UUID)
    case deleting(UUID)
    case forking(UUID)
    case archiving(UUID)
    case restoring(UUID)
    case titling(UUID)

    var sessionID: UUID? {
        switch self {
        case .creating:
            nil
        case let .switching(id), let .deleting(id), let .forking(id),
             let .archiving(id), let .restoring(id), let .titling(id):
            id
        }
    }
}

private struct SessionSearchTaskID: Equatable {
    let query: String
    let revisions: [SessionSearchRevision]
}

private struct SessionSearchRevision: Equatable {
    let id: UUID
    let revision: Int
    let archivedAt: Date?
}

private enum SessionCollectionScope: String, CaseIterable, Identifiable {
    case active
    case archived
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: "Current"
        case .archived: "Archive"
        case .all: "All"
        }
    }

    var sectionTitle: String {
        switch self {
        case .active: "Projects"
        case .archived: "Archived"
        case .all: "All Projects"
        }
    }

    var systemImage: String {
        switch self {
        case .active: "rectangle.stack"
        case .archived: "archivebox"
        case .all: "square.grid.2x2"
        }
    }
}

private enum SessionSortOrder: String, CaseIterable, Identifiable {
    case updatedNewest
    case createdNewest
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .updatedNewest: "Recently Updated"
        case .createdNewest: "Recently Created"
        case .title: "Title"
        }
    }

    var systemImage: String {
        switch self {
        case .updatedNewest: "clock.arrow.circlepath"
        case .createdNewest: "calendar.badge.plus"
        case .title: "textformat"
        }
    }
}

private enum SessionDisplayStatus: Equatable {
    case running
    case waiting(Int)
    case resumable
    case completed
    case ready
    case current
    case archived

    var title: String {
        switch self {
        case .running: "Running"
        case let .waiting(count): "Queued \(count)"
        case .resumable: "Resumable"
        case .completed: "Completed"
        case .ready: "Ready"
        case .current: "Current"
        case .archived: "Archived"
        }
    }

    var systemImage: String {
        switch self {
        case .running: "waveform"
        case .waiting: "clock"
        case .resumable: "pause.fill"
        case .completed: "checkmark"
        case .ready: "circle"
        case .current: "checkmark.circle.fill"
        case .archived: "archivebox.fill"
        }
    }

    var leadingIcon: String {
        switch self {
        case .running:
            "waveform"
        case .waiting:
            "text.line.last.and.arrowtriangle.forward"
        case .resumable:
            "play.fill"
        case .completed:
            "checkmark"
        case .ready:
            "sparkles"
        case .current:
            "bubble.left.fill"
        case .archived:
            "archivebox.fill"
        }
    }

    var color: Color {
        switch self {
        case .running, .current: .blue
        case .waiting, .resumable: .orange
        case .completed: .green
        case .ready, .archived: .secondary
        }
    }
}

private struct SessionRow: View {
    let session: ConversationSessionSummary
    let matchSnippet: String?
    let status: SessionDisplayStatus
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 13) {
            HarnessIconTile(systemImage: status.leadingIcon, tint: status.color, size: 38)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    Text(
                        session.updatedAt.formatted(
                            .relative(presentation: .named, unitsStyle: .abbreviated)
                                .locale(Locale(identifier: "en_US"))
                        )
                    )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let matchSnippet, !matchSnippet.isEmpty {
                    Text(matchSnippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: HarnessTheme.Spacing.small) {
                    HarnessStatusPill(
                        title: status.title,
                        systemImage: status.systemImage,
                        tint: status.color
                    )
                    Text("\(session.messageCount) messages")
                    if session.isDesktopMirror {
                        Text("·").accessibilityHidden(true)
                        Label("Desktop Mirror", systemImage: "desktopcomputer")
                            .labelStyle(.titleAndIcon)
                    }
                    if session.forkedFromSessionID != nil {
                        Text("·").accessibilityHidden(true)
                        Label("Fork", systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Processing project")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, HarnessTheme.Spacing.medium)
        .background(
            status == .current ? Color.accentColor.opacity(0.10) : HarnessTheme.surface,
            in: RoundedRectangle(cornerRadius: HarnessTheme.Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: HarnessTheme.Radius.card, style: .continuous)
                .stroke(
                    status == .current ? Color.accentColor.opacity(0.24) : HarnessTheme.separator,
                    lineWidth: 0.5
                )
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(status == .current ? .isSelected : [])
    }
}

private struct SessionErrorSection: View {
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
            Label("Operation Failed", systemImage: "exclamationmark.triangle")
        }
    }
}

private struct RenameConversationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let session: ConversationSessionSummary

    @State private var title: String
    @State private var isSaving = false
    @FocusState private var isTitleFocused: Bool

    init(session: ConversationSessionSummary) {
        self.session = session
        _title = State(initialValue: session.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project Name", text: $title)
                        .focused($isTitleFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    HStack {
                        Text("The name is saved on this device, up to 80 characters.")
                        Spacer()
                        Text("\(title.count)/80")
                            .monospacedDigit()
                            .foregroundStyle(title.count > 80 ? .red : .secondary)
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Label("Unable to Rename Project", systemImage: "pencil.slash")
                    }
                }
            }
            .navigationTitle("Rename Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
            .task {
                isTitleFocused = true
            }
        }
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !isSaving
            && !normalizedTitle.isEmpty
            && normalizedTitle.count <= 80
            && normalizedTitle != session.title
    }

    private func save() {
        guard canSave else { return }
        let savedTitle = normalizedTitle
        model.errorMessage = nil
        isSaving = true
        Task { @MainActor in
            await model.renameConversation(id: session.id, title: savedTitle)
            isSaving = false
            if model.sessions.first(where: { $0.id == session.id })?.title == savedTitle {
                dismiss()
            }
        }
    }
}
