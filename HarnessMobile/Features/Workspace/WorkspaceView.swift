import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var isFileImporterPresented = false
    @State private var isFolderImporterPresented = false
    @State private var reauthorizingMountID: UUID?
    @State private var mountPendingRemoval: WorkspaceStore.MountSnapshot?
    @State private var isRemovalConfirmationPresented = false
    @State private var isFileExporterPresented = false
    @State private var exportDocument: ConversationExportFileDocument?
    @State private var exportContentType: UTType = .data
    @State private var exportFilename = "workspace-file"

    var body: some View {
        List {
            WorkspaceMountsSection(
                mounts: model.workspaceMounts,
                onToggleWritable: toggleWritable,
                onReauthorize: reauthorize,
                onRemove: requestRemoval
            )

            Section {
                if model.workspaceFiles.isEmpty {
                    VStack(spacing: HarnessTheme.Spacing.medium) {
                        ContentUnavailableView(
                            "No Files Yet",
                            systemImage: "folder.badge.plus",
                            description: Text("Import a file or mount an external folder to start using the workspace.")
                        )

                        HStack(spacing: HarnessTheme.Spacing.small) {
                            Button("Import File", systemImage: "doc.badge.plus") {
                                isFileImporterPresented = true
                            }
                            .buttonStyle(.bordered)

                            Button("Mount Folder", systemImage: "externaldrive.badge.plus") {
                                reauthorizingMountID = nil
                                isFolderImporterPresented = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HarnessTheme.Spacing.large)
                } else {
                    ForEach(model.workspaceFiles, id: \.path) { file in
                        WorkspaceFileRow(
                            file: file,
                            onExport: { export(file) }
                        )
                    }
                }
            } header: { Label("Files", systemImage: "doc.text") }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(HarnessTheme.pageBackground)
        .navigationTitle("Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Import File", systemImage: "doc.badge.plus") {
                        isFileImporterPresented = true
                    }
                    Button("Mount Folder", systemImage: "externaldrive.badge.plus") {
                        reauthorizingMountID = nil
                        isFolderImporterPresented = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add to Workspace")
            }
        }
        .refreshable {
            await model.refreshWorkspace(forceMountRefresh: true)
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [
                .plainText,
                .json,
                .commaSeparatedText,
                .xml,
                .yaml
            ]
        ) { result in
            switch result {
            case let .success(url):
                Task {
                    await model.importDocument(url)
                }
            case let .failure(error):
                model.presentError(error)
            }
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
        .fileImporter(
            isPresented: $isFolderImporterPresented,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case let .success(url):
                let mountID = reauthorizingMountID
                reauthorizingMountID = nil
                Task {
                    if let mountID {
                        await model.reauthorizeWorkspaceMount(id: mountID, url: url)
                    } else {
                        await model.mountWorkspaceFolder(url)
                    }
                }
            case let .failure(error):
                reauthorizingMountID = nil
                model.presentError(error)
            }
        }
        .confirmationDialog(
            "Unmount This Folder?",
            isPresented: $isRemovalConfirmationPresented,
            titleVisibility: .visible,
            presenting: mountPendingRemoval
        ) { mount in
            Button("Unmount \(mount.name)", role: .destructive) {
                mountPendingRemoval = nil
                Task {
                    await model.removeWorkspaceMount(id: mount.id)
                }
            }
            Button("Cancel", role: .cancel) {
                mountPendingRemoval = nil
            }
        } message: { mount in
            Text("The source folder won't be deleted; it will only be removed from /workspace/mounts/\(mount.name).")
        }
    }

    private func toggleWritable(_ mount: WorkspaceStore.MountSnapshot) {
        Task {
            await model.setWorkspaceMountWritable(
                id: mount.id,
                writable: !mount.access.allowsWriting
            )
        }
    }

    private func reauthorize(_ mount: WorkspaceStore.MountSnapshot) {
        reauthorizingMountID = mount.id
        isFolderImporterPresented = true
    }

    private func requestRemoval(_ mount: WorkspaceStore.MountSnapshot) {
        mountPendingRemoval = mount
        isRemovalConfirmationPresented = true
    }

    private func export(_ file: WorkspaceStore.FileEntry) {
        Task {
            do {
                let data = try await model.workspaceFileData(path: file.path)
                exportDocument = ConversationExportFileDocument(data: data)
                exportContentType = UTType(filenameExtension: URL(fileURLWithPath: file.path).pathExtension) ?? .data
                exportFilename = URL(fileURLWithPath: file.path).lastPathComponent
                isFileExporterPresented = true
            } catch {
                model.presentError(error)
            }
        }
    }
}

private struct WorkspaceMountsSection: View {
    let mounts: [WorkspaceStore.MountSnapshot]
    let onToggleWritable: (WorkspaceStore.MountSnapshot) -> Void
    let onReauthorize: (WorkspaceStore.MountSnapshot) -> Void
    let onRemove: (WorkspaceStore.MountSnapshot) -> Void

    var body: some View {
        Section {
            if mounts.isEmpty {
                Label("No External Folders Mounted", systemImage: "externaldrive")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mounts) { mount in
                    WorkspaceMountRow(
                        mount: mount,
                        onToggleWritable: { onToggleWritable(mount) },
                        onReauthorize: { onReauthorize(mount) },
                        onRemove: { onRemove(mount) }
                    )
                }
            }
        } header: { Label("Mounted Folders", systemImage: "externaldrive") }
    }
}

