import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum CommunityPluginMarketMode: String, CaseIterable, Identifiable {
    case catalog
    case installed

    var id: Self { self }

    var title: String {
        switch self {
        case .catalog: "Market"
        case .installed: "Installed"
        }
    }
}

private enum CommunityPluginMarketSheet: String, Identifiable {
    case github

    var id: String { rawValue }
}

struct CommunityPluginMarketView: View {
    @Environment(AppModel.self) private var model
    @State private var mode = CommunityPluginMarketMode.catalog
    @State private var query = ""
    @State private var presentedSheet: CommunityPluginMarketSheet?
    @State private var isFileImporterPresented = false
    @State private var isActionsPresented = false

    var body: some View {
        List {
            HStack(spacing: 8) {
                Picker("Plugin View", selection: $mode) {
                    ForEach(CommunityPluginMarketMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("community-plugin-market-mode")
                .controlSize(.small)

                Button {
                    isActionsPresented = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("community-plugin-market-actions")
                .accessibilityLabel("Plugin Actions")
                .disabled(model.isISHPluginMarketplaceWorking)
            }
            .padding(.vertical, 0)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)

            CommunityPluginMarketHeader()
            CommunityPluginMarketplaceStateSections()
            if let trace = model.nativePluginCompilationTrace {
                CommunityPluginCompilationTraceSection(trace: trace)
            }

            switch mode {
            case .catalog:
                catalogContent
            case .installed:
                installedContent
            }
        }
        .communityPluginListChrome()
        .navigationTitle("Community Plugins")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            prompt: Text("Search plugins, categories, or repositories")
        )
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.refreshISHPluginMarketplace(forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier("community-plugin-market-refresh")
                .accessibilityLabel("Refresh Plugin Catalog")
                .disabled(model.isISHPluginMarketplaceWorking)
            }

        }
        .confirmationDialog(
            "Plugin Actions",
            isPresented: $isActionsPresented,
            titleVisibility: .visible
        ) {
            Button("Refresh Catalog") {
                Task { await model.refreshISHPluginMarketplace(forceRefresh: true) }
            }
            Button("GitHub Repository") {
                model.clearISHPluginMarketplaceFailure()
                presentedSheet = .github
            }
            Button("Import ZIP") {
                isFileImporterPresented = true
            }
            Button("Clear Download Cache") {
                Task { await model.clearISHPluginMarketplaceCache() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .github:
                CommunityPluginGitHubInstallSheet()
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else {
                if case let .failure(error) = result {
                    model.reportISHPluginMarketplaceError(error)
                }
                return
            }
            Task {
                _ = await model.importISHMarketplacePluginArchive(from: url)
            }
        }
        .task {
            if model.ishPluginMarketplaceCatalog == nil, !isUITestingMarketplaceFixtureRequested {
                await model.refreshISHPluginMarketplace()
            }
        }
        .refreshable {
            await model.refreshISHPluginMarketplace(forceRefresh: true)
        }
    }

    private var isUITestingMarketplaceFixtureRequested: Bool {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-present-plugin-market-for-ui-testing")
            || arguments.contains("-present-plugin-compilation-failure-for-ui-testing")
#else
        false
#endif
    }

    @ViewBuilder
    private var catalogContent: some View {
        if model.ishPluginMarketplaceCatalog == nil {
            if !model.isISHPluginMarketplaceWorking,
               model.ishPluginMarketplaceFailure == nil {
                CommunityPluginEmptyRow(
                    title: "Plugin Catalog Not Loaded",
                    detail: "Reload the community catalog, or install from GitHub or a local ZIP.",
                    systemImage: "shippingbox"
                ) {
                    Button {
                        Task { await model.refreshISHPluginMarketplace(forceRefresh: true) }
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                }
            }
        } else if filteredCatalogItems.isEmpty {
            CommunityPluginEmptyRow(
                title: query.isEmpty ? "No Plugins in Catalog" : "No Matching Plugins",
                detail: query.isEmpty ? "Refresh the catalog later, or install from GitHub or ZIP using the top-right menu." : "Try a different name, category, or repository keyword.",
                systemImage: query.isEmpty ? "shippingbox" : "magnifyingglass"
            )
        } else {
            Section {
                ForEach(filteredCatalogItems) { item in
                    NavigationLink {
                        CommunityPluginCatalogDetailView(itemID: item.id)
                    } label: {
                        CommunityPluginCatalogRow(item: item)
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 12))
                }
            } header: {
                HStack {
                    Text("Community Catalog")
                    Spacer()
                    if let catalog = model.ishPluginMarketplaceCatalog, catalog.stale {
                        Label("Cached", systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(filteredCatalogItems.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var installedContent: some View {
        if filteredInstalledPlugins.isEmpty {
            CommunityPluginEmptyRow(
                title: query.isEmpty ? "No Community Plugins Yet" : "No Matching Plugins",
                detail: query.isEmpty
                    ? "Plugins installed from the market, GitHub, or ZIP will appear here."
                    : "Try a different plugin name, version, or source keyword.",
                systemImage: query.isEmpty ? "shippingbox" : "magnifyingglass"
            )
        } else {
            Section {
                ForEach(filteredInstalledPlugins) { plugin in
                    NavigationLink {
                        CommunityInstalledPluginDetailView(pluginID: plugin.id)
                    } label: {
                        CommunityInstalledPluginRow(plugin: plugin)
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 12))
                }
            } header: {
                Label("Installed", systemImage: "shippingbox.fill")
            }
        }
    }

    private var filteredCatalogItems: [ISHMarketplaceCatalogItem] {
        let items = model.ishPluginMarketplaceCatalog?.items ?? []
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return items }
        return items.filter { item in
            [
                item.name,
                item.description,
                item.category,
                item.repositoryKey
            ].joined(separator: " ").lowercased().contains(normalized)
        }
    }

    private var filteredInstalledPlugins: [ISHMarketplacePlugin] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return model.ishMarketplacePlugins }
        return model.ishMarketplacePlugins.filter { plugin in
            [
                plugin.id,
                plugin.name,
                plugin.version,
                plugin.description ?? "",
                plugin.source.location,
                plugin.state.rawValue
            ].joined(separator: " ").lowercased().contains(normalized)
        }
    }
}

private struct CommunityPluginMarketplaceStateSections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let operation = model.ishPluginMarketplaceOperation {
            HStack(alignment: .top, spacing: 11) {
                HarnessIconTile(systemImage: "arrow.triangle.2.circlepath", tint: .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(operation.title(hostState: model.ishPluginHostState))
                        .font(.subheadline.weight(.semibold))
                    Text(operation.detail(hostState: model.ishPluginHostState))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
            .harnessCardListRow()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("community-plugin-market-status")
        }

        if let failure = model.ishPluginMarketplaceFailure {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 11) {
                    HarnessIconTile(systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Operation Failed")
                            .font(.subheadline.weight(.semibold))
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    if failure.canRetry {
                        Button {
                            Task { await model.retryISHPluginMarketplaceOperation() }
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .accessibilityIdentifier("community-plugin-market-retry")
                        .frame(minHeight: 44)
                    }
                    Button {
                        model.clearISHPluginMarketplaceFailure()
                    } label: {
                        Label("Close", systemImage: "xmark")
                    }
                    .frame(minHeight: 44)
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 6)
            .harnessCardListRow()
            .accessibilityIdentifier("community-plugin-market-error")
        }
    }
}

private struct CommunityPluginCompilationTraceSection: View {
    let trace: NativePluginCompilationTrace
    @State private var isExpanded = true
    @State private var areLogsExpanded = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(trace.steps) { step in
                        CommunityPluginCompilationStepRow(step: step)
                    }
                }

                if !trace.logs.isEmpty {
                    DisclosureGroup(isExpanded: $areLogsExpanded) {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(trace.logs) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(entry.timestamp.formatted(
                                        .dateTime.hour().minute().second()
                                            .locale(Locale(identifier: "en_US"))
                                    ))
                                        .foregroundStyle(.tertiary)
                                    Text(entry.stage.title)
                                        .foregroundStyle(entry.state.tint)
                                    Text(entry.message)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 6)
                        .accessibilityIdentifier("community-plugin-compilation-logs")
                    } label: {
                        HStack {
                            Text("Detailed Log")
                        }
                        .accessibilityIdentifier("community-plugin-compilation-logs-toggle")
                    }
                    .font(.caption)
                    .padding(.top, 8)
                }

                if let diagnostic = trace.diagnostic {
                    VStack(alignment: .leading, spacing: 5) {
                        HarnessStatusPill(
                            title: diagnostic.retryable ? "Retryable" : "Action Needed",
                            systemImage: diagnostic.retryable ? "arrow.triangle.2.circlepath" : "hand.raised.fill",
                            tint: diagnostic.retryable ? .orange : .red
                        )
                        Text("Structured Diagnostic · \(diagnostic.code)")
                            .font(.caption.weight(.semibold))
                        Text(diagnostic.message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(diagnostic.suggestedAction)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 10)
                    .accessibilityIdentifier("community-plugin-compilation-diagnostic")
                }
            } label: {
                HStack(spacing: 10) {
                    HarnessIconTile(
                        systemImage: hasFailure
                            ? "xmark.octagon.fill"
                            : trace.isFinished ? "checklist.checked" : "hammer.fill",
                        tint: hasFailure ? .red : trace.isFinished ? .green : .accentColor
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trace.isFinished ? "Latest Compilation Result" : "Phone Agent Compiling")
                            .font(.subheadline.weight(.semibold))
                        Text(trace.outcome ?? currentSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    HarnessStatusPill(
                        title: hasFailure ? "Failed" : trace.isFinished ? "Finished" : "In Progress",
                        systemImage: hasFailure ? "xmark" : trace.isFinished ? "checkmark" : "ellipsis",
                        tint: hasFailure ? .red : trace.isFinished ? .green : .accentColor
                    )
                }
                .accessibilityIdentifier("community-plugin-compilation-summary")
            }
        } header: {
            Text("Agent Native Compilation")
        } footer: {
            Label {
                Text(trace.source)
            } icon: {
                Image(systemName: "shippingbox")
            }
                .fontDesign(.monospaced)
                .textSelection(.enabled)
                .accessibilityIdentifier("community-plugin-compilation-source")
        }
        .onChange(of: trace.id) {
            isExpanded = true
            areLogsExpanded = false
        }
    }

    private var currentSummary: String {
        trace.steps.last(where: { $0.state == .running })?.detail
            ?? trace.steps.last(where: { $0.state == .failed })?.detail
            ?? "Waiting to Start"
    }

    private var hasFailure: Bool {
        trace.steps.contains { $0.state == .failed }
    }
}

private struct CommunityPluginCompilationStepRow: View {
    let step: NativePluginCompilationStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if step.state == .running {
                    HarnessIconTile(systemImage: "ellipsis", tint: .accentColor, size: 28)
                } else {
                    HarnessIconTile(systemImage: step.state.iconName, tint: step.state.tint, size: 28)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(step.stage.title)
                    .font(.subheadline.weight(.medium))
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HarnessStatusPill(
                title: step.state.title,
                systemImage: step.state.iconName,
                tint: step.state.tint
            )
        }
        .padding(.vertical, 7)
    }
}

private extension NativePluginCompilationStageState {
    var iconName: String {
        switch self {
        case .pending: "clock"
        case .running: "circle.dotted"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .pending, .skipped: .secondary
        case .running: .accentColor
        case .succeeded: .green
        case .failed: .red
        }
    }

    var title: String {
        switch self {
        case .pending: "Waiting"
        case .running: "In Progress"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .skipped: "Skipped"
        }
    }
}

/// A compact, Minis-style summary sits above the catalog so the page remains
/// useful while the Host is starting or the remote catalog is unavailable.
private struct CommunityPluginMarketHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            HStack(spacing: 12) {
                HarnessIconTile(
                    systemImage: "puzzlepiece.extension.fill",
                    tint: .accentColor,
                    size: 36
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Native First")
                        .font(.headline)
                    Text("Catalog \(catalogCount) · Native \(model.nativeInstalledMarketplaceCount) · iSH \(model.ishFallbackMarketplaceCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                hostStatus
            }
        } footer: {
            Text("Installs try native compilation first and fall back to on-device iSH only when incompatible.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("community-plugin-market-summary")
    }

    private var catalogCount: String {
        model.ishPluginMarketplaceCatalog.map { "\($0.items.count)" } ?? "-"
    }

    private var hostStatus: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Image(systemName: model.ishPluginHostState.iconName)
                .foregroundStyle(model.ishPluginHostState.tint)
            Text(model.ishPluginHostState.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 54)
    }

}

private struct CommunityPluginEmptyRow<Actions: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let actions: Actions

    init(
        title: String,
        detail: String,
        systemImage: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 10)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowSeparator(.hidden)
    }
}

