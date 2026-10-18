import SwiftUI

struct PluginSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var isRefreshing = false

    var body: some View {
        Group {
            if model.ishPluginSettingsSnapshot?.namespaces.isEmpty == false {
                settingsList
                    .searchable(text: $query, prompt: "Search Namespaces")
            } else {
                settingsList
            }
        }
        .navigationTitle("Plugin Settings")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh Plugin Settings")
                .accessibilityIdentifier("ish-plugin-settings-refresh")
                .help("Refresh Plugin Settings")
            }
        }
        .task {
            if !isUITestingFixtureRequested {
                await refresh()
            }
        }
        .refreshable {
            await refresh()
        }
    }

    private var settingsList: some View {
        List {
            if let snapshot = model.ishPluginSettingsSnapshot {
                Section {
                    LabeledContent("Namespaces", value: "\(snapshot.namespaces.count)")
                    HStack {
                        Text("Writes")
                        Spacer()
                        HarnessStatusPill(
                            title: snapshot.writable ? "Available" : "Read-Only",
                            systemImage: snapshot.writable ? "pencil" : "lock.fill",
                            tint: snapshot.writable ? .green : .secondary
                        )
                    }
                    HStack {
                        Text("Config File")
                        Spacer()
                        HarnessStatusPill(
                            title: snapshot.hasDocument ? "Mounted" : "Not Mounted",
                            systemImage: snapshot.hasDocument ? "checkmark" : "minus",
                            tint: snapshot.hasDocument ? .green : .secondary
                        )
                    }
                } header: {
                    Label("Settings Provider", systemImage: "slider.horizontal.3")
                }

                if filteredNamespaces.isEmpty {
                    Section {
                        Label(
                            query.isEmpty ? "No Plugin Settings" : "No Matching Settings",
                            systemImage: "slider.horizontal.3"
                        )
                        .foregroundStyle(.secondary)
                        Text(
                            query.isEmpty
                                ? "Host plugins that register a settings namespace appear here once enabled."
                                : "Try searching for a different namespace."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } header: {
                        Label("Namespaces", systemImage: "square.stack.3d.up")
                    }
                } else {
                    Section {
                        ForEach(filteredNamespaces) { namespace in
                            NavigationLink {
                                PluginSettingsNamespaceView(namespaceID: namespace.ns)
                            } label: {
                                PluginSettingsNamespaceRow(namespace: namespace)
                            }
                        }
                    } header: {
                        Label("Namespaces", systemImage: "square.stack.3d.up")
                    }
                }
            } else {
                Section {
                    VStack(spacing: HarnessTheme.Spacing.medium) {
                        ContentUnavailableView(
                            isRefreshing ? "Starting Settings Host" : "Settings Host Not Ready",
                            systemImage: "terminal",
                            description: Text("Start the on-device iSH Cordis Host to read plugin settings.")
                        )

                        if isRefreshing {
                            ProgressView()
                                .controlSize(.large)
                                .accessibilityLabel("Starting Settings Host")
                                .accessibilityIdentifier("ish-plugin-settings-loading")
                        } else {
                            Button("Start Host", systemImage: "play.fill") {
                                Task { await refresh() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HarnessTheme.Spacing.large)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .accessibilityIdentifier("ish-plugin-settings-list")
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(HarnessTheme.pageBackground)
    }

    private var filteredNamespaces: [ISHPluginSettingsNamespace] {
        let namespaces = (model.ishPluginSettingsSnapshot?.namespaces ?? [])
            .sorted { $0.ns.localizedStandardCompare($1.ns) == .orderedAscending }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return namespaces }
        return namespaces.filter { namespace in
            namespace.ns.lowercased().contains(normalized)
                || namespace.applies.displayName.lowercased().contains(normalized)
                || (namespace.unsupportedReason ?? "").lowercased().contains(normalized)
        }
    }

    private var hostIsRunning: Bool {
        if case .running = model.ishPluginHostState { return true }
        return false
    }

    private var isUITestingFixtureRequested: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-present-plugin-settings-for-ui-testing")
#else
        false
#endif
    }

    @MainActor
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if hostIsRunning {
            _ = await model.refreshISHPluginSettings()
        } else {
            _ = await model.startISHPluginHost()
        }
    }
}

private struct PluginSettingsNamespaceRow: View {
    let namespace: ISHPluginSettingsNamespace

    var body: some View {
        HStack(spacing: 12) {
            HarnessIconTile(
                systemImage: namespace.editable ? "slider.horizontal.3" : "lock.fill",
                tint: namespace.editable ? .accentColor : .secondary
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(namespace.ns)
                    .font(.body.monospaced())
                    .lineLimit(1)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        metadata
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        metadata
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if namespace.user?.objectValue?.isEmpty == false {
                HarnessStatusPill(title: "Overridden", systemImage: "checkmark", tint: .accentColor)
            }
        }
        .padding(.vertical, HarnessTheme.Spacing.xSmall)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ish-plugin-settings-namespace-\(namespace.ns)")
    }

    @ViewBuilder
    private var metadata: some View {
        Label(namespace.applies.displayName, systemImage: namespace.applies.systemImage)
        Text("Revision \(namespace.revision)")
            .monospacedDigit()
        if !namespace.secrets.isEmpty {
            Label("\(namespace.secrets.count)", systemImage: "key.fill")
        }
    }
}

struct PluginSettingsNamespaceView: View {
    @Environment(AppModel.self) private var model

    let namespaceID: String

    @State private var form: ISHPluginSettingsForm?
    @State private var draft: ISHPluginSettingsDraft?
    @State private var notice: EditorNotice?
    @State private var hasConflict = false
    @State private var isSaving = false

    var body: some View {
        Group {
            if let namespace {
                Form {
                    namespaceStatusSection(namespace)

                    if hasConflict {
                        conflictSection(namespace)
                    }

                    if let notice {
                        Section {
                            HStack(alignment: .top, spacing: 10) {
                                HarnessIconTile(systemImage: notice.systemImage, tint: notice.tint, size: 28)
                                Text(notice.message)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if namespace.editable, providerIsWritable {
                        if let form, let draftBinding = Binding($draft) {
                            PluginSettingsFormSections(
                                form: form,
                                draft: draftBinding,
                                isDisabled: isSaving
                            )
                        } else {
                            Section {
                                HStack(spacing: 10) {
                                    HarnessIconTile(systemImage: "arrow.triangle.2.circlepath", tint: .accentColor, size: 28)
                                    Text("Load Schema")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        readOnlySection(namespace)
                    }

                    if !namespace.secrets.isEmpty {
                        PluginSettingsSecretsSection(secrets: namespace.secrets)
                    }
                }
                .accessibilityIdentifier("ish-plugin-settings-editor")
                .listStyle(.insetGrouped)
                .environment(\.defaultMinListRowHeight, 44)
                .scrollContentBackground(.hidden)
                .background(HarnessTheme.pageBackground)
            } else {
                ContentUnavailableView(
                    "Settings Released",
                    systemImage: "slider.horizontal.3",
                    description: Text("The plugin may have been disabled, uninstalled, or restarted.")
                )
            }
        }
        .navigationTitle(namespaceID)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if namespace?.editable == true, providerIsWritable, draft != nil {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        discardDraft()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(isSaving || draft?.isDirty != true)
                    .accessibilityLabel("Discard Settings Draft")
                    .accessibilityIdentifier("ish-plugin-settings-discard")
                    .help("Discard Settings Draft")

                    Button {
                        saveDraft()
                    } label: {
                        Image(systemName: "checkmark")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(!canSave)
                    .accessibilityLabel("Save Plugin Settings")
                    .accessibilityIdentifier("ish-plugin-settings-save")
                    .help("Save Plugin Settings")
                }
            }
        }
        .task {
            if namespace == nil {
                _ = await model.refreshISHPluginSettings()
            }
            seedFromCurrentNamespace(force: false)
        }
        .onChange(of: namespace?.revision) {
            synchronizeExternalRevision()
        }
    }

    private var namespace: ISHPluginSettingsNamespace? {
        model.ishPluginSettingsSnapshot?.namespaces.first { $0.ns == namespaceID }
    }

    private var providerIsWritable: Bool {
        model.ishPluginSettingsSnapshot?.writable == true
    }

    private var canSave: Bool {
        guard !isSaving,
              !hasConflict,
              let form,
              let draft,
              draft.isDirty,
              draft.operations.count <= 256 else { return false }
        return draft.validationIssues(in: form).isEmpty
    }

    @ViewBuilder
    private func namespaceStatusSection(_ namespace: ISHPluginSettingsNamespace) -> some View {
        Section {
            LabeledContent("Revision", value: "\(namespace.revision)")
            LabeledContent("Applies", value: namespace.applies.displayName)
            LabeledContent("Editing", value: namespace.editable && providerIsWritable ? "Available" : "Read-Only")
            if let draft {
                LabeledContent("Draft Overrides", value: "\(draft.overriddenFieldCount)")
            }
        } header: {
            Label("Status", systemImage: "waveform.path.ecg")
        }
    }

    @ViewBuilder
    private func conflictSection(_ namespace: ISHPluginSettingsNamespace) -> some View {
        Section {
            Label("Settings were updated elsewhere to revision \(namespace.revision)", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Button {
                rebaseDraft()
            } label: {
                Label("Replay Draft on New Revision", systemImage: "arrow.triangle.branch")
            }
            Button(role: .destructive) {
                discardDraft()
            } label: {
                Label("Discard Draft and Reload", systemImage: "trash")
            }
        } header: {
            Label("Revision Conflict", systemImage: "exclamationmark.arrow.circlepath")
        }
    }

    @ViewBuilder
    private func readOnlySection(_ namespace: ISHPluginSettingsNamespace) -> some View {
        Section {
            Label(
                namespace.unsupportedReason ?? "This namespace can't currently be written from the native form.",
                systemImage: "lock.fill"
            )
                .foregroundStyle(.secondary)
            if namespace.value != .null {
                Text(namespace.value.displayText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            Label("Read-Only Configuration", systemImage: "lock.fill")
        }
    }

    @MainActor
    private func seedFromCurrentNamespace(force: Bool) {
        guard let namespace else { return }
        if !force, draft != nil { return }
        do {
            let parsed = try ISHPluginSettingsForm(namespace: namespace)
            form = parsed
            draft = try ISHPluginSettingsDraft(namespace: namespace, form: parsed)
            hasConflict = false
            notice = nil
        } catch {
            form = nil
            draft = nil
            notice = .error(error.localizedDescription)
        }
    }

    @MainActor
    private func synchronizeExternalRevision() {
        guard let namespace else { return }
        guard let draft else {
            seedFromCurrentNamespace(force: true)
            return
        }
        guard namespace.revision != draft.expectedRevision else { return }
        if draft.isDirty {
            hasConflict = true
            notice = .warning("Your draft is kept. Resolve the revision conflict before saving.")
        } else {
            seedFromCurrentNamespace(force: true)
        }
    }

    @MainActor
    private func discardDraft() {
        seedFromCurrentNamespace(force: true)
    }

    @MainActor
    private func rebaseDraft() {
        guard let namespace, let draft else { return }
        do {
            let parsed = try ISHPluginSettingsForm(namespace: namespace)
            self.form = parsed
            self.draft = try draft.rebased(onto: namespace, form: parsed)
            hasConflict = false
            notice = .success("Draft replayed onto revision \(namespace.revision).")
        } catch {
            notice = .error(error.localizedDescription)
        }
    }

    private func saveDraft() {
        guard canSave, let draft else { return }
        let operations = draft.operations
        isSaving = true
        notice = nil

        Task { @MainActor in
            defer { isSaving = false }
            do {
                let updated = try await model.mutateISHPluginSettings(
                    namespace: draft.namespace,
                    operations: operations,
                    expectedRevision: draft.expectedRevision
                )
                let updatedForm = try ISHPluginSettingsForm(namespace: updated)
                self.form = updatedForm
                self.draft = try ISHPluginSettingsDraft(namespace: updated, form: updatedForm)
                hasConflict = false
                notice = .success(
                    updated.applies == .live
                        ? "Settings applied."
                        : "Settings saved. They take effect after the plugin restarts."
                )
            } catch let error as ISHPluginHostError {
                if error.settingsConflict != nil {
                    hasConflict = true
                    notice = .warning("Save was rejected by the revision check. Your draft was not lost.")
                } else {
                    notice = .error(error.localizedDescription)
                }
            } catch {
                notice = .error(error.localizedDescription)
            }

        }
    }
}

struct NativeAgentPluginSettingsView: View {
    @Environment(AppModel.self) private var model

    let pluginID: String

    @State private var form: ISHPluginSettingsForm?
    @State private var draft: ISHPluginSettingsDraft?
    @State private var notice: EditorNotice?
    @State private var isSaving = false

    var body: some View {
        Group {
            if let plugin, plugin.settings != nil {
                Form {
                    Section {
                        LabeledContent("Applies", value: "Replaces runtime contributions immediately")
                        LabeledContent("Storage", value: "App-local plugin registry")
                    } header: {
                        Label("Runtime", systemImage: "power")
                    }

                    if let notice {
                        Section {
                            HStack(alignment: .top, spacing: 10) {
                                HarnessIconTile(systemImage: notice.systemImage, tint: notice.tint, size: 28)
                                Text(notice.message)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if let form, let draftBinding = Binding($draft) {
                        PluginSettingsFormSections(
                            form: form,
                            draft: draftBinding,
                            isDisabled: isSaving
                        )
                    } else {
                        Section {
                            HStack(spacing: 10) {
                                HarnessIconTile(systemImage: "arrow.triangle.2.circlepath", tint: .accentColor, size: 28)
                                Text("Load Native Settings Schema")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let defaults = plugin.settings?.defaults {
                        Section {
                            Button {
                                save(values: defaults, successMessage: "Plugin defaults restored.")
                            } label: {
                                Label("Restore All Defaults", systemImage: "arrow.counterclockwise")
                            }
                            .disabled(isSaving || plugin.settings?.values == defaults)
                        } header: {
                            Label("Defaults", systemImage: "arrow.counterclockwise")
                        }
                    }
                }
                .accessibilityIdentifier("native-agent-settings-editor")
                .listStyle(.insetGrouped)
                .environment(\.defaultMinListRowHeight, 44)
                .scrollContentBackground(.hidden)
                .background(HarnessTheme.pageBackground)
            } else {
                ContentUnavailableView(
                    "No Editable Settings",
                    systemImage: "slider.horizontal.3",
                    description: Text("The plugin may have been uninstalled, or its source doesn't declare a migratable settings schema.")
                )
            }
        }
        .navigationTitle(plugin?.name ?? "Native Plugin Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if draft != nil {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        seed(force: true)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(isSaving || draft?.isDirty != true)
                    .accessibilityLabel("Discard Settings Draft")
                    .help("Discard Settings Draft")

                    Button {
                        saveDraft()
                    } label: {
                        Image(systemName: "checkmark")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(!canSave)
                    .accessibilityLabel("Save Native Plugin Settings")
                    .help("Save Native Plugin Settings")
                }
            }
        }
        .task {
            seed(force: false)
        }
    }

    private var plugin: NativeAgentCompiledPlugin? {
        model.nativeAgentPlugins.first { $0.id == pluginID }
    }

    private var namespace: ISHPluginSettingsNamespace? {
        guard let settings = plugin?.settings else { return nil }
        return ISHPluginSettingsNamespace(
            ns: pluginID,
            schema: settings.schema,
            value: settings.values,
            base: settings.defaults,
            user: settings.values,
            revision: 1,
            applies: .live,
            secrets: [],
            editable: true,
            unsupportedReason: nil
        )
    }

    private var canSave: Bool {
        guard !isSaving,
              let form,
              let draft,
              draft.isDirty,
              draft.operations.count <= 256 else { return false }
        return draft.validationIssues(in: form).isEmpty
    }

    @MainActor
    private func seed(force: Bool) {
        guard let namespace else { return }
        if !force, draft != nil { return }
        do {
            let parsed = try ISHPluginSettingsForm(namespace: namespace)
            form = parsed
            draft = try ISHPluginSettingsDraft(namespace: namespace, form: parsed)
            notice = nil
        } catch {
            form = nil
            draft = nil
            notice = .error(error.localizedDescription)
        }
    }

    private func saveDraft() {
        guard canSave,
              let settings = plugin?.settings,
              let draft else { return }
        let values = ISHPluginSettingsValue.merging(
            base: settings.defaults,
            overrides: draft.user
        )
        save(values: values, successMessage: "Native plugin settings applied.")
    }

    private func save(values: JSONValue, successMessage: String) {
        guard !isSaving else { return }
        isSaving = true
        notice = nil
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await model.updateNativeAgentPluginSettings(id: pluginID, values: values)
                seed(force: true)
                notice = .success(successMessage)
            } catch {
                notice = .error(error.localizedDescription)
            }
        }
    }
}

private struct PluginSettingsFormSections: View {
    let form: ISHPluginSettingsForm
    @Binding var draft: ISHPluginSettingsDraft
    let isDisabled: Bool

    var body: some View {
        if !form.rootFields.isEmpty {
            Section {
                ForEach(form.rootFields) { leaf in
                    PluginSettingsFieldEditor(
                        leaf: leaf,
                        draft: $draft,
                        isDisabled: isDisabled
                    )
                }
            } header: {
                Label("Configuration", systemImage: "slider.horizontal.3")
            }
        }

        ForEach(form.groups) { group in
            Section {
                ForEach(group.fields) { leaf in
                    PluginSettingsFieldEditor(
                        leaf: leaf,
                        draft: $draft,
                        isDisabled: isDisabled
                    )
                }
            } header: {
                Label(group.name, systemImage: "square.stack.3d.up")
            } footer: {
                if let help = group.description ?? group.comment {
                    Text(help)
                }
            }
        }

        let issues = draft.validationIssues(in: form)
        if !issues.isEmpty || draft.operations.count > 256 {
            Section {
                ForEach(issues, id: \.self) { issue in
                    HStack(alignment: .top, spacing: 10) {
                        HarnessIconTile(systemImage: "exclamationmark.triangle.fill", tint: .red, size: 28)
                        Text(issue)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if draft.operations.count > 256 {
                    HStack(alignment: .top, spacing: 10) {
                        HarnessIconTile(systemImage: "exclamationmark.triangle.fill", tint: .red, size: 28)
                        Text("Up to 256 fields can be written at once.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Validation", systemImage: "checkmark.shield")
            }
        }
    }
}

private struct PluginSettingsFieldEditor: View {
    let leaf: ISHPluginSettingsLeaf
    @Binding var draft: ISHPluginSettingsDraft
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(leaf.label)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if draft.isOverridden(at: leaf.field.path) {
                    HarnessStatusPill(title: "Override", systemImage: "checkmark", tint: .accentColor)
                    Button {
                        var updated = draft
                        updated.reset(leaf.field.path)
                        draft = updated
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled || leaf.disabled)
                    .accessibilityLabel("Reset \(leaf.label)")
                    .help("Reset to inherited value")
                } else {
                    HarnessStatusPill(title: "Inherited", systemImage: "arrow.down.left", tint: .secondary)
                }
            }

            fieldControl
                .disabled(isDisabled || leaf.disabled)

            if let help = leaf.field.description ?? leaf.field.comment {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("ish-plugin-setting-\(leaf.field.path.joined(separator: "."))")
    }

    @ViewBuilder
    private var fieldControl: some View {
        switch leaf.field.kind {
        case .boolean:
            Toggle("Value", isOn: booleanBinding)
                .labelsHidden()
                .accessibilityLabel(leaf.label)
        case let .number(minimum, maximum, step):
            numberControl(minimum: minimum, maximum: maximum, step: step)
        case .string:
            TextField("Value", text: stringBinding, axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case let .selection(options):
            if options.count <= 3 {
                Picker("Value", selection: selectionBinding(options)) {
                    ForEach(options) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .pickerStyle(.segmented)
            } else {
                Picker("Value", selection: selectionBinding(options)) {
                    ForEach(options) { option in
                        Text(option.label).tag(option.id)
                    }
                }
            }
        case .object:
            EmptyView()
        }
    }

    @ViewBuilder
    private func numberControl(
        minimum: Double?,
        maximum: Double?,
        step: Double?
    ) -> some View {
        let effectiveStep = step.flatMap { $0 > 0 ? $0 : nil } ?? 1
        if let minimum, let maximum, minimum <= maximum {
            Stepper(value: numberBinding, in: minimum...maximum, step: effectiveStep) {
                numberTextField
            }
        } else {
            Stepper(value: numberBinding, step: effectiveStep) {
                numberTextField
            }
        }
    }

    private var numberTextField: some View {
        TextField(
            "Value",
            value: numberBinding,
            format: .number.precision(.fractionLength(0...6))
        )
        .keyboardType(.numbersAndPunctuation)
        .multilineTextAlignment(.trailing)
    }

    private var booleanBinding: Binding<Bool> {
        Binding(
            get: {
                guard case let .bool(value)? = draft.effectiveValue(for: leaf.field) else {
                    return false
                }
                return value
            },
            set: { update(.bool($0)) }
        )
    }

    private var numberBinding: Binding<Double> {
        Binding(
            get: {
                guard case let .number(value)? = draft.effectiveValue(for: leaf.field) else {
                    return 0
                }
                return value
            },
            set: { update(.number($0)) }
        )
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: {
                guard case let .string(value)? = draft.effectiveValue(for: leaf.field) else {
                    return ""
                }
                return value
            },
            set: { update(.string($0)) }
        )
    }

    private func selectionBinding(_ options: [ISHPluginSettingsOption]) -> Binding<String> {
        Binding(
            get: {
                let value = draft.effectiveValue(for: leaf.field)
                return options.first(where: { $0.value == value })?.id ?? options.first?.id ?? ""
            },
            set: { selectedID in
                guard let value = options.first(where: { $0.id == selectedID })?.value else { return }
                update(value)
            }
        )
    }

    private func update(_ value: JSONValue) {
        var updated = draft
        updated.set(value, at: leaf.field.path)
        draft = updated
    }
}

private struct PluginSettingsSecretsSection: View {
    let secrets: [ISHPluginSettingsSecret]

    var body: some View {
        Section {
            ForEach(secrets, id: \.self) { secret in
                LabeledContent(secret.path.joined(separator: " / ")) {
                    Label(
                        secret.set ? "Configured" : "Not Configured",
                        systemImage: secret.set ? "checkmark.shield.fill" : "shield"
                    )
                    .foregroundStyle(secret.set ? Color.green : Color.secondary)
                }
            }
        } header: {
            Label("Protected Fields", systemImage: "key.fill")
        }
    }
}

private struct EditorNotice: Equatable {
    enum Kind: Equatable {
        case success
        case warning
        case error
    }

    let kind: Kind
    let message: String

    static func success(_ message: String) -> Self { Self(kind: .success, message: message) }
    static func warning(_ message: String) -> Self { Self(kind: .warning, message: message) }
    static func error(_ message: String) -> Self { Self(kind: .error, message: message) }

    var systemImage: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

private extension ISHPluginSettingsApplies {
    var displayName: String {
        switch self {
        case .live: "Live"
        case .restart: "After Restart"
        }
    }

    var systemImage: String {
        switch self {
        case .live: "bolt.fill"
        case .restart: "arrow.clockwise"
        }
    }
}
