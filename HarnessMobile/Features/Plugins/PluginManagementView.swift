import SwiftUI

struct PluginManagementView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var presentedSheet: PluginManagementSheet?

    var body: some View {
        List {
            Section {
                PluginRuntimeSummary(
                    installedCount: model.pluginSnapshots.count,
                    activeCount: activePluginCount,
                    hostCount: model.ishPluginHostInventory.count,
                    contributionSummary: "Tools \(model.pluginToolContributions.count) · Prompts \(model.pluginPromptContributions.count) · Clients \(model.ishNativeClientPlugins.count)"
                )
                .accessibilityIdentifier("plugin-runtime-summary")
            } header: {
                Label("Cordis Runtime", systemImage: "cpu")
            } footer: {
                Text("Native plugins can be hot-started, stopped, and rolled back. Community JavaScript plugins run in the on-device iSH Host.")
            }

            ISHPluginHostSection()

            if !filteredHostInventory.isEmpty {
                Section {
                    ForEach(filteredHostInventory, id: \.pluginId) { entry in
                        NavigationLink {
                            ISHPluginDetailView(pluginID: entry.pluginId)
                        } label: {
                            ISHPluginInventoryRow(entry: entry)
                        }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if let plan = entry.preferredActivationPlan {
                                    Button {
                                        Task {
                                            await model.runISHPlugin(
                                                pluginID: entry.pluginId,
                                                packageID: plan.packageID,
                                                mode: plan.mode
                                            )
                                        }
                                    } label: {
                                        Label(plan.title, systemImage: plan.iconName)
                                    }
                                    .tint(plan.tint)
                                }

                                if entry.activeRun != nil {
                                    Button {
                                        Task { await model.stopISHPlugin(pluginID: entry.pluginId) }
                                    } label: {
                                        Label("Stop", systemImage: "stop.fill")
                                    }
                                    .tint(.orange)
                                }

                                Button(role: .destructive) {
                                    Task { await model.undefineISHPlugin(pluginID: entry.pluginId) }
                                } label: {
                                    Label("Uninstall", systemImage: "trash")
                                }
                            }
                            .harnessCardListRow()
                    }
                } header: { Label("iSH Dynamic Plugins", systemImage: "terminal") }
            }

            if filteredSnapshots.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                Section {
                    ForEach(filteredSnapshots, id: \.id) { snapshot in
                        NavigationLink {
                            PluginDetailView(pluginID: snapshot.id)
                        } label: {
                            PluginInventoryRow(snapshot: snapshot)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                Task { await model.restartPlugin(id: snapshot.id) }
                            } label: {
                                Label("Restart", systemImage: "arrow.clockwise")
                            }
                            .tint(.blue)
                        }
                        .harnessCardListRow()
                    }
                } header: { Label("Plugins", systemImage: "puzzlepiece.extension") }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(HarnessTheme.pageBackground)
        .navigationTitle("Plugins")
        .searchable(text: $query, prompt: "Search plugins, dependencies, or services")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        presentedSheet = .experimentalPrompt
                    } label: {
                        Label("Prompt Plugin", systemImage: "text.badge.plus")
                    }
                    Button {
                        presentedSheet = .ishHostPlugin
                    } label: {
                        Label("iSH JavaScript Plugin", systemImage: "terminal")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Plugin")
                .accessibilityIdentifier("add-plugin-menu")
                .help("Add Plugin")
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .experimentalPrompt:
                ExperimentalPromptPluginSheet()
            case .ishHostPlugin:
                ISHHostPluginSheet()
            }
        }
        .task {
            await model.refreshPluginInventory()
        }
        .refreshable {
            await model.refreshPluginInventory()
        }
    }

    private var activePluginCount: Int {
        model.pluginSnapshots.count { $0.state == .active }
    }

    private var filteredSnapshots: [CordisPluginSnapshot] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return model.pluginSnapshots }
        return model.pluginSnapshots.filter { snapshot in
            let searchable = [
                snapshot.id.rawValue,
                snapshot.version,
                snapshot.state.rawValue,
                snapshot.dependencies.joined(separator: " "),
                snapshot.provides.joined(separator: " "),
                snapshot.missingDependencies.joined(separator: " "),
                snapshot.error ?? ""
            ].joined(separator: " ").lowercased()
            return searchable.contains(normalized)
        }
    }

    private var filteredHostInventory: [ISHPluginHostInventoryEntry] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return model.ishPluginHostInventory }
        return model.ishPluginHostInventory.filter { entry in
            let searchable = [
                entry.pluginId,
                entry.agentId,
                entry.currentPackageId ?? "",
                entry.nextPackageId ?? "",
                entry.packages.map { [$0.packageId, $0.name, $0.purpose].joined(separator: " ") }
                    .joined(separator: " ")
            ].joined(separator: " ").lowercased()
            return searchable.contains(normalized)
        }
    }
}