private extension CommunityPluginEmptyRow where Actions == EmptyView {
    init(title: String, detail: String, systemImage: String) {
        self.init(title: title, detail: detail, systemImage: systemImage) {
            EmptyView()
        }
    }
}

private extension ISHPluginMarketplaceOperation {
    func title(hostState: ISHPluginHostRuntimeState) -> String {
        switch self {
        case .preparingHost:
            switch hostState {
            case .installing: "Installing iSH Plugin Host"
            case .starting: "Starting iSH Plugin Host"
            case .running: "Checking iSH Plugin Host"
            case .stopped, .failed: "Preparing iSH Plugin Host"
            }
        case .loadingCatalog: "Loading Community Plugin Catalog"
        case .preparingNativePlugin: "Downloading and Analyzing Plugin Source"
        case .installingPlugin: "Downloading and Installing Plugin"
        case .updatingPlugin: "Downloading and Updating Plugin"
        case .compilingNativePlugin: "Phone Agent Is Compiling Native Plugin"
        case .enablingPlugin: "Enabling Plugin"
        case .disablingPlugin: "Disabling Plugin"
        case .uninstallingPlugin: "Uninstalling Plugin"
        case .clearingCache: "Clearing Plugin Cache"
        }
    }

    func detail(hostState: ISHPluginHostRuntimeState) -> String {
        switch self {
        case .preparingHost:
            switch hostState {
            case .installing:
                "First-time installation of Node and Cordis dependencies usually takes 40–60 seconds. Keep the app in the foreground."
            case .starting:
                "Dependencies are ready. Starting the local on-device Host."
            case .running:
                "Verifying the Host version and installed plugins."
            case .stopped, .failed:
                "Checking the on-device iSH environment and Host dependencies."
            }
        case .loadingCatalog:
            "iSH guest networking is on by default. Catalog loading still happens entirely on device, and you can turn networking off on the Commands page."
        case .preparingNativePlugin:
            "Preparing a restricted source snapshot on device, first trying to compile native tools that the signed built-in engine can run."
        case .installingPlugin, .updatingPlugin:
            "Native adaptation fell short; falling back to iSH. Verification and dependency installation still happen entirely on device."
        case .compilingNativePlugin:
            "Source was handed from the isolated environment to the phone Agent. Generated output is verified and registered by Swift; no new binaries are loaded."
        case .enablingPlugin, .disablingPlugin:
            "Syncing Host and native tool contribution state."
        case .uninstallingPlugin:
            "Removing the plugin, its dependencies, and runtime contributions."
        case .clearingCache:
            "Only clears the plugin download cache; workspace files are not deleted."
        }
    }
}

