import SwiftUI

struct NativeToolEventRowSummary: Equatable {
    let text: String
    let suffix: String?
    let isError: Bool

    static func make(
        event: AgentToolEvent,
        presentation: NativeToolEventPresentation
    ) -> NativeToolEventRowSummary {
        if event.status == .failed || event.status == .denied || event.status == .interrupted,
           let error = firstLine(event.errorMessage),
           !error.isEmpty {
            return NativeToolEventRowSummary(text: compact(error), suffix: nil, isError: true)
        }

        switch presentation {
        case let .workspaceRead(read):
            return NativeToolEventRowSummary(text: read.path, suffix: nil, isError: false)
        case let .workspaceWrite(write):
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(write.byteCount),
                countStyle: .file
            )
            return NativeToolEventRowSummary(
                text: "\(write.path) · \(size)",
                suffix: nil,
                isError: false
            )
        case let .workspaceFiles(files):
            return NativeToolEventRowSummary(
                text: "\(files.files.count) paths",
                suffix: nil,
                isError: false
            )
        case let .diff(diff):
            return NativeToolEventRowSummary(
                text: diff.path,
                suffix: diff.changed ? "+\(diff.added) / -\(diff.removed)" : "No changes",
                isError: false
            )
        case let .deliverable(deliverable):
            return NativeToolEventRowSummary(
                text: deliverable.title ?? deliverable.path,
                suffix: ByteCountFormatter.string(fromByteCount: Int64(deliverable.bytes), countStyle: .file),
                isError: false
            )
        case let .search(search):
            return NativeToolEventRowSummary(
                text: search.query,
                suffix: "\(search.totalCount) items",
                isError: false
            )
        case let .web(web):
            switch web.kind {
            case .search:
                return NativeToolEventRowSummary(
                    text: web.queries.joined(separator: " · "),
                    suffix: "\(web.resultCount) sources",
                    isError: false
                )
            case .fetch:
                return NativeToolEventRowSummary(
                    text: web.url ?? "Web page",
                    suffix: web.statusCode.map { "HTTP \($0)" },
                    isError: (web.statusCode ?? 200) >= 400
                )
            }
        case let .job(job):
            let text = job.jobID ?? (job.kind == .list ? "Background Jobs" : "Job Control")
            let suffix = job.kind == .list ? "\(job.entries.count) items" : job.status
            return NativeToolEventRowSummary(
                text: text,
                suffix: suffix,
                isError: job.status == "failed"
            )
        case let .workItems(workItems):
            let head = "\(workItems.completedCount)/\(workItems.items.count) completed"
            guard let active = workItems.activeItems.first else {
                return NativeToolEventRowSummary(text: head, suffix: nil, isError: false)
            }
            let extra = workItems.activeItems.count - 1
            return NativeToolEventRowSummary(
                text: "\(head) · \(active.title)",
                suffix: extra > 0 ? "+\(extra)" : nil,
                isError: false
            )
        case let .terminal(terminal):
            return NativeToolEventRowSummary(
                text: terminal.firstCommandLine,
                suffix: nil,
                isError: terminal.failedExit
            )
        case let .workflow(workflow):
            let head = workflow.members.isEmpty
                ? "Preparing to run"
                : "\(workflow.completedMembers)/\(workflow.members.count) subagents"
            let suffix = workflow.durationMilliseconds.map { duration in
                duration < 1_000 ? "\(duration)ms" : String(format: "%.1fs", Double(duration) / 1_000)
            }
            return NativeToolEventRowSummary(
                text: workflow.name + " · " + head,
                suffix: suffix,
                isError: workflow.status == .failed || workflow.status == .interrupted || workflow.status == .denied
            )
        case .generic:
            let summary = event.summary.isEmpty ? firstLine(event.arguments) ?? event.name : event.summary
            return NativeToolEventRowSummary(text: compact(summary), suffix: nil, isError: false)
        }
    }

    private static func firstLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \Character.isNewline).first.map(String.init)
    }

    private static func compact(_ text: String, maximumCharacters: Int = 220) -> String {
        let normalized = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maximumCharacters else { return normalized }
        return String(normalized.prefix(maximumCharacters)) + "…"
    }
}