private struct WorkspaceMountRow: View {
    let mount: WorkspaceStore.MountSnapshot
    let onToggleWritable: () -> Void
    let onReauthorize: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HarnessIconTile(systemImage: statusIcon, tint: statusColor)

            VStack(alignment: .leading, spacing: 3) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text(mount.name).lineLimit(1)
                        accessPill
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mount.name)
                            .fixedSize(horizontal: false, vertical: true)
                        accessPill
                    }
                }
                Text(mount.guestPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Menu {
                Button(
                    mount.access.allowsWriting ? "Make Read-Only" : "Allow Writing",
                    systemImage: mount.access.allowsWriting ? "lock" : "lock.open"
                ) {
                    onToggleWritable()
                }
                .disabled(!mount.sourceWritable && !mount.access.allowsWriting)

                Button("Reauthorize", systemImage: "arrow.clockwise") {
                    onReauthorize()
                }

                Button("Unmount", systemImage: "eject", role: .destructive) {
                    onRemove()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Manage Mount \(mount.name)")
        }
    }

    private var statusIcon: String {
        switch mount.status {
        case .active:
            mount.effectiveWritable
                ? "externaldrive.fill.badge.checkmark"
                : "externaldrive.badge.checkmark"
        case .staleBookmark:
            "externaldrive.badge.exclamationmark"
        case .permissionDenied, .unavailable:
            "externaldrive.badge.xmark"
        }
    }

    private var statusColor: Color {
        switch mount.status {
        case .active: .green
        case .staleBookmark: .orange
        case .permissionDenied, .unavailable: .red
        }
    }

    private var statusText: String {
        switch mount.status {
        case .active:
            mount.sourceDisplayName
        case .staleBookmark:
            mount.failureMessage ?? "Authorization expired"
        case .permissionDenied:
            mount.failureMessage ?? "Reauthorization required"
        case .unavailable:
            mount.failureMessage ?? "Folder currently unavailable"
        }
    }

    private var accessPill: some View {
        HarnessStatusPill(
            title: mount.effectiveWritable ? "Read-Write" : "Read-Only",
            systemImage: mount.effectiveWritable ? "lock.open" : "lock",
            tint: mount.effectiveWritable ? .green : .secondary
        )
    }
}

private struct WorkspaceFileRow: View {
    let file: WorkspaceStore.FileEntry
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HarnessIconTile(
                systemImage: file.path.hasPrefix("mounts/") ? "doc.on.doc" : "doc.text",
                tint: .secondary
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .lineLimit(2)
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: file.size,
                        countStyle: .file
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Export File", systemImage: "square.and.arrow.up", action: onExport)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Export \(file.path)")
        }
    }
}