private struct CommunityPluginCatalogRow: View {
    let item: ISHMarketplaceCatalogItem

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            HarnessIconTile(systemImage: item.compatibility.iconName, tint: item.compatibility.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(item.category)
                    Text("·")
                        .accessibilityHidden(true)
                    Label(
                        // Desktop parity (D-010): entries without an explicit
                        // strategy install into the local host runtime by
                        // default; only entries tagged native-first show the
                        // native manifest compile.
                        item.nativeInstallStrategy?.title
                            ?? ISHMarketplaceInstallPreference.hostLoad.label,
                        systemImage: item.nativeInstallStrategy?.iconName
                            ?? "shippingbox"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)
            if item.installed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Installed")
            }
        }
        .contentShape(Rectangle())
    }
}

private struct CommunityInstalledPluginRow: View {
    let plugin: ISHMarketplacePlugin

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            HarnessIconTile(systemImage: plugin.state.iconName, tint: plugin.state.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                if let description = plugin.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(plugin.state.title)
                    Text("·")
                        .accessibilityHidden(true)
                    Text(
                        plugin.id.hasPrefix(NativeAgentCompiledPlugin.idPrefix)
                            ? "Native"
                            : "iSH Fallback"
                    )
                    Text("·")
                        .accessibilityHidden(true)
                    Text("v\(plugin.version)")
                    Text("·")
                        .accessibilityHidden(true)
                    Text("\(plugin.entryCount) entries")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }
}