private struct PluginRuntimeSummary: View {
    let installedCount: Int
    let activeCount: Int
    let hostCount: Int
    let contributionSummary: String

    var body: some View {
        VStack(alignment: .leading, spacing: HarnessTheme.Spacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: HarnessTheme.Spacing.small) {
                    summaryItem("Installed", value: installedCount, icon: "puzzlepiece.extension", tint: .accentColor)
                    summaryItem("Running", value: activeCount, icon: "bolt.fill", tint: .green)
                    summaryItem("Host Plugins", value: hostCount, icon: "terminal.fill", tint: .orange)
                }

                VStack(alignment: .leading, spacing: HarnessTheme.Spacing.small) {
                    HStack(spacing: HarnessTheme.Spacing.small) {
                        summaryItem("Installed", value: installedCount, icon: "puzzlepiece.extension", tint: .accentColor)
                        summaryItem("Running", value: activeCount, icon: "bolt.fill", tint: .green)
                    }
                    summaryItem("Host Plugins", value: hostCount, icon: "terminal.fill", tint: .orange)
                }
            }
            Text(contributionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, HarnessTheme.Spacing.xSmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plugin runtime summary: \(installedCount) installed, \(activeCount) running, \(hostCount) Host plugins. \(contributionSummary)")
    }

    private func summaryItem(_ title: String, value: Int, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HarnessIconTile(systemImage: icon, tint: tint, size: 28)
            Text("\(value)")
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum PluginManagementSheet: String, Identifiable {
    case experimentalPrompt
    case ishHostPlugin

    var id: String { rawValue }
}

private struct ISHPluginHostSection: View {
    @Environment(AppModel.self) private var model
    @State private var isWorking = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: model.ishPluginHostState.iconName)
                    .font(.title3)
                    .foregroundStyle(model.ishPluginHostState.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("iSH Cordis Host")
                        .font(.headline)
                    Text(model.ishPluginHostState.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let processID = model.ishPluginHostState.processID {
                    Text("PID \(processID)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("ish-plugin-host-status")

            HStack(spacing: 10) {
                Button {
                    runHostAction(.start)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(isWorking || model.ishPluginHostState.isRunning)
                .accessibilityIdentifier("ish-plugin-host-start")

                Button {
                    runHostAction(.refresh)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isWorking || !model.ishPluginHostState.isRunning)
                .accessibilityIdentifier("ish-plugin-host-refresh")

                Button(role: .destructive) {
                    runHostAction(.stop)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(isWorking || !model.ishPluginHostState.isRunning)
                .accessibilityIdentifier("ish-plugin-host-stop")
            }
            .buttonStyle(.bordered)

            if !model.ishPluginHostPackages.isEmpty {
                ForEach(model.ishPluginHostPackages.keys.sorted(), id: \.self) { packageName in
                    LabeledContent(
                        packageName,
                        value: model.ishPluginHostPackages[packageName] ?? "-"
                    )
                    .font(.caption)
                }
            }

            NavigationLink {
                CommunityPluginMarketView()
            } label: {
                Label {
                    HStack {
                        Text("Community Plugin Marketplace")
                        Spacer()
                        if !model.ishMarketplacePlugins.isEmpty {
                            Text("\(model.ishMarketplacePlugins.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } icon: {
                    Image(systemName: "shippingbox.and.arrow.backward")
                }
            }
            .accessibilityIdentifier("community-plugin-market")

            NavigationLink {
                PluginSettingsView()
            } label: {
                Label {
                    HStack {
                        Text("Plugin Settings")
                        Spacer()
                        if let count = model.ishPluginSettingsSnapshot?.namespaces.count,
                           count > 0 {
                            Text("\(count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } icon: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
            .accessibilityIdentifier("ish-plugin-settings")

            if let diagnostics = model.ishPluginHostDiagnostics,
               !diagnostics.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Host stderr", systemImage: "waveform.path.ecg")
                        .font(.caption.weight(.semibold))
                    Text(diagnostics.stderrTail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("iSH Host")
        } footer: {
            Text("Dynamic definitions are released when the Host stops. Host plugins installed from the community marketplace persist in the on-device iSH workspace.")
        }
    }

    private func runHostAction(_ action: HostAction) {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            switch action {
            case .start:
                _ = await model.startISHPluginHost()
            case .refresh:
                await model.refreshISHPluginHost()
            case .stop:
                await model.stopISHPluginHost()
            }
            isWorking = false
        }
    }

    private enum HostAction {
        case start
        case refresh
        case stop
    }
}

private struct ISHPluginInventoryRow: View {
    let entry: ISHPluginHostInventoryEntry

    var body: some View {
        HStack(spacing: 12) {
            HarnessIconTile(
                systemImage: entry.activeRun == nil ? "shippingbox" : "shippingbox.fill",
                tint: entry.activeRun == nil ? .secondary : .green
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.pluginId)
                    .font(.body.monospaced())
                    .lineLimit(1)
                Text(entry.packages.map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let activeRun = entry.activeRun {
                    Text("Running · \(activeRun.packageId)")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if let currentPackageID = entry.currentPackageId {
                    Text("Defined · \(currentPackageID)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if entry.nextPackageId != nil {
                HarnessStatusPill(title: "Pending Switch", systemImage: "arrow.triangle.2.circlepath", tint: .orange)
                    .accessibilityLabel("A version is pending switch")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ISHPluginDetailView: View {
    @Environment(AppModel.self) private var model
    let pluginID: String
    @State private var isWorking = false

    var body: some View {
        Group {
            if let entry {
                Form {
                    Section {
                        LabeledContent("Plugin", value: entry.pluginId)
                        LabeledContent("Session Agent", value: entry.agentId)
                        HStack {
                            Text("Status")
                            Spacer(minLength: 8)
                            HarnessStatusPill(
                                title: entry.activeRun == nil ? "Stopped" : "Running",
                                systemImage: entry.activeRun == nil ? "pause.circle" : "bolt.fill",
                                tint: entry.activeRun == nil ? .secondary : .green
                            )
                        }
                        if let packageID = entry.currentPackageId {
                            LabeledContent("Current Version", value: packageID)
                        }
                        if let packageID = entry.nextPackageId,
                           packageID != entry.currentPackageId {
                            LabeledContent("Pending Version", value: packageID)
                        }
                        if let activeRun = entry.activeRun {
                            LabeledContent("Run ID", value: activeRun.pluginRunId)
                        }

                        if let plan = entry.preferredActivationPlan {
                            Button {
                                run(.activate(plan))
                            } label: {
                                Label(plan.title, systemImage: plan.iconName)
                            }
                            .disabled(isWorking)
                        }

                        if entry.activeRun != nil {
                            Button {
                                run(.stop)
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .disabled(isWorking)
                        }

                        NavigationLink {
                            PluginSettingsView()
                        } label: {
                            Label("Host Settings Namespace", systemImage: "slider.horizontal.3")
                        }
                    } header: { Label("Lifecycle", systemImage: "arrow.clockwise") }

                    Section {
                        ForEach(entry.packages, id: \.packageId) { package in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(package.name)
                                        .font(.headline)
                                    Spacer(minLength: 8)
                                    Text(package.packageId)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text(package.purpose)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 12) {
                                        packageCapabilityLabels(for: package)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        packageCapabilityLabels(for: package)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                if let plan = entry.activationPlan(for: package.packageId) {
                                    Button {
                                        run(.activate(plan))
                                    } label: {
                                        Label(plan.title, systemImage: plan.iconName)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isWorking || package.hasClientHalf)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    } header: { Label("Packages", systemImage: "shippingbox") }

                    if let latestRun = entry.latestRun {
                        Section {
                            Text(latestRun.displayText)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        } header: { Label("Last Run", systemImage: "clock.arrow.circlepath") }
                    }

                    Section {
                        Button("Uninstall Plugin", role: .destructive) {
                            run(.undefine)
                        }
                        .disabled(isWorking)
                    } footer: {
                        Text("Uninstalling removes all of this plugin's in-memory packages. Dynamic definitions also disappear after the iSH Host restarts.")
                    }
                }
            } else {
                ContentUnavailableView(
                    "Plugin Unavailable",
                    systemImage: "shippingbox",
                    description: Text("It may have been uninstalled, or the iSH Host has restarted.")
                )
            }
        }
        .navigationTitle(pluginID)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refreshPluginInventory()
        }
    }

    private var entry: ISHPluginHostInventoryEntry? {
        model.ishPluginHostInventory.first { $0.pluginId == pluginID }
    }

    private func run(_ action: Action) {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            switch action {
            case let .activate(plan):
                await model.runISHPlugin(
                    pluginID: pluginID,
                    packageID: plan.packageID,
                    mode: plan.mode
                )
            case .stop:
                await model.stopISHPlugin(pluginID: pluginID)
            case .undefine:
                await model.undefineISHPlugin(pluginID: pluginID)
            }
            isWorking = false
        }
    }

    private enum Action {
        case activate(ISHPluginHostActivationPlan)
        case stop
        case undefine
    }

    @ViewBuilder
    private func packageCapabilityLabels(
        for package: ISHPluginHostPackageSummary
    ) -> some View {
        Label(
            package.hasHostHalf ? "Host" : "No Host",
            systemImage: package.hasHostHalf ? "terminal.fill" : "terminal"
        )
        Label(
            package.hasClientHalf ? "Client" : "No Client",
            systemImage: package.hasClientHalf ? "rectangle.on.rectangle" : "iphone"
        )
    }
}

private struct PluginInventoryRow: View {
    let snapshot: CordisPluginSnapshot

    var body: some View {
        HStack(spacing: 12) {
            HarnessIconTile(systemImage: snapshot.state.iconName, tint: snapshot.state.tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.id.rawValue)
                    .font(.body.monospaced())
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(snapshot.state.title)
                    Text("v\(snapshot.version)")
                    if snapshot.generation > 0 {
                        Text("gen \(snapshot.generation)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !snapshot.isEnabled {
                HarnessStatusPill(title: "Disabled", systemImage: "pause.circle.fill", tint: .secondary)
            } else if !snapshot.missingDependencies.isEmpty {
                HarnessStatusPill(title: "Waiting for Dependencies", systemImage: "link.badge.plus", tint: .orange)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PluginDetailView: View {
    @Environment(AppModel.self) private var model
    let pluginID: CordisPluginID

    var body: some View {
        Group {
            if let snapshot {
                Form {
                    Section {
                        LabeledContent("Status", value: snapshot.state.title)
                        LabeledContent("Version", value: snapshot.version)
                        LabeledContent("Generation", value: "\(snapshot.generation)")
                        Toggle(
                            "Enable Plugin",
                            isOn: Binding(
                                get: { snapshot.isEnabled },
                                set: { enabled in
                                    Task {
                                        await model.setPluginEnabled(enabled, id: pluginID)
                                    }
                                }
                            )
                        )
                        Button {
                            Task { await model.restartPlugin(id: pluginID) }
                        } label: {
                            Label("Restart Fiber", systemImage: "arrow.clockwise")
                        }
                    } header: { Label("Lifecycle", systemImage: "arrow.clockwise") }

                    if !snapshot.dependencies.isEmpty {
                        StringListSection(title: "Dependencies", values: snapshot.dependencies)
                    }
                    if !snapshot.provides.isEmpty {
                        StringListSection(title: "Provides", values: snapshot.provides)
                    }
                    if !snapshot.missingDependencies.isEmpty {
                        StringListSection(
                            title: "Waiting to Reconnect",
                            values: snapshot.missingDependencies,
                            tint: .orange
                        )
                    }

                    let tools = model.pluginToolContributions.filter { $0.pluginID == pluginID }
                    if !tools.isEmpty {
                        Section {
                            ForEach(tools, id: \.definition.name) { contribution in
                                LabeledContent(
                                    contribution.definition.name,
                                    value: contribution.risk.rawValue
                                )
                            }
                        } header: { Label("Tools", systemImage: "wrench.and.screwdriver") }
                    }

                    let prompts = model.pluginPromptContributions.filter { $0.pluginID == pluginID }
                    if !prompts.isEmpty {
                        Section {
                            ForEach(prompts, id: \.stableID) { contribution in
                                LabeledContent(
                                    contribution.name,
                                    value: contribution.kind.rawValue
                                )
                            }
                        } header: { Label("Prompts", systemImage: "text.quote") }
                    }

                    if let error = snapshot.error {
                        Section {
                            Text(error)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        } header: { Label("Fault Isolation", systemImage: "exclamationmark.triangle") }
                    }

                    if pluginID.rawValue.hasPrefix("memory.") || pluginID.rawValue.hasPrefix("ish.") {
                        Section {
                            Button("Uninstall Plugin", role: .destructive) {
                                Task { await model.uninstallPlugin(id: pluginID) }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Plugin Uninstalled",
                    systemImage: "shippingbox",
                    description: Text("Return to the plugin list to view the current runtime inventory.")
                )
            }
        }
        .navigationTitle(pluginID.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refreshPluginInventory()
        }
    }

    private var snapshot: CordisPluginSnapshot? {
        model.pluginSnapshots.first { $0.id == pluginID }
    }
}

private struct StringListSection: View {
    let title: String
    let values: [String]
    var tint: Color = .secondary

    var body: some View {
        Section {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(.body.monospaced())
                    .foregroundStyle(tint)
            }
        } header: { Label(title, systemImage: "list.bullet.rectangle") }
    }
}

private struct ExperimentalPromptPluginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pluginName = ""
    @State private var instruction = ""
    @State private var isInstalling = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $pluginName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextEditor(text: $instruction)
                        .frame(minHeight: 160)
                } header: {
                    Label("In-Memory Plugin", systemImage: "text.badge.plus")
                } footer: {
                    Text("The plugin exists only in the current app process and disappears on restart. Once enabled, its prompt is added to the next request.")
                }
            }
            .navigationTitle("Experimental Plugin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Install") {
                        isInstalling = true
                        Task {
                            let installed = await model.installExperimentalPromptPlugin(
                                id: pluginName,
                                instruction: instruction
                            )
                            isInstalling = false
                            if installed { dismiss() }
                        }
                    }
                    .disabled(
                        isInstalling
                            || pluginName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
}

private struct ISHHostPluginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pluginName = ""
    @State private var purpose = ""
    @State private var hostCode = Self.defaultHostCode
    @State private var isInstalling = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $pluginName)
                        .accessibilityIdentifier("ish-plugin-name")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Purpose", text: $purpose, axis: .vertical)
                        .accessibilityIdentifier("ish-plugin-purpose")
                        .lineLimit(2...4)
                    TextEditor(text: $hostCode)
                        .accessibilityIdentifier("ish-plugin-host-code")
                        .font(.footnote.monospaced())
                        .frame(minHeight: 260)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Label("Host-half JavaScript", systemImage: "terminal")
                } footer: {
                    Text("Code is defined and run only in memory in the on-device iSH Cordis Host.")
                }
            }
            .navigationTitle("iSH Plugin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Define and Run") {
                        isInstalling = true
                        Task { @MainActor in
                            let installed = await model.defineAndRunISHPlugin(
                                name: pluginName,
                                purpose: purpose,
                                hostCode: hostCode
                            )
                            isInstalling = false
                            if installed { dismiss() }
                        }
                    }
                    .disabled(
                        isInstalling
                            || pluginName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || hostCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .interactiveDismissDisabled(isInstalling)
        }
        .presentationDetents([.medium, .large])
    }

    private static let defaultHostCode = """
    return {
      name: 'mobile-echo',
      inject: ['tools'],
      apply(ctx) {
        harness.registerTool(ctx, harness.defineTool({
          name: 'mobile_echo',
          description: 'Return the supplied text.',
          parameters: { text: { type: 'string', required: true } },
          output: {
            schema: { type: 'string' },
            render(_args, value) { return [{ type: 'text', text: value }] },
          },
          async execute(args) { return String(args.text ?? '') },
        }))
      },
    }
    """
}

private extension ISHPluginHostActivationPlan {
    var title: String {
        switch mode {
        case .run: "Run"
        case .update: "Update"
        }
    }

    var iconName: String {
        switch mode {
        case .run: "play.fill"
        case .update: "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch mode {
        case .run: .green
        case .update: .blue
        }
    }
}

private extension CordisPluginState {
    var title: String {
        switch self {
        case .pending: "Pending"
        case .loading: "Loading"
        case .active: "Running"
        case .failed: "Failed"
        case .unloading: "Unloading"
        case .disposed: "Disposed"
        }
    }

    var iconName: String {
        switch self {
        case .pending: "clock"
        case .loading, .unloading: "arrow.trianglehead.2.clockwise.rotate.90"
        case .active: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .disposed: "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .active: .green
        case .failed: .red
        case .pending: .orange
        case .loading, .unloading: .blue
        case .disposed: .secondary
        }
    }
}

private extension ISHPluginHostRuntimeState {
    var title: String {
        switch self {
        case .stopped: "Not Started"
        case .installing: "Installing Dependencies"
        case .starting: "Starting"
        case .running: "Running"
        case .failed: "Fault Isolation"
        }
    }

    var iconName: String {
        switch self {
        case .stopped: "pause.circle"
        case .installing, .starting: "arrow.triangle.2.circlepath"
        case .running: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .stopped: .secondary
        case .installing, .starting: .orange
        case .running: .green
        case .failed: .red
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var processID: Int32? {
        guard case let .running(_, processID) = self else { return nil }
        return processID
    }
}

private extension CordisPromptContributionSnapshot {
    var stableID: String {
        "\(kind.rawValue):\(name)"
    }
}