struct NativeToolEventBody: View {
    let presentation: NativeToolEventPresentation
    let event: AgentToolEvent

    var body: some View {
        switch presentation {
        case let .workspaceRead(read):
            WorkspaceReadToolCard(model: read)
        case let .workspaceWrite(write):
            WorkspaceWriteToolCard(model: write)
        case let .workspaceFiles(files):
            WorkspaceFilesToolCard(model: files)
        case let .diff(diff):
            DiffToolCard(model: diff)
        case let .deliverable(deliverable):
            DeliverableToolCard(model: deliverable)
        case let .search(search):
            SearchToolCard(model: search)
        case let .web(web):
            WebToolCard(model: web)
        case let .job(job):
            JobToolCard(model: job)
        case let .workItems(workItems):
            WorkItemsToolCard(model: workItems)
        case let .terminal(terminal):
            TerminalToolCard(model: terminal)
        case let .workflow(workflow):
            WorkflowToolCard(model: workflow)
        case .generic:
            GenericToolEventBody(event: event)
        }
    }
}

private struct SearchToolCard: View {
    let model: NativeSearchPresentation
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HarnessIconTile(systemImage: model.kind == .glob ? "doc.text.magnifyingglass" : "magnifyingglass", tint: .blue, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.query)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let root = model.root {
                        Text(root)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text("\(model.totalCount) items")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()
            if model.matches.isEmpty {
                Text("No matches found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(slice.head) { match in row(match) }
                    if slice.hidden > 0 {
                        Button(expanded ? "Collapse" : "Show \(slice.hidden) more") {
                            expanded.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    ForEach(slice.tail) { match in row(match) }
                }
            }

            if model.truncated || model.filesVisited != nil || model.spillLocator != nil {
                Divider()
                HStack(spacing: 6) {
                    if model.truncated {
                        Image(systemName: "ellipsis.circle")
                        Text("Results truncated")
                    }
                    if let filesVisited = model.filesVisited {
                        Text("Scanned \(filesVisited) items")
                    }
                    if let locator = model.spillLocator {
                        Text("Full results: \(locator)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption2)
                .foregroundStyle(model.truncated ? .orange : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .toolSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search \(model.query), \(model.totalCount) results")
    }

    private var slice: ToolHeadTailSlice<NativeSearchMatchPresentation> {
        ToolHeadTailSlice(items: model.matches, maximumVisible: 6, expanded: expanded)
    }

    private func row(_ match: NativeSearchMatchPresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(match.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let line = match.line {
                    Text(":\(line)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let excerpt = match.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WebToolCard: View {
    let model: NativeWebPresentation
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.kind == .search {
                if model.sources.isEmpty {
                    Text("No search results")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                } else {
                    ForEach(sourceSlice.head) { source in sourceRow(source) }
                    if sourceSlice.hidden > 0 {
                        Button(expanded ? "Collapse" : "Show \(sourceSlice.hidden) more sources") {
                            expanded.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    ForEach(sourceSlice.tail) { source in sourceRow(source) }
                }
            } else if let preview = model.contentPreview {
                Text(preview.isEmpty ? "Page body is empty" : preview)
                    .font(.caption2.monospaced())
                    .foregroundStyle(preview.isEmpty ? .secondary : .primary)
                    .lineLimit(expanded ? nil : 12)
                    .textSelection(.enabled)
                    .padding(10)
                if preview.count > 500 || model.truncated {
                    Button(expanded ? "Collapse Text" : "Expand Text") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 7)
                }
            }

            if model.truncated {
                Divider()
                Label("Content truncated to the phone display limit", systemImage: "ellipsis.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .toolSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.kind == .search ? "Web search, \(model.resultCount) sources" : "Web fetch")
    }

    private var header: some View {
        HStack(spacing: 8) {
            HarnessIconTile(systemImage: model.kind == .search ? "globe.badge.chevron.backward" : "doc.text.magnifyingglass", tint: .cyan, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.kind == .search ? model.queries.joined(separator: " · ") : (model.url ?? "Web page"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.kind == .fetch, let bodyKind = model.bodyKind {
                    Text(bodyKind.uppercased())
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let status = model.statusCode {
                Text("HTTP \(status)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(status >= 400 ? .red : .secondary)
            } else {
                Text("\(model.resultCount) sources")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var sourceSlice: ToolHeadTailSlice<NativeWebSourcePresentation> {
        ToolHeadTailSlice(items: model.sources, maximumVisible: 5, expanded: expanded)
    }

    private func sourceRow(_ source: NativeWebSourcePresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(source.rank)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(source.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(URL(string: source.url)?.host ?? source.provider)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !source.snippet.isEmpty {
                Text(source.snippet)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct JobToolCard: View {
    let model: NativeJobPresentation
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HarnessIconTile(systemImage: model.kind == .list ? "list.bullet.rectangle" : "gearshape.2", tint: statusTint, size: 28)
                Text(model.jobID ?? "Background Jobs")
                    .font(.caption.weight(.semibold).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(statusLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(statusTint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()
            if model.kind == .list {
                if model.entries.isEmpty {
                    Text("No background jobs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                } else {
                    ForEach(entrySlice.head) { entry in entryRow(entry) }
                    if entrySlice.hidden > 0 {
                        Button(expanded ? "Collapse" : "Show \(entrySlice.hidden) more") {
                            expanded.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    ForEach(entrySlice.tail) { entry in entryRow(entry) }
                }
            } else if model.outputPreview.isEmpty {
                Text("No new output")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                Text(model.outputPreview)
                    .font(.caption2.monospaced())
                    .lineLimit(expanded ? nil : 10)
                    .textSelection(.enabled)
                    .padding(10)
                if model.totalLines > 10 || model.truncated {
                    Button(expanded ? "Collapse Output" : "Expand Output") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 7)
                }
            }

            if let detail = model.detail, !detail.isEmpty {
                Divider()
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .toolSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Background job \(model.jobID ?? "list"), \(statusLabel)")
    }

    private var entrySlice: ToolHeadTailSlice<NativeJobEntryPresentation> {
        ToolHeadTailSlice(items: model.entries, maximumVisible: 6, expanded: expanded)
    }

    private var statusLabel: String {
        if model.kind == .list { return "\(model.entries.count) items" }
        switch model.status {
        case "running": return "Running"
        case "stopping": return "Stopping"
        case "completed": return "Completed"
        case "killed": return "Stopped"
        case "failed": return "Failed"
        default: return model.status ?? "Unknown status"
        }
    }

    private var statusTint: Color {
        switch model.status {
        case "running": .blue
        case "stopping": .orange
        case "completed": .green
        case "failed": .red
        default: .secondary
        }
    }

    private func entryRow(_ entry: NativeJobEntryPresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(entry.status == "completed" ? Color.green : (entry.status == "failed" ? Color.red : Color.blue))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(entry.id) · \(entry.kind)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text(entry.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct DiffToolCard: View {
    let model: NativeDiffPresentation
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HarnessIconTile(systemImage: "arrow.left.arrow.right", tint: .orange, size: 28)
                Text(model.path)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("+\(model.added) / -\(model.removed)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            if model.changed {
                Text(model.diff)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(expanded ? nil : 12)
                    .padding(10)
                Button(expanded ? "Collapse Diff" : "Expand Full Diff") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 7)
            } else {
                Text("No file changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
        }
        .toolSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File diff \(model.path)")
    }
}

private struct DeliverableToolCard: View {
    let model: NativeDeliverablePresentation
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HarnessIconTile(systemImage: "doc.badge.plus", tint: .green, size: 28)
                Text(model.title ?? model.path)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(ByteCountFormatter.string(fromByteCount: Int64(model.bytes), countStyle: .file))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            Text(model.preview)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .lineLimit(expanded ? nil : 10)
                .padding(10)
            HStack {
                Text("\(model.lines) lines · \(model.path)")
                Spacer()
                if model.truncated {
                    Button(expanded ? "Collapse" : "Expand Preview") { expanded.toggle() }
                        .buttonStyle(.plain)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
        }
        .toolSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Deliverable \(model.path)")
    }
}

private struct WorkspaceReadToolCard: View {
    let model: NativeWorkspaceReadPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(model.path)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let languageHint = model.languageHint {
                    Text(languageHint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(lineCountLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if model.totalLines == 0 {
                Text("Empty file")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ToolTextRows(
                    lines: model.lines,
                    totalLines: model.totalLines,
                    style: .read
                )
            }
        }
        .toolSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Read file \(model.path), \(lineCountLabel)")
    }

    private var lineCountLabel: String {
        if model.previewTruncated || model.lines.count < model.totalLines {
            return "Preview \(model.lines.count) / \(model.totalLines) lines"
        }
        return "\(model.totalLines) lines"
    }
}

private struct WorkspaceWriteToolCard: View {
    let model: NativeWorkspaceWritePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HarnessIconTile(systemImage: "square.and.pencil", tint: .green, size: 28)
                Text(model.path)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let languageHint = model.languageHint {
                    Text(languageHint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if model.totalLines == 0 {
                Text("Wrote empty file")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ToolTextRows(
                    lines: model.lines,
                    totalLines: model.totalLines,
                    style: .added
                )
            }

            Divider()
            Text(footer)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .toolSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Write file \(model.path), \(model.totalLines) lines")
    }

    private var footer: String {
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(model.byteCount),
            countStyle: .file
        )
        let preview = model.previewTruncated ? " · UI preview truncated" : ""
        return "└ Wrote \(model.totalLines) lines · \(size)\(preview)"
    }
}

private enum ToolTextRowStyle {
    case read
    case added
}

private struct ToolTextDisplayRow: Identifiable {
    enum Content {
        case line(NativeToolTextLine)
        case gap(Int)
    }

    let id: String
    let content: Content
}

private struct ToolTextRows: View {
    let lines: [NativeToolTextLine]
    let totalLines: Int
    let style: ToolTextRowStyle

    @State private var isExpanded = false

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(headRows) { row in
                    rowView(row)
                }
                if hiddenCount > 0 {
                    expandButton
                }
                ForEach(tailRows) { row in
                    rowView(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 230)
    }

    private var displayRows: [ToolTextDisplayRow] {
        var rows: [ToolTextDisplayRow] = []
        rows.reserveCapacity(lines.count + 1)
        var previousNumber: Int?
        for line in lines {
            if let previousNumber, line.number > previousNumber + 1 {
                let omitted = line.number - previousNumber - 1
                rows.append(
                    ToolTextDisplayRow(
                        id: "gap-\(previousNumber)-\(line.number)",
                        content: .gap(omitted)
                    )
                )
            }
            rows.append(
                ToolTextDisplayRow(id: "line-\(line.number)", content: .line(line))
            )
            previousNumber = line.number
        }
        return rows
    }

    private var slice: ToolHeadTailSlice<ToolTextDisplayRow> {
        ToolHeadTailSlice(items: displayRows, maximumVisible: 8, expanded: isExpanded)
    }

    private var headRows: [ToolTextDisplayRow] { slice.head }
    private var tailRows: [ToolTextDisplayRow] { slice.tail }
    private var hiddenCount: Int { slice.hidden }

    private var expandButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Text(isExpanded ? "Collapse" : "… \(hiddenCount) more lines")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse content" : "Show \(hiddenCount) more lines")
    }

    @ViewBuilder
    private func rowView(_ row: ToolTextDisplayRow) -> some View {
        switch row.content {
        case let .gap(omitted):
            Text("… \(omitted) lines omitted from UI preview")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        case let .line(line):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if style == .read {
                    Text("\(line.number)")
                        .frame(width: 36, alignment: .trailing)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("+")
                        .frame(width: 12, alignment: .trailing)
                        .foregroundStyle(.green)
                }
                Text(line.text + (line.isTruncated ? " …" : ""))
                    .foregroundStyle(style == .added ? .green : .primary)
            }
            .font(.caption.monospaced())
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
        }
    }
}

private struct WorkspaceFilesToolCard: View {
    let model: NativeWorkspaceFilesPresentation

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(model.files.count) paths")
                    .font(.caption.weight(.semibold))
                Spacer()
                HarnessIconTile(systemImage: "doc.on.doc", tint: .secondary, size: 28)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if model.files.isEmpty {
                Text("No text files in the workspace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ForEach(slice.head) { file in
                    fileRow(file)
                }
                if slice.hidden > 0 {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Text(isExpanded ? "Collapse" : "… \(slice.hidden) more paths")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse paths" : "Show \(slice.hidden) more paths")
                }
                ForEach(slice.tail) { file in
                    fileRow(file)
                }
            }
        }
        .toolSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File list, \(model.files.count) paths")
    }

    private var slice: ToolHeadTailSlice<NativeWorkspaceFilePresentation> {
        ToolHeadTailSlice(items: model.files, maximumVisible: 8, expanded: isExpanded)
    }

    private func fileRow(_ file: NativeWorkspaceFilePresentation) -> some View {
        HStack(spacing: 8) {
            HarnessIconTile(systemImage: "doc.text", tint: .secondary, size: 24)
            Text(file.path)
                .font(.caption.monospaced())
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

private struct WorkItemsToolCard: View {
    let model: NativeWorkItemsPresentation

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(model.kind == .todos ? "To-Do List" : "Execution Plan")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text("\(model.completedCount)/\(model.items.count) completed")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if model.items.isEmpty {
                Text("List is empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ForEach(slice.head) { item in
                    itemRow(item)
                }
                if slice.hidden > 0 {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Text(isExpanded ? "Collapse" : "… \(slice.hidden) more items")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse list" : "Show \(slice.hidden) more")
                }
                ForEach(slice.tail) { item in
                    itemRow(item)
                }
            }
        }
        .toolSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.kind == .todos ? "To-Do List" : "Execution Plan"), \(model.completedCount) of \(model.items.count) completed")
    }

    private var slice: ToolHeadTailSlice<NativeWorkItemPresentation> {
        ToolHeadTailSlice(items: model.items, maximumVisible: 8, expanded: isExpanded)
    }

    private func itemRow(_ item: NativeWorkItemPresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HarnessIconTile(systemImage: statusIcon(item.status), tint: statusTint(item.status), size: 24)
            Text(item.title)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(statusTitle(item.status))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private func statusIcon(_ status: ConversationItemStatus) -> String {
        switch status {
        case .pending: "circle"
        case .active: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .blocked: "exclamationmark.octagon.fill"
        }
    }

    private func statusTint(_ status: ConversationItemStatus) -> Color {
        switch status {
        case .pending, .paused: .secondary
        case .active: .blue
        case .completed: .green
        case .blocked: .red
        }
    }

    private func statusTitle(_ status: ConversationItemStatus) -> String {
        switch status {
        case .pending: "Pending"
        case .active: "In Progress"
        case .paused: "Paused"
        case .completed: "Completed"
        case .blocked: "Blocked"
        }
    }
}

private struct WorkflowToolCard: View {
    let model: NativeWorkflowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HarnessIconTile(systemImage: "arrow.triangle.branch", tint: model.status == .failed ? .red : .blue, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let description = model.description, !description.isEmpty {
                        Text(description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if let duration = model.durationMilliseconds {
                    Text(durationLabel(duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if !model.phases.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.phases) { phase in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: phase.isCompleted ? "checkmark.circle.fill" : (phase.isCurrent ? "circle.inset.filled" : "circle"))
                                .font(.caption2)
                                .foregroundStyle(phase.isCompleted ? Color.green : (phase.isCurrent ? Color.blue : Color.secondary))
                            Text(phase.title)
                                .font(.caption)
                                .fontWeight(phase.isCurrent ? .semibold : .regular)
                            if let detail = phase.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            if !model.members.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Subagents")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(model.completedMembers)/\(model.members.count) done")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.members) { member in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: memberIcon(member.status))
                                .font(.caption2)
                                .foregroundStyle(memberTint(member.status))
                            Text("\(member.sequence). \(member.label)")
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 5)
                            if let duration = member.durationMilliseconds {
                                Text(durationLabel(duration))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(memberStatus(member.status))
                                .font(.caption2)
                                .foregroundStyle(memberTint(member.status))
                        }
                        if let error = member.error, !error.isEmpty {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                                .padding(.leading, 22)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            if !model.logs.isEmpty || model.resultSummary != nil || model.errorMessage != nil {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    if let error = model.errorMessage, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                    }
                    ForEach(Array(model.logs.enumerated()), id: \.offset) { _, log in
                        Text(log)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let result = model.resultSummary, !result.isEmpty {
                        Text(result)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .toolSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workflow \(model.name), \(model.completedMembers) subagents completed")
    }

    private func durationLabel(_ milliseconds: Int) -> String {
        milliseconds < 1_000 ? "(milliseconds)ms" : String(format: "%.1fs", Double(milliseconds) / 1_000)
    }

    private func memberIcon(_ status: NativeWorkflowMemberStatus) -> String {
        switch status {
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private func memberTint(_ status: NativeWorkflowMemberStatus) -> Color {
        switch status {
        case .running: .blue
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    private func memberStatus(_ status: NativeWorkflowMemberStatus) -> String {
        switch status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

private struct TerminalToolCard: View {
    let model: NativeTerminalPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                runState
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.commandLines.prefix(3)) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(line.number == 1 ? "workspace" : "$")
                                .foregroundStyle(.green.opacity(0.9))
                            Text(line.text + (line.isTruncated ? " …" : ""))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption.monospaced())
                    }
                    if model.commandPreviewTruncated || model.commandLines.count > 3 {
                        Text("Command preview \(min(3, model.commandLines.count)) / \(model.commandTotalLines) lines")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                if let statusLabel {
                    Text(statusLabel)
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(statusTint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.08), in: .capsule)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(10)

            if !model.outputLines.isEmpty {
                Divider()
                    .overlay(.white.opacity(0.12))
                TerminalOutputRows(model: model)
            } else if !model.isRunning {
                Divider()
                    .overlay(.white.opacity(0.12))
                Text("No output")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(10)
            }

            if let metadataLabel {
                Divider()
                    .overlay(.white.opacity(0.12))
                Text(metadataLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .background(.black.opacity(0.88), in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("iSH terminal, \(terminalStatusTitle)")
    }

    @ViewBuilder
    private var runState: some View {
        if model.isRunning {
            ProgressView()
                .controlSize(.mini)
                .tint(.blue)
                .accessibilityLabel("Running")
        } else {
            Image(systemName: statusIcon)
                .font(.caption)
                .foregroundStyle(statusTint)
                .accessibilityLabel(terminalStatusTitle)
        }
    }

    private var statusLabel: String? {
        if model.isRunning { return "Running" }
        if model.status == .interrupted { return "Cancelled" }
        if let exitCode = model.exitCode, exitCode != 0 { return "Exit code \(exitCode)" }
        return nil
    }

    private var terminalStatusTitle: String {
        if model.isRunning { return "Running" }
        if model.status == .interrupted { return "Cancelled" }
        return model.failedExit ? "Failed" : "Completed"
    }

    private var statusIcon: String {
        if model.status == .interrupted { return "stop.circle.fill" }
        return model.failedExit ? "xmark.circle.fill" : "checkmark.circle.fill"
    }

    private var statusTint: Color {
        if model.status == .interrupted { return .white.opacity(0.7) }
        return model.failedExit ? .red : .green
    }

    private var metadataLabel: String? {
        var parts: [String] = []
        if let duration = model.durationMilliseconds {
            parts.append(duration >= 1_000
                ? String(format: "%.2f s", Double(duration) / 1_000)
                : "\(duration) ms")
        }
        if let processID = model.processID {
            parts.append("PID \(processID)")
        }
        if let timeout = model.timeoutSeconds {
            parts.append("Timeout \(timeout) s")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct TerminalOutputRows: View {
    let model: NativeTerminalPresentation

    @State private var isExpanded = false

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(slice.head) { line in
                    terminalLine(line)
                }
                if slice.hidden > 0 {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Text(isExpanded ? "Collapse" : "… \(slice.hidden) more lines")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse Output" : "Show \(slice.hidden) more output lines")
                }
                ForEach(slice.tail) { line in
                    terminalLine(line)
                }
                if model.outputPreviewTruncated {
                    Text("UI preview \(model.outputLines.count) / \(model.totalOutputLines) lines")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.yellow.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 230)
    }

    private var slice: ToolHeadTailSlice<NativeTerminalLine> {
        ToolHeadTailSlice(items: model.outputLines, maximumVisible: 8, expanded: isExpanded)
    }

    private func terminalLine(_ line: NativeTerminalLine) -> some View {
        HStack(spacing: 0) {
            ForEach(line.segments) { segment in
                Text(segment.text)
                    .foregroundStyle(outputTint(segment.channel))
            }
            if line.isTruncated {
                Text(" …")
                    .foregroundStyle(.yellow)
            }
        }
        .font(.caption.monospaced())
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    private func outputTint(_ channel: AgentToolOutputChannel) -> Color {
        switch channel {
        case .stdout: Color(white: 0.92)
        case .stderr: .red.opacity(0.92)
        case .progress: .cyan.opacity(0.92)
        case .system: .yellow.opacity(0.92)
        }
    }
}

private struct GenericToolEventBody: View {
    let event: AgentToolEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !event.arguments.isEmpty {
                genericSection(label: "IN") {
                    Text(limited(event.arguments))
                        .foregroundStyle(.secondary)
                }
            }

            if !event.arguments.isEmpty, hasOutput {
                Divider()
            }

            if hasOutput {
                genericSection(label: "OUT") {
                    if !event.output.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(event.output) { chunk in
                                Text(limited(chunk.text))
                                    .foregroundStyle(outputTint(chunk.channel))
                            }
                        }
                    } else if let result = event.result, !result.isEmpty {
                        Text(limited(result))
                            .foregroundStyle(.secondary)
                    } else if let error = event.errorMessage, !error.isEmpty {
                        Text(limited(error))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .toolSurface()
    }

    private var hasOutput: Bool {
        !event.output.isEmpty
            || !(event.result?.isEmpty ?? true)
            || !(event.errorMessage?.isEmpty ?? true)
    }

    private func genericSection<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .leading)
            ScrollView(.horizontal) {
                content()
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .padding(10)
        .frame(maxHeight: 170)
    }

    private func limited(_ text: String) -> String {
        guard text.utf8.count > 64 * 1_024 else { return text }
        var result = ""
        var usedBytes = 0
        for scalar in text.unicodeScalars {
            let fragment = String(scalar)
            let bytes = fragment.utf8.count
            guard usedBytes + bytes <= 64 * 1_024 else { break }
            result.unicodeScalars.append(scalar)
            usedBytes += bytes
        }
        return result + "\n[UI output truncated]"
    }

    private func outputTint(_ channel: AgentToolOutputChannel) -> Color {
        switch channel {
        case .stdout: .secondary
        case .stderr: .red
        case .progress: .blue
        case .system: .orange
        }
    }
}

private struct ToolHeadTailSlice<Item> {
    let head: [Item]
    let tail: [Item]
    let hidden: Int

    init(items: [Item], maximumVisible: Int, expanded: Bool) {
        hidden = max(0, items.count - maximumVisible)
        guard hidden > 0, !expanded else {
            head = items
            tail = []
            return
        }
        let headCount = (maximumVisible + 1) / 2
        let tailCount = maximumVisible - headCount
        head = Array(items.prefix(headCount))
        tail = Array(items.suffix(tailCount))
    }
}

private struct ToolSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(HarnessTheme.surface, in: .rect(cornerRadius: HarnessTheme.Radius.small))
            .overlay {
                RoundedRectangle(cornerRadius: HarnessTheme.Radius.small)
                    .strokeBorder(.separator.opacity(0.55), lineWidth: 0.5)
            }
    }
}

private extension View {
    func toolSurface() -> some View {
        modifier(ToolSurfaceModifier())
    }
}