private struct CommunityPluginCatalogDetailView: View {
    @Environment(AppModel.self) private var model
    let itemID: String
    @State private var isConfirmationPresented = false

    var body: some View {
        Group {
            if let item {
                List {
                    CommunityPluginMarketplaceStateSections()

                    Section {
                        LabeledContent("Category", value: item.category)
                        LabeledContent("Compatibility", value: item.compatibility.title)
                        if let installedVersion = item.installedVersion {
                            LabeledContent("Installed", value: installedVersion)
                        }
                        LabeledContent(
                            "Install Path",
                            value: (item.nativeInstallStrategy ?? .nativeFirst).title
                        )
                    } header: {
                        Label("Plugin", systemImage: "puzzlepiece.extension")
                    }

                    if !item.description.isEmpty {
                        Section {
                            Text(item.description)
                                .textSelection(.enabled)
                        } header: {
                            Label("Description", systemImage: "text.alignleft")
                        }
                    }

                    Section {
                        Text(item.repositoryURL)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    } header: {
                        Label("Source", systemImage: "link")
                    }

                    if let reason = item.unsupportedReason {
                        Section {
                            Label(reason, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(item.compatibility == .unsupported ? .orange : .secondary)
                        } header: {
                            Label("Phone Compatibility", systemImage: "iphone.gen3")
                        }
                    }

                    Section {
                        Button {
                            isConfirmationPresented = true
                        } label: {
                            Label(
                                item.installed ? "Reinstall" : "Install (Native First)",
                                systemImage: "arrow.down.app"
                            )
                        }
                        .disabled(
                            model.isISHPluginMarketplaceWorking
                        )
                    } footer: {
                        Text("Installation first analyzes the source on device and tries to register signed native tools; it runs in iSH only if that isn't compatible.")
                    }
                }
                .communityPluginListChrome()
                .confirmationDialog(
                    item.installed ? "Reinstall Plugin?" : "Install Community Plugin?",
                    isPresented: $isConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button(item.installed ? "Update and Keep Enabled State" : "Install") {
                        Task {
                            _ = await model.installISHMarketplacePlugin(
                                source: ISHMarketplacePluginSource(
                                    kind: .market,
                                    location: item.repositoryURL
                                ),
                                replace: item.installed,
                                preference: item.nativeInstallStrategy == .nativeFirst
                                    ? .nativeCompile
                                    : .hostLoad
                            )
                        }
                    }
                } message: {
                    Text("Desktop parity (D-010): plugins load into the local runtime by default; entries marked Native First are compiled as native tools. Plugins never receive model keys.")
                }
            } else {
                ContentUnavailableView("Plugin Unavailable", systemImage: "shippingbox")
            }
        }
        .navigationTitle(item?.name ?? "Plugin")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var item: ISHMarketplaceCatalogItem? {
        model.ishPluginMarketplaceCatalog?.items.first { $0.id == itemID }
    }
}

private enum CommunityInstalledPluginAction: String {
    case enable
    case reinstall
    case uninstall
}

private struct CommunityInstalledPluginDetailView: View {
    @Environment(AppModel.self) private var model
    let pluginID: String
    @State private var pendingAction: CommunityInstalledPluginAction?

    var body: some View {
        Group {
            if let plugin {
                List {
                    CommunityPluginMarketplaceStateSections()

                    Section {
                        LabeledContent("Status", value: plugin.state.title)
                        LabeledContent("Version", value: plugin.version)
                        LabeledContent("Entries", value: "\(plugin.entryCount)")
                        Toggle(
                            "Enable Plugin",
                            isOn: Binding(
                                get: { plugin.enabled },
                                set: { enabled in
                                    if enabled {
                                        pendingAction = .enable
                                    } else {
                                        Task {
                                            await model.setISHMarketplacePluginEnabled(
                                                id: pluginID,
                                                enabled: false
                                            )
                                        }
                                    }
                                }
                            )
                        )
                        .disabled(model.isISHPluginMarketplaceWorking)
                    } header: {
                        Label("Runtime Status", systemImage: "power")
                    }

                    if let nativeClient {
                        Section {
                            NavigationLink {
                                NativeClientContributionsView(pluginID: pluginID)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Native Client")
                                        Text(
                                            "\(nativeClient.contributions.inspectors.count) inspectors · "
                                                + "\(nativeClient.contributions.settings.count) settings · "
                                                + "\(nativeClient.contributions.commands.count) commands"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "puzzlepiece.extension")
                                }
                            }
                            .accessibilityIdentifier("native-client-open-\(pluginID)")
                        } header: {
                            Label("Native Extensions", systemImage: "puzzlepiece.extension")
                        }
                    }

                    if nativeAgentPlugin?.settings != nil {
                        Section {
                            NavigationLink {
                                NativeAgentPluginSettingsView(pluginID: pluginID)
                            } label: {
                                Label("Plugin Settings", systemImage: "slider.horizontal.3")
                            }
                            .accessibilityIdentifier("native-agent-settings-\(pluginID)")
                        } header: {
                            Label("Native Plugin", systemImage: "swift")
                        }
                    }

                    if !nativeClientFailures.isEmpty {
                        Section {
                            ForEach(nativeClientFailures) { failure in
                                Text(failure.message)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        } header: {
                            Label("Native Extension Failed to Load", systemImage: "exclamationmark.triangle")
                        }
                    }

                    if let description = plugin.description, !description.isEmpty {
                        Section {
                            Text(description)
                                .textSelection(.enabled)
                        } header: {
                            Label("Description", systemImage: "text.alignleft")
                        }
                    }

                    if let notes = nativeAgentPlugin?.compatibilityNotes,
                       !notes.isEmpty {
                        Section {
                            ForEach(notes, id: \.self) { note in
                                Label(note, systemImage: "info.circle")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        } header: {
                            Label("Compatibility Notes", systemImage: "info.circle")
                        }
                    }

                    Section {
                        LabeledContent("Type", value: plugin.source.kind.title)
                        Text(plugin.source.location)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        if let license = plugin.license {
                            LabeledContent("License", value: license)
                        }
                    } header: {
                        Label("Source", systemImage: "link")
                    }

                    if let error = plugin.lastError {
                        Section {
                            Text(error)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        } header: {
                            Label("Failed to Load", systemImage: "exclamationmark.triangle")
                        }
                    }

                    Section {
                        if plugin.source.kind != .localZip {
                            Button {
                                pendingAction = .reinstall
                            } label: {
                                Label("Redownload and Update", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(model.isISHPluginMarketplaceWorking)
                        }
                        Button(role: .destructive) {
                            pendingAction = .uninstall
                        } label: {
                            Label("Uninstall Plugin", systemImage: "trash")
                        }
                        .disabled(model.isISHPluginMarketplaceWorking)
                    } header: {
                        Label("Manage", systemImage: "slider.horizontal.3")
                    }
                }
                .communityPluginListChrome()
                .confirmationDialog(
                    "Confirm Plugin Action",
                    isPresented: Binding(
                        get: { pendingAction != nil },
                        set: { presented in
                            if !presented { pendingAction = nil }
                        }
                    ),
                    titleVisibility: .visible,
                    presenting: pendingAction
                ) { action in
                    switch action {
                    case .enable:
                        Button("Enable Third-Party Code") {
                            Task {
                                await model.setISHMarketplacePluginEnabled(
                                    id: pluginID,
                                    enabled: true
                                )
                            }
                        }
                    case .reinstall:
                        Button("Update and Keep Enabled State") {
                            Task {
                                _ = await model.installISHMarketplacePlugin(
                                    source: ISHMarketplacePluginSource(
                                        kind: plugin.source.kind,
                                        location: plugin.source.location
                                    ),
                                    replace: true
                                )
                            }
                        }
                    case .uninstall:
                        Button("Uninstall", role: .destructive) {
                            Task { await model.uninstallISHMarketplacePlugin(id: pluginID) }
                        }
                    }
                } message: { action in
                    switch action {
                    case .enable:
                        Text(
                            nativeAgentPlugin == nil
                                ? "The plugin will run inside the on-device iSH Host and can access the app's private workspace."
                                : "The plugin will be loaded by the app's signed Swift runtime and only gets the phone capabilities declared in its manifest and verified."
                        )
                    case .reinstall:
                        Text("If the new version fails to load, it rolls back to the currently installed version.")
                    case .uninstall:
                        Text("Uninstalling removes this plugin and the dependencies it installed in iSH.")
                    }
                }
            } else {
                ContentUnavailableView("Plugin Uninstalled", systemImage: "shippingbox")
            }
        }
        .navigationTitle(plugin?.name ?? pluginID)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var plugin: ISHMarketplacePlugin? {
        model.ishMarketplacePlugins.first { $0.id == pluginID }
    }

    private var nativeClient: ISHNativeClientPlugin? {
        model.ishNativeClientPlugins.first { $0.pluginId == pluginID }
    }

    private var nativeAgentPlugin: NativeAgentCompiledPlugin? {
        model.nativeAgentPlugins.first { $0.id == pluginID }
    }

    private var nativeClientFailures: [ISHNativeClientSynchronizationFailure] {
        model.ishNativeClientFailures.filter { $0.pluginID == pluginID }
    }
}

private struct CommunityPluginGitHubInstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var location = ""
    @State private var replaceExisting = false

    var body: some View {
        NavigationStack {
            List {
                CommunityPluginMarketplaceStateSections()

                Section {
                    TextField("https://github.com/owner/repository", text: $location)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Toggle("Replace Plugin with Same Name", isOn: $replaceExisting)
                } header: {
                    Label("GitHub", systemImage: "link")
                } footer: {
                    Text("Source is analyzed on device and installed natively when possible, falling back to iSH only if incompatible. Plugins never receive the model API Key.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Install Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Install") {
                        Task {
                            let installed = await model.installISHMarketplacePlugin(
                                source: ISHMarketplacePluginSource(
                                    kind: .github,
                                    location: normalizedLocation
                                ),
                                replace: replaceExisting
                            )
                            if installed { dismiss() }
                        }
                    }
                    .disabled(
                        model.isISHPluginMarketplaceWorking
                            || normalizedLocation.isEmpty
                    )
                }
            }
            .interactiveDismissDisabled(model.isISHPluginMarketplaceWorking)
        }
        .presentationDetents([.height(340), .medium])
    }

    private var normalizedLocation: String {
        location.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension View {
    func communityPluginListChrome() -> some View {
        listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 52)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
    }
}

private extension ISHMarketplaceCompatibility {
    var title: String {
        switch self {
        case .supported: "Host Compatible"
        case .review: "Needs Install Check"
        case .unsupported: "Desktop Client Only"
        }
    }

    var iconName: String {
        switch self {
        case .supported: "checkmark.shield.fill"
        case .review: "shield.lefthalf.filled"
        case .unsupported: "desktopcomputer.trianglebadge.exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .supported: .green
        case .review: .orange
        case .unsupported: .secondary
        }
    }
}

private extension ISHMarketplacePluginState {
    var title: String {
        switch self {
        case .enabled: "Running"
        case .disabled: "Off"
        case .failed: "Failed to Load"
        }
    }

    var iconName: String {
        switch self {
        case .enabled: "checkmark.circle.fill"
        case .disabled: "pause.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .enabled: .green
        case .disabled: .secondary
        case .failed: .red
        }
    }
}

private extension ISHMarketplacePluginSourceKind {
    var title: String {
        switch self {
        case .market: "Community Market"
        case .github: "GitHub"
        case .localZip: "Local ZIP"
        }
    }
}

private extension ISHPluginHostRuntimeState {
    var title: String {
        switch self {
        case .installing: "Installing"
        case .starting: "Starting"
        case .running(_, _): "Running"
        case .stopped: "Not Started"
        case .failed(_): "Error"
        }
    }

    var iconName: String {
        switch self {
        case .installing, .starting: "hourglass"
        case .running(_, _): "checkmark.circle.fill"
        case .stopped: "pause.circle"
        case .failed(_): "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .installing, .starting: .orange
        case .running(_, _): .green
        case .stopped: .secondary
        case .failed(_): .red
        }
    }
}
