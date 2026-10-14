import SwiftUI
import UniformTypeIdentifiers

/// Read-only browser of the desktop session's workspace (D-014): the bridge
/// lists directories and streams file bytes; nothing is written back and
/// nothing is cached beyond the open screen.
struct DesktopFilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DesktopDirectoryView(path: "", title: "Desktop Files")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

private struct DesktopDirectoryView: View {
    @Environment(AppModel.self) private var model

    let path: String
    let title: String

    @State private var listing: BridgeDirectoryListing?
    @State private var errorText: String?
    @State private var isLoading = false

    var body: some View {
        List {
            if let root = listing?.root, path.isEmpty, !root.isEmpty {
                Section {
                    Text(root)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text("Workspace")
                }
            }
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                }
            }
            if let listing {
                if listing.entries.isEmpty, errorText == nil {
                    Text("Empty folder")
                        .foregroundStyle(.secondary)
                }
                ForEach(sortedEntries(listing.entries)) { entry in
                    if entry.isDirectory {
                        NavigationLink {
                            DesktopDirectoryView(path: childPath(entry.name), title: entry.name)
                        } label: {
                            DesktopFileRow(entry: entry)
                        }
                    } else {
                        NavigationLink {
                            DesktopFileContentView(path: childPath(entry.name), title: entry.name)
                        } label: {
                            DesktopFileRow(entry: entry)
                        }
                    }
                }
            }
        }
        .harnessCompactListChrome()
        .overlay {
            if isLoading, listing == nil {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .accessibilityLabel("Refresh")
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func childPath(_ name: String) -> String {
        path.isEmpty ? name : "\(path)/\(name)"
    }

    private func sortedEntries(_ entries: [BridgeFileEntry]) -> [BridgeFileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            listing = try await model.desktopMirrorFiles(path: path)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct DesktopFileRow: View {
    let entry: BridgeFileEntry

    var body: some View {
        HStack(spacing: 10) {
            HarnessIconTile(
                systemImage: entry.isDirectory ? "folder.fill" : (entry.isSymlink ? "link" : "doc"),
                tint: entry.isDirectory ? .blue : .secondary,
                size: 28
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = detailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var detailText: String? {
        var parts: [String] = []
        if !entry.isDirectory, let size = entry.size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let modified = entry.modifiedAt {
            let date = Date(timeIntervalSince1970: TimeInterval(modified) / 1_000)
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct DesktopFileContentView: View {
    @Environment(AppModel.self) private var model

    let path: String
    let title: String

    @State private var content: BridgeFileContent?
    @State private var errorText: String?
    @State private var isLoading = false

    /// Text beyond this is shown cut so the layout stays responsive.
    private let maximumRenderedCharacters = 200_000

    var body: some View {
        Group {
            if let content {
                ScrollView(content.isImage ? .vertical : [.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 12) {
                        if content.truncated {
                            Label(
                                "Showing the first \(ByteCountFormatter.string(fromByteCount: Int64(content.data.count), countStyle: .file)) of this file.",
                                systemImage: "scissors"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        if content.isImage, let image = UIImage(data: content.data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                        } else if let text = content.text {
                            Text(String(text.prefix(maximumRenderedCharacters)))
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Binary file", systemImage: "doc.zipper")
                                Text(
                                    "\(content.mimeType ?? "unknown type") · "
                                        + ByteCountFormatter.string(
                                            fromByteCount: content.totalBytes ?? Int64(content.data.count),
                                            countStyle: .file
                                        )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(16)
                }
            } else if let errorText {
                ContentUnavailableView {
                    Label("Could not open file", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorText)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        }
        .background(HarnessTheme.pageBackground)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let content {
                    ShareLink(
                        item: DesktopSharedFile(content: content, name: title),
                        preview: SharePreview(title)
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            content = try await model.desktopMirrorFile(path: path)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Hands the downloaded bytes to the share sheet as a file of their name.
private struct DesktopSharedFile: Transferable {
    let content: BridgeFileContent
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { shared in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("desktop-files", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(shared.name.isEmpty ? "file" : shared.name)
            try shared.content.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
