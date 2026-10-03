import SwiftUI

/// Selects a saved Provider Profile and model for the current conversation.
/// Credentials remain write-only and are resolved by AppModel from Keychain.
struct SessionModelPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft = AgentConfiguration()
    @State private var selectedProfileID = ""
    @State private var catalog = SessionModelCatalog.builtIn(for: AgentConfiguration())
    @State private var searchText = ""
    @State private var isFollowingGlobal = true
    @State private var isDiscoveringModels = false
    @State private var isSaving = false
    @State private var modelDiscoveryError: String?
    @State private var saveError: String?
    @State private var didLoad = false

    private var selectedProfile: ProviderProfile? {
        model.providerDirectory.profile(id: selectedProfileID)
    }

    private var provider: ModelProviderDescriptor {
        selectedProfile?.descriptor
            ?? ModelProviderCatalog.descriptor(for: draft.providerID)
    }

    private var visibleCatalog: SessionModelCatalog {
        guard catalog.identity == SessionModelCatalogIdentity(configuration: draft) else {
            if let selectedProfile {
                return .stored(for: selectedProfile, configuration: draft)
            }
            return .builtIn(for: draft)
        }
        return catalog
    }

    private var filteredModels: [ProviderModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visibleCatalog.models }
        return visibleCatalog.models.filter { candidate in
            candidate.id.localizedCaseInsensitiveContains(query)
                || candidate.name?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var canRefreshModels: Bool {
        guard let selectedProfile else { return false }
        return selectedProfile.descriptor.supportsRemoteModelDiscovery
            && model.credentialStatus(for: selectedProfile) == .configured
            && !isDiscoveringModels
            && (try? draft.modelsURL()) != nil
    }

    private var selectedModelIsInCatalog: Bool {
        visibleCatalog.models.contains { $0.id == draft.model }
    }

    private var selectedProfileIsUsable: Bool {
        guard let selectedProfile else { return false }
        return selectedProfile.descriptor.supportsCurrentInferenceWire
            && model.credentialStatus(for: selectedProfile) == .configured
    }

    private var saveIsDisabled: Bool {
        isSaving
            || isDiscoveringModels
            || model.isRunning
            || (!isFollowingGlobal && (
                !selectedProfileIsUsable
                    || draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ))
    }

    var body: some View {
        NavigationStack {
            List {
                scopeSection
                if !isFollowingGlobal {
                    providerSection
                }
                modelSection
                if !isFollowingGlobal {
                    inferenceSection
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 44)
            .scrollContentBackground(.hidden)
            .background(HarnessTheme.pageBackground)
            .navigationTitle("Session Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search model ID or name"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Done")
                        }
                    }
                    .disabled(saveIsDisabled)
                    .accessibilityIdentifier("session-model-save")
                }
            }
            .task {
                await loadIfNeeded()
            }
            .onChange(of: model.providerDirectory) { _, _ in
                reconcileSelectedProfile()
            }
            .alert("Couldn't Save Session Model", isPresented: saveErrorPresented) {
                Button("OK") {
                    saveError = nil
                }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private var scopeSection: some View {
        Section {
            Toggle("Follow Default Model Settings", isOn: followingGlobalBinding)
                .accessibilityIdentifier("session-model-follow-global")

            if !isFollowingGlobal {
                Label("This choice only overrides the current session and doesn't change the default provider configuration.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Scope")
        } footer: {
            Text("Changes take effect on the next model request; in-flight requests won't switch providers midway.")
        }
    }

    private var providerSection: some View {
        Section {
            if model.providerProfiles.isEmpty {
                ContentUnavailableView(
                    "No Provider Profiles",
                    systemImage: "server.rack",
                    description: Text("Add a connection in Models & Providers first.")
                )
                .listRowBackground(Color.clear)
            } else {
                Picker("Provider Profile", selection: profileSelection) {
                    ForEach(model.providerProfiles) { profile in
                        Text(profile.displayName)
                            .tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isDiscoveringModels || isSaving || model.isRunning)
                .accessibilityIdentifier("session-model-provider-picker")
            }

            if let selectedProfile {
                HStack(spacing: HarnessTheme.Spacing.medium) {
                    HarnessIconTile(systemImage: "server.rack", tint: .blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedProfile.displayName)
                            .font(.body.weight(.medium))
                        Text("\(selectedProfile.id) · \(endpointHost(selectedProfile.baseURL))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                }
                .harnessCardListRow()
                SessionProviderStatusView(
                    credentialStatus: model.credentialStatus(for: selectedProfile),
                    supportsInference: selectedProfile.descriptor.supportsCurrentInferenceWire
                )

                Text(selectedProfile.descriptor.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let compatibilityNotice = selectedProfile.descriptor.compatibilityNotice {
                    Label(
                        compatibilityNotice,
                        systemImage: selectedProfile.descriptor.supportsCurrentInferenceWire
                            ? "info.circle"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(
                        selectedProfile.descriptor.supportsCurrentInferenceWire
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(.orange)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            NavigationLink {
                ProviderProfilesView()
            } label: {
                Label("Manage Models & Providers", systemImage: "slider.horizontal.3")
            }
        } header: {
            Text("Provider")
        } footer: {
            Text("Only saved provider profiles can be selected here; API keys are never shown and can't be edited from the session page.")
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        Section {
            TextField("Manual Model ID", text: modelIDBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(isSaving || model.isRunning || selectedProfile == nil)
                .accessibilityIdentifier("session-model-field")

            if isDiscoveringModels {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching model catalog…")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if filteredModels.isEmpty {
                ContentUnavailableView {
                    Label(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "No Models Available"
                            : "No Matching Models",
                        systemImage: "tray"
                    )
                } description: {
                    Text(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "You can enter a model ID manually above."
                            : "Change your search, or enter a model ID directly."
                    )
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredModels) { candidate in
                    Button {
                        if isFollowingGlobal, candidate.id != draft.model {
                            isFollowingGlobal = false
                        }
                        draft.model = candidate.id
                        draft.inputModalities = candidate.inputModalities
                    } label: {
                        SessionModelRow(
                            model: candidate,
                            isSelected: candidate.id == draft.model
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving || model.isRunning)
                    .accessibilityIdentifier("session-model-option-\(candidate.id)")
                }
            }

            if !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !selectedModelIsInCatalog {
                Label("Use Manual Model ID: \(draft.model)", systemImage: "keyboard")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Label(catalogSourceTitle, systemImage: catalogSourceIcon)
                Spacer()
                if let fetchedAt = visibleCatalog.fetchedAt {
                    Text(fetchedAt, format: .dateTime.month().day().hour().minute())
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)

            if let modelDiscoveryError {
                Label(modelDiscoveryError, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Refresh Model Catalog", systemImage: "arrow.clockwise") {
                Task {
                    await discoverModels(forceRefresh: true)
                }
            }
            .disabled(!canRefreshModels || isSaving || model.isRunning)
            .accessibilityIdentifier("session-model-refresh")
        } header: {
            Text("Model")
        } footer: {
            Text("Refreshing only uses the same-origin API key saved in the Keychain for this provider profile. Models outside the catalog can be entered by ID.")
        }
    }

    private var modelIDBinding: Binding<String> {
        Binding(
            get: { draft.model },
            set: { value in
                draft.model = value
                draft.inputModalities = visibleCatalog.models.first(
                    where: { $0.id == value }
                )?.inputModalities
            }
        )
    }

    private var inferenceSection: some View {
        Section {
            Picker("Reasoning Mode", selection: $draft.reasoningMode) {
                ForEach(draft.supportedReasoningModes
                    ?? ReasoningMode.supportedModes(for: draft.providerID)) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        } header: {
            Text("Reasoning")
        } footer: {
            Text("Available modes are filtered by the current provider protocol; Anthropic extended thinking isn't yet used for sessions that need tool follow-up turns.")
        }
    }

    private var followingGlobalBinding: Binding<Bool> {
        Binding(
            get: { isFollowingGlobal },
            set: { followsGlobal in
                isFollowingGlobal = followsGlobal
                saveError = nil
                modelDiscoveryError = nil
                if followsGlobal {
                    let configuration = model.configuration
                    draft = configuration
                    selectedProfileID = model.activeProviderProfile?.id ?? ""
                    if let profile = model.activeProviderProfile {
                        catalog = .stored(for: profile, configuration: configuration)
                    } else {
                        catalog = .builtIn(for: configuration)
                    }
                } else if let profile = model.activeProviderProfile {
                    selectProfile(profile.id)
                }
            }
        )
    }

    private var profileSelection: Binding<String> {
        Binding(
            get: { selectedProfileID },
            set: { selectProfile($0) }
        )
    }

    private var saveErrorPresented: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { presented in
                if !presented {
                    saveError = nil
                }
            }
        )
    }

    private var catalogSourceTitle: String {
        switch visibleCatalog.source {
        case .builtIn:
            return "Profile Catalog · \(visibleCatalog.models.count)"
        case .remote:
            return "Provider Catalog · \(visibleCatalog.models.count)"
        case .cache:
            return "Local Cache · \(visibleCatalog.models.count)"
        }
    }

    private var catalogSourceIcon: String {
        switch visibleCatalog.source {
        case .builtIn:
            return "shippingbox"
        case .remote:
            return "network"
        case .cache:
            return "internaldrive"
        }
    }

    private func loadIfNeeded() async {
        guard !didLoad else { return }
        let configuration = model.effectiveConfiguration
        let profile = model.providerDirectory.profile(matching: configuration)
            ?? model.activeProviderProfile
        draft = configuration
        selectedProfileID = profile?.id ?? ""
        isFollowingGlobal = model.controlState.modelConfiguration == nil
        if let profile {
            catalog = .stored(for: profile, configuration: configuration)
        } else {
            catalog = .builtIn(for: configuration)
        }
        didLoad = true

        guard !isFollowingGlobal, canRefreshModels else { return }
        await discoverModels(forceRefresh: false)
    }

    private func selectProfile(_ profileID: String) {
        guard let profile = model.providerDirectory.profile(id: profileID) else { return }
        selectedProfileID = profile.id
        draft = profile.configuration()
        catalog = .stored(for: profile)
        modelDiscoveryError = nil
        saveError = nil
    }

    private func reconcileSelectedProfile() {
        guard didLoad else { return }
        guard let profile = model.providerDirectory.profile(id: selectedProfileID) else {
            if let activeProfile = model.activeProviderProfile {
                selectProfile(activeProfile.id)
            } else {
                selectedProfileID = ""
            }
            return
        }

        let selectedModel = draft.model
        let reasoningMode = draft.reasoningMode
        draft = profile.configuration(model: selectedModel, reasoningMode: reasoningMode)
        catalog = .stored(for: profile, configuration: draft)
        modelDiscoveryError = nil
    }

    private func discoverModels(forceRefresh: Bool) async {
        guard !isFollowingGlobal, canRefreshModels else { return }
        let requestConfiguration = draft
        let requestIdentity = SessionModelCatalogIdentity(configuration: requestConfiguration)
        isDiscoveringModels = true
        modelDiscoveryError = nil
        defer {
            isDiscoveringModels = false
        }

        do {
            let snapshot = try await model.discoverModels(
                for: requestConfiguration,
                forceRefresh: forceRefresh
            )
            guard requestIdentity == SessionModelCatalogIdentity(configuration: draft) else {
                return
            }
            let refreshedCatalog = SessionModelCatalog.merging(
                snapshot,
                existing: visibleCatalog.models,
                for: requestConfiguration
            )
            catalog = refreshedCatalog
            // Keep the request configuration in sync with the refreshed
            // capability metadata. Without this, an already-selected vision
            // model can remain explicitly cached as `.text` and fail the
            // runtime image-input guard even though the catalog is correct.
            draft.inputModalities = refreshedCatalog.models.first(
                where: { $0.id == draft.model }
            )?.inputModalities
        } catch is CancellationError {
            return
        } catch {
            guard requestIdentity == SessionModelCatalogIdentity(configuration: draft) else {
                return
            }
            modelDiscoveryError = error.localizedDescription
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                if isFollowingGlobal {
                    try await model.setSessionModelConfiguration(nil)
                } else {
                    try await model.setSessionModelConfiguration(draft)
                }
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func endpointHost(_ baseURL: String) -> String {
        URLComponents(string: baseURL)?.host ?? "Invalid URL"
    }
}

struct SessionModelCatalogIdentity: Equatable {
    let profileID: String
    let providerID: ModelProviderID
    let baseURL: String

    init(configuration: AgentConfiguration) {
        profileID = configuration.profileID ?? configuration.providerID.rawValue
        providerID = configuration.providerID
        baseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SessionModelCatalog {
    let identity: SessionModelCatalogIdentity
    let source: ModelCatalogSource
    let fetchedAt: Date?
    let models: [ProviderModel]

    static func builtIn(for configuration: AgentConfiguration) -> SessionModelCatalog {
        let snapshot = ModelProviderCatalog.builtInSnapshot(for: configuration.providerID)
        return SessionModelCatalog(
            identity: SessionModelCatalogIdentity(configuration: configuration),
            source: snapshot.source,
            fetchedAt: snapshot.fetchedAt,
            models: snapshot.models
        )
    }

    static func stored(
        for profile: ProviderProfile,
        configuration: AgentConfiguration? = nil
    ) -> SessionModelCatalog {
        SessionModelCatalog(
            identity: SessionModelCatalogIdentity(
                configuration: configuration ?? profile.configuration()
            ),
            source: .builtIn,
            fetchedAt: nil,
            models: profile.models
        )
    }

    static func merging(
        _ snapshot: ModelCatalogSnapshot,
        existing: [ProviderModel],
        for configuration: AgentConfiguration
    ) -> SessionModelCatalog {
        guard snapshot.providerID == configuration.providerID else {
            return .builtIn(for: configuration)
        }

        var models = existing
        var positions = Dictionary(
            uniqueKeysWithValues: models.enumerated().map { ($0.element.id, $0.offset) }
        )
        for discoveredModel in snapshot.models {
            if let position = positions[discoveredModel.id] {
                let current = models[position]
                let builtIn = ModelProviderCatalog.descriptor(for: configuration.providerID)
                    .builtInModels
                    .first(where: { $0.id == discoveredModel.id })
                let refreshedModalities = discoveredModel.inputModalities == [.text]
                    && builtIn?.inputModalities.contains(.image) == true
                    ? builtIn?.inputModalities ?? discoveredModel.inputModalities
                    : discoveredModel.inputModalities
                let resolvedName = discoveredModel.name ?? current.name
                let resolvedDescription = discoveredModel.description ?? current.description
                let resolvedContextWindow = discoveredModel.contextWindow ?? current.contextWindow
                let resolvedMaxOutputTokens = discoveredModel.maxOutputTokens ?? current.maxOutputTokens
                let resolvedReasoningModes = discoveredModel.reasoningModes ?? current.reasoningModes
                let resolvedDefaultReasoningMode = discoveredModel.defaultReasoningMode
                    ?? current.defaultReasoningMode
                let resolvedReasoningWireStyle = discoveredModel.reasoningWireStyle
                    ?? current.reasoningWireStyle
                models[position] = ProviderModel(
                    id: discoveredModel.id,
                    name: resolvedName,
                    description: resolvedDescription,
                    contextWindow: resolvedContextWindow,
                    maxOutputTokens: resolvedMaxOutputTokens,
                    inputModalities: refreshedModalities,
                    reasoningModes: resolvedReasoningModes,
                    defaultReasoningMode: resolvedDefaultReasoningMode,
                    reasoningWireStyle: resolvedReasoningWireStyle,
                    // The refreshed catalog is authoritative for capabilities.
                    // Keeping `current.inputModalities` here preserves stale
                    // `.text` metadata from an older profile and makes
                    // `deepseek-v4-flash-vision-exp` fail the vision guard.
                    openAICompatibility: current.openAICompatibility
                )
            } else {
                positions[discoveredModel.id] = models.count
                models.append(discoveredModel)
            }
        }

        return SessionModelCatalog(
            identity: SessionModelCatalogIdentity(configuration: configuration),
            source: snapshot.source,
            fetchedAt: snapshot.fetchedAt,
            models: models
        )
    }
}

private struct SessionProviderStatusView: View {
    let credentialStatus: ProviderCredentialStatus
    let supportsInference: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(foregroundStyle)
    }

    private var title: String {
        guard supportsInference else { return "This protocol doesn't have a native inference client yet" }
        switch credentialStatus {
        case .unknown:
            return "Checking API Key"
        case .configured:
            return "API Key configured"
        case .missing:
            return "Missing API Key. Edit this profile first"
        case .originMismatch:
            return "API URL changed. Re-enter the API Key"
        }
    }

    private var systemImage: String {
        guard supportsInference else { return "exclamationmark.triangle.fill" }
        switch credentialStatus {
        case .unknown:
            return "ellipsis.circle"
        case .configured:
            return "checkmark.circle.fill"
        case .missing:
            return "key.slash"
        case .originMismatch:
            return "arrow.trianglehead.2.clockwise.rotate.90.circle"
        }
    }

    private var foregroundStyle: AnyShapeStyle {
        guard supportsInference else { return AnyShapeStyle(.orange) }
        switch credentialStatus {
        case .unknown:
            return AnyShapeStyle(.secondary)
        case .configured:
            return AnyShapeStyle(.green)
        case .missing:
            return AnyShapeStyle(.red)
        case .originMismatch:
            return AnyShapeStyle(.orange)
        }
    }
}

private struct SessionModelRow: View {
    let model: ProviderModel
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HarnessIconTile(
                systemImage: model.inputModalities.contains(.image) ? "photo" : "cpu",
                tint: model.inputModalities.contains(.image) ? .purple : .accentColor,
                size: 30
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name ?? model.id)
                    .foregroundStyle(.primary)
                if model.name != nil {
                    Text(model.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let capacityDescription {
                    Text(capacityDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "checkmark")
                .fontWeight(.semibold)
                .foregroundStyle(.tint)
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var capacityDescription: String? {
        var parts: [String] = []
        if let contextWindow = model.contextWindow {
            parts.append("Context \(contextWindow.formatted())")
        }
        if let maxOutputTokens = model.maxOutputTokens {
            parts.append("Max Output \(maxOutputTokens.formatted())")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
