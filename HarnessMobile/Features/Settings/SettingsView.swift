import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isResetConfirmationPresented = false
    @State private var isRemoveConfirmationPresented = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Provider", value: activeProfileName)
                LabeledContent("API", value: endpointHost)
                LabeledContent("Model", value: model.configuration.model)
                LabeledContent("Reasoning", value: model.configuration.reasoningMode.title)
                if let compatibilityNotice = provider.compatibilityNotice {
                    Label(compatibilityNotice, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                NavigationLink {
                    ProviderProfilesView()
                } label: {
                    SettingsLinkLabel(title: "Models & Providers", systemImage: "server.rack", tint: .blue)
                }
                .accessibilityIdentifier("settings-model-providers")
            } header: { Label("Model", systemImage: "server.rack") }

            Section {
                NavigationLink {
                    BackgroundSettingsView(
                        runtimeStatus: model.backgroundRuntimeStatus,
                        locationSnapshot: model.backgroundLocationKeepAliveSnapshot,
                        systemProjection: model.backgroundSystemProjection,
                        requestLocationAuthorization: model.requestBackgroundLocationAuthorization
                    )
                } label: {
                    SettingsLinkLabel(title: "Background Tasks & Recovery", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90", tint: .orange)
                }
                .accessibilityIdentifier("settings-background-tasks")
                LabeledContent("Current Status", value: backgroundStatusLabel)
                LabeledContent("Active Tasks", value: "\(model.backgroundSystemProjection.activeRunCount)")
            } header: { Label("Background", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") }

            Section {
                NavigationLink {
                    WebSearchSettingsView()
                } label: {
                    SettingsLinkLabel(title: "Web Search", systemImage: "magnifyingglass", tint: .cyan)
                }
                .accessibilityIdentifier("settings-web-search")
            } header: { Label("Search", systemImage: "magnifyingglass") }

            Section {
                NavigationLink {
                    LocalWebhookSettingsView()
                } label: {
                    SettingsLinkLabel(title: "GitHub Webhook", systemImage: "arrow.down.circle", tint: .purple)
                }
                .accessibilityIdentifier("settings-github-webhook")
            } header: { Label("Event Ingestion", systemImage: "arrow.down.circle") }

            Section {
                NavigationLink {
                    AgentProviderBundlesView()
                } label: {
                    SettingsLinkLabel(title: "Agent Orchestration Bundle", systemImage: "arrow.triangle.branch", tint: .indigo)
                }
                .accessibilityIdentifier("settings-agent-bundles")
                NavigationLink {
                    PhonePermissionsView()
                } label: {
                    SettingsLinkLabel(title: "Device Permissions", systemImage: "hand.raised", tint: .green)
                }
                .accessibilityIdentifier("settings-phone-permissions")
            } header: { Label("Agents & Permissions", systemImage: "person.crop.circle.badge.checkmark") }

            Section {
                NavigationLink {
                    PluginManagementView()
                } label: {
                    SettingsLinkLabel(title: "Cordis Plugins", systemImage: "puzzlepiece.extension", tint: .purple)
                }
                NavigationLink {
                    ToolApprovalSettingsView()
                } label: {
                    HStack {
                        SettingsLinkLabel(title: "Tool Approvals", systemImage: "checkmark.shield", tint: .teal)
                        Spacer()
                        Text("This Time Only")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settings-tool-approvals")
                LabeledContent("Local Tools", value: "\(ProductionToolCatalog.approvedNames.count)")
            } header: { Label("Tools & Plugins", systemImage: "puzzlepiece.extension") }

            Section {
                NavigationLink {
                    DesktopBridgeSettingsView()
                } label: {
                    SettingsLinkLabel(title: "Desktop DSH Bridge", systemImage: "desktopcomputer", tint: .blue)
                }
                .accessibilityIdentifier("settings-desktop-bridge")
            } header: { Label("Desktop Mirror", systemImage: "desktopcomputer") }

            Section {
                NavigationLink {
                    WorkspaceView()
                } label: {
                    SettingsLinkLabel(title: "Local Workspace", systemImage: "folder", tint: .orange)
                }
                .accessibilityIdentifier("settings-workspace")
                NavigationLink {
                    MemoryManagementView()
                } label: {
                    SettingsLinkLabel(title: "Memory", systemImage: "brain", tint: .purple)
                }
                .accessibilityIdentifier("settings-memory")
                LabeledContent("Session Storage", value: "On-Device")
                LabeledContent("Desktop Mirror", value: mirroredSessionCount > 0 ? "\(mirroredSessionCount) Read-Only" : "Off")
                Text("Sessions, trajectories, and workspace files are stored on this iPhone. The optional Desktop DSH Bridge mirrors sessions of your DeepSeek Harness desktop; messages typed in a mirror run on the desktop agent, which stays the master of that session. Local sessions never send their tools or agent loop to another machine.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: { Label("Storage & Sync", systemImage: "externaldrive") }

            Section {
                Button {
                    isResetConfirmationPresented = true
                } label: {
                    Label("Clear Current Session", systemImage: "trash")
                }
                .foregroundStyle(.red)

                Button {
                    isRemoveConfirmationPresented = true
                } label: {
                    Label("Reset All Model Connections", systemImage: "arrow.counterclockwise")
                }
                .foregroundStyle(.red)
            } header: {
                Label("Danger Zone", systemImage: "exclamationmark.triangle")
            } footer: {
                Text("These actions only affect local configuration or the current session; workspace files are not deleted.")
            }

            Section {
                DisclosureGroup("Execution Boundary") {
                    LabeledContent("Model Inference", value: "Your Configured API")
                    LabeledContent("Agent Loop", value: "On Device")
                    LabeledContent("Tools & Files", value: "On Device")
                    LabeledContent("Command Execution", value: "On-Device iSH / Alpine")
                    LabeledContent("Linux Network", value: "On by Default")
                    Text("The model provider only handles inference. shell_execute, files, and the Agent Loop all run on the iPhone; Linux networking is available by default and can be turned off on the Commands page.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                NavigationLink {
                    DiagnosticLogView()
                } label: {
                    SettingsLinkLabel(title: "Detailed Logs", systemImage: "doc.text.magnifyingglass", tint: .gray)
                }
                .accessibilityIdentifier("settings-diagnostics")
                if let usage = model.latestUsage {
                    LabeledContent("Recent Usage", value: "Input \(usage.promptTokens) · Output \(usage.completionTokens)")
                }
                Text("Diagnostic exports are redacted on device first; by default they exclude API keys, Authorization headers, command text, and model prompts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: { Label("Privacy & Diagnostics", systemImage: "checkmark.shield") }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(HarnessTheme.pageBackground)
        .navigationTitle("Settings")
        .confirmationDialog(
            "Clear Current Session?",
            isPresented: $isResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task {
                    await model.resetConversation()
                }
            }
        } message: {
            Text("This deletes the current conversation stored on this device. Workspace files are not deleted.")
        }
        .confirmationDialog(
            "Reset All Model Connections?",
            isPresented: $isRemoveConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task {
                    await model.removeConfiguration()
                }
            }
        } message: {
            Text("All Provider Profiles and API Keys will be removed. Local sessions and workspace files are kept.")
        }
    }

    private var provider: ModelProviderDescriptor {
        ModelProviderCatalog.descriptor(for: model.configuration.providerID)
    }

    private var activeProfileName: String {
        model.activeProviderProfile?.displayName ?? provider.displayName
    }

    private var endpointHost: String {
        URLComponents(string: model.configuration.baseURL)?.host ?? "Invalid URL"
    }

    private var mirroredSessionCount: Int {
        model.sessions.filter(\.isDesktopMirror).count
    }

    private var backgroundStatusLabel: String {
        switch model.backgroundSystemProjection.survivalTier {
        case .foreground: "Foreground"
        case .finiteBackgroundTask: "Short Background"
        case .continuedProcessing: "Continued Processing"
        case .extendedAudio: "Extended (Audio)"
        case .extendedLocation: "Extended (Location)"
        case .degraded: "Degraded"
        }
    }
}

private struct SettingsLinkLabel: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 11) {
            HarnessIconTile(systemImage: systemImage, tint: tint, size: 30)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }
}

/// Desktop DeepSeek Harness bridge (mirror + desktop turns, D-014).
///
/// This screen can only *read* desktop sessions. It deliberately offers no
/// prompt, cancel or chat-completions entry point, because the product boundary
/// forbids sending this app's prompts, tools or agent loop to another machine.
private struct DesktopBridgeSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var isEnabled = false
    @State private var baseURLText = ""
    @State private var includesArchived = false
    @State private var autoFollow = false
    @State private var token = ""
    @State private var tokenConfigured = false
    @State private var isSavingToken = false
    @State private var isImporting = false
    @State private var isProbing = false
    @State private var healthSummary: String?
    @State private var errorMessage: String?
    @State private var importSummary: String?
    @State private var mirrorSessions: [ConversationSessionSummary] = []

    var body: some View {
        Form {
            Section {
                Toggle("Enable Desktop Bridge", isOn: $isEnabled)
                    .accessibilityIdentifier("desktop-bridge-enabled")
                TextField("Bridge URL", text: $baseURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("desktop-bridge-url")
                Toggle("Include Archived Desktop Sessions", isOn: $includesArchived)
                Toggle("Follow Open Mirror Automatically", isOn: $autoFollow)
                HStack {
                    Button("Save") { saveSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("Test Connection") { probe() }
                        .disabled(isProbing || !isEnabled)
                    if isProbing { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("Bridge")
            } footer: {
                Text("The address is the DSH host origin, for example http://203.0.113.7:19387, a LAN IP, or a host name. /bridge/v1 is appended automatically. Over plain HTTP the bearer token and session content travel unencrypted, so prefer https:// (a reverse proxy or a tailnet) when the host is reachable from the internet. Model providers always require HTTPS.")
            }

            Section {
                SecureField("Bearer Token", text: $token)
                    .textContentType(.password)
                    .accessibilityIdentifier("desktop-bridge-token")
                LabeledContent("Token", value: tokenConfigured ? "In Keychain" : "Not Configured")
                HStack {
                    Button("Save Token") { saveToken() }
                        .buttonStyle(.borderedProminent)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingToken)
                    if tokenConfigured {
                        Button("Delete Token", role: .destructive) { deleteToken() }
                            .disabled(isSavingToken)
                    }
                    if isSavingToken { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("Credential")
            } footer: {
                Text("The token is the content of api-bridge.token on the DSH host. It is stored only in this device's Keychain (WhenUnlockedThisDeviceOnly) and is sent only as the Authorization header of a bridge request; it is never written to settings, logs, URLs, session content or exports.")
            }

            Section {
                Button {
                    importSessions()
                } label: {
                    Label("Import Desktop Sessions", systemImage: "arrow.down.circle")
                }
                .disabled(isImporting || !isEnabled)

                if isImporting {
                    if let progress = model.desktopMirrorProgress {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: progress.fraction)
                            Text(progress.currentTitle ?? "Finishing…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Importing desktop sessions")
                    } else {
                        ProgressView()
                    }
                }
                if let importSummary {
                    Text(importSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let healthSummary {
                    Text(healthSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Import")
            } footer: {
                Text("Importing copies the desktop session log into this app as a local trajectory plus a search index entry. Nothing is written back by the import; the imported session is marked as a desktop mirror.")
            }

            Section {
                if mirrorSessions.isEmpty {
                    Text("No desktop sessions have been mirrored yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(mirrorSessions) { session in
                    Button {
                        Task { await model.openDesktopMirrorSession(session.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.title).font(.body.weight(.semibold))
                            HStack(spacing: 6) {
                                Label("Desktop Mirror", systemImage: "desktopcomputer")
                                Text("·")
                                Text("\(session.messageCount) messages")
                                if model.followedMirrorSessionIDs.contains(session.id) {
                                    Text("·")
                                    Label("Following", systemImage: "dot.radiowaves.left.and.right")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the mirror of this desktop session")
                    .swipeActions(edge: .trailing) {
                        Button("Forget", role: .destructive) {
                            Task { await model.removeDesktopMirrorSession(session.id) }
                        }
                    }
                }
            } header: {
                Text("Mirrored Sessions")
            } footer: {
                Text("The desktop stays the master of a mirrored session. While the bridge is connected, a message typed in a mirror runs as a turn of the desktop agent and the stop button cancels it there; the iPhone only keeps the mirrored log and never runs its own agent for it. Forget removes the local copy only.")
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(HarnessTheme.pageBackground)
        .navigationTitle("Desktop DSH Bridge")
        .task {
            let settings = model.desktopMirrorSettings
            isEnabled = settings.isEnabled
            baseURLText = settings.baseURL?.absoluteString ?? ""
            includesArchived = settings.includesArchivedSessions
            autoFollow = settings.followsSelectedMirrorAutomatically
            tokenConfigured = await model.desktopMirrorTokenConfigured()
            await reloadMirrorSessions()
        }
        .alert("Desktop Bridge", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func saveSettings() {
        let settings = BridgeSettings(
            baseURL: URL(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
            isEnabled: isEnabled,
            includesArchivedSessions: includesArchived,
            followsSelectedMirrorAutomatically: autoFollow
        )
        if isEnabled, settings.baseURL == nil {
            errorMessage = BridgeSettingsError.invalidBaseURL.errorDescription
            return
        }
        Task {
            guard await model.saveDesktopMirrorSettings(settings) else {
                errorMessage = model.desktopMirrorLastError
                return
            }
            // Show the normalized address so the user can see what will be used.
            baseURLText = model.desktopMirrorSettings.baseURL?.absoluteString ?? baseURLText
            errorMessage = nil
            await reloadMirrorSessions()
        }
    }

    private func saveToken() {
        isSavingToken = true
        Task {
            let success = await model.saveDesktopMirrorToken(token)
            if success {
                token = ""
                tokenConfigured = true
            } else {
                errorMessage = model.desktopMirrorLastError
            }
            isSavingToken = false
        }
    }

    private func deleteToken() {
        isSavingToken = true
        Task {
            await model.deleteDesktopMirrorToken()
            tokenConfigured = false
            isSavingToken = false
        }
    }

    private func probe() {
        isProbing = true
        healthSummary = nil
        Task {
            if let health = await model.checkDesktopMirrorHealth() {
                let services = health.services?.keys.sorted().joined(separator: ", ") ?? "unknown"
                healthSummary = "Bridge \(health.displayStatus) · services: \(services)"
            } else {
                errorMessage = model.desktopMirrorLastError ?? "The bridge did not answer."
            }
            isProbing = false
        }
    }

    private func importSessions() {
        isImporting = true
        importSummary = nil
        Task {
            let result = await model.importDesktopMirrorSessions()
            importSummary = "Created \(result.created), refreshed \(result.refreshed), failed \(result.failures.count)."
            if !result.failures.isEmpty {
                errorMessage = result.failures.values.sorted().first
            }
            isImporting = false
            await reloadMirrorSessions()
        }
    }

    private func reloadMirrorSessions() async {
        mirrorSessions = model.sessions.filter(\.isDesktopMirror)
    }
}

private struct WebSearchSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedProvider = "none"
    @State private var apiKey = ""
    @State private var credentialStatus: ProviderCredentialStatus = .unknown
    @State private var errorMessage: String?
    @State private var isSaving = false

    private let providers = [
        (id: "none", name: "Search Off", detail: "Don't register the web search tool"),
        (id: DeepSeekSearchProvider.identifierValue, name: "DeepSeek", detail: "Use the current model provider's search capability"),
        (id: ExaSearchProvider.identifierValue, name: "Exa", detail: "Exa Search API"),
        (id: PerplexitySearchProvider.identifierValue, name: "Perplexity", detail: "Perplexity Sonar API")
    ]

    var body: some View {
        Form {
            Section {
                Picker("Search Provider", selection: $selectedProvider) {
                    ForEach(providers, id: \.id) { provider in
                        VStack(alignment: .leading) {
                            Text(provider.name)
                            Text(provider.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .disabled(provider.id == DeepSeekSearchProvider.identifierValue && model.effectiveConfiguration.providerID != .deepSeekOfficial)
                        .tag(provider.id)
                    }
                }
                .accessibilityIdentifier("web-search-provider-picker")
                .onChange(of: selectedProvider) { _, newValue in
                    model.setWebSearchProvider(newValue == "none" ? nil : newValue)
                    Task { await refreshCredentialStatus(for: newValue) }
                }
            } header: {
                Text("Web Search")
            } footer: {
                Text("Search results include the URL, title, and snippet returned by the provider. DeepSeek is only available when the current model provider is official DeepSeek.")
            }

            if selectedProvider == ExaSearchProvider.identifierValue || selectedProvider == PerplexitySearchProvider.identifierValue {
                Section {
                    SecureField("API Key", text: $apiKey)
                        .textContentType(.password)
                        .accessibilityIdentifier("web-search-api-key")
                    LabeledContent("Credential Status", value: credentialStatusLabel)
                    HStack {
                        Button("Save") { saveKey() }
                            .buttonStyle(.borderedProminent)
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                        if credentialStatus == .configured {
                            Button("Delete Key", role: .destructive) { deleteKey() }
                                .disabled(isSaving)
                        }
                        if isSaving { ProgressView().controlSize(.small) }
                    }
                } header: {
                    Text("\(selectedProvider.capitalized) Credentials")
                } footer: {
                    Text("The key is stored only in the local Keychain. Without a key, the search tool returns an explicit error.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(HarnessTheme.pageBackground)
        .navigationTitle("Web Search")
        .task {
            let saved = UserDefaults.standard.string(forKey: "harness.web-search-provider")
            selectedProvider = saved ?? (model.effectiveConfiguration.providerID == .deepSeekOfficial ? DeepSeekSearchProvider.identifierValue : "none")
            await refreshCredentialStatus(for: selectedProvider)
        }
        .alert("Search Settings Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var credentialStatusLabel: String {
        switch credentialStatus {
        case .unknown: "Checking"
        case .configured: "Configured"
        case .missing: "Missing Key"
        case .originMismatch: "Origin Mismatch"
        }
    }

    private func refreshCredentialStatus(for providerID: String) async {
        guard providerID == ExaSearchProvider.identifierValue || providerID == PerplexitySearchProvider.identifierValue else {
            credentialStatus = .unknown
            return
        }
        credentialStatus = await model.searchProviderCredentialStatus(for: providerID)
    }

    private func saveKey() {
        isSaving = true
        Task {
            do {
                try await model.saveSearchProviderAPIKey(apiKey, providerID: selectedProvider)
                model.setWebSearchProvider(selectedProvider)
                apiKey = ""
                await refreshCredentialStatus(for: selectedProvider)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func deleteKey() {
        isSaving = true
        Task {
            do {
                try await model.deleteSearchProviderAPIKey(providerID: selectedProvider)
                credentialStatus = .missing
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

private struct LocalWebhookSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var secret = ""
    @State private var configured = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var rules: [LocalWebhookRule] = []
    @State private var ruleID = ""
    @State private var providerKind = "github"
    @State private var eventName = "*"
    @State private var jobLabel = ""
    @State private var prompt = ""
    @State private var maximumAttempts = 1
    @State private var wakeActiveSession = false

    var body: some View {
        Form {
            Section {
                SecureField("Webhook Secret", text: $secret)
                    .textContentType(.password)
                    .accessibilityIdentifier("github-webhook-secret")
                LabeledContent("Signature Verification", value: configured ? "Enabled" : "Not Configured")
                HStack {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                    if configured {
                        Button("Delete Secret", role: .destructive) { remove() }
                            .disabled(isSaving)
                    }
                    if isSaving { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("GitHub Signature")
            } footer: {
                Text("Once set, POST /webhook/github must include a matching X-Hub-Signature-256. Events are still projected only to local Jobs.")
            }

            Section {
                if rules.isEmpty {
                    Text("When not configured, all events use the default local Job.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rules) { rule in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.id).font(.headline)
                        Text("\(rule.providerKind) / \(rule.eventName) → \(rule.jobLabel)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { try? await model.deleteLocalWebhookRule(id: rule.id); await reloadRules() }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                TextField("Rule ID", text: $ruleID)
                    .textInputAutocapitalization(.never)
                TextField("Provider (e.g. github)", text: $providerKind)
                    .textInputAutocapitalization(.never)
                TextField("Event (* for all)", text: $eventName)
                    .textInputAutocapitalization(.never)
                TextField("Job Label (Optional)", text: $jobLabel)
                TextField("Wake Prompt (Optional)", text: $prompt, axis: .vertical)
                Stepper("Retries on Failure: \(maximumAttempts)", value: $maximumAttempts, in: 1...5)
                Toggle("Wake Current Agent After Event", isOn: $wakeActiveSession)
                Button("Save Rule") { saveRule() }
                    .disabled(ruleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Webhook Rules")
            } footer: {
                Text("Rules match on provider and event; {event}, {delivery}, and {payload} can be used in the wake prompt.")
            }

            Section {
                LabeledContent("Local Address", value: "127.0.0.1")
                Text("iOS does not support persistent public listening. For external access, use a tunnel or push relay you configure yourself, and keep local event evidence.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Listening Scope")
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(HarnessTheme.pageBackground)
        .navigationTitle("GitHub Webhook")
        .task { configured = await model.localWebhookSecretConfigured(); await reloadRules() }
        .alert("Webhook Settings Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await model.saveLocalWebhookSecret(secret)
                secret = ""
                configured = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func remove() {
        isSaving = true
        Task {
            do {
                try await model.deleteLocalWebhookSecret()
                configured = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func reloadRules() async {
        rules = await model.localWebhookRules()
    }

    private func saveRule() {
        Task {
            do {
                let rule = try LocalWebhookRule(
                    id: ruleID,
                    providerKind: providerKind,
                    eventName: eventName,
                    jobLabel: jobLabel.isEmpty ? nil : jobLabel,
                    prompt: prompt.isEmpty ? nil : prompt,
                    maximumAttempts: maximumAttempts,
                    wakeActiveSession: wakeActiveSession
                )
                try await model.saveLocalWebhookRule(rule)
                ruleID = ""; jobLabel = ""; prompt = ""; wakeActiveSession = false
                await reloadRules()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct DiagnosticLogView: View {
    @Environment(AppModel.self) private var model

    @State private var isRefreshing = false
    @State private var isPreparingExport = false
    @State private var isFileExporterPresented = false
    @State private var exportDocument: ConversationExportFileDocument?
    @State private var exportFilename = "Harness-Diagnostics"
    @State private var workspaceExportPath: String?

    var body: some View {
        @Bindable var preferences = model.backgroundPreferences

        Form {
            Section {
                LabeledContent("Agent", value: model.isRunning ? "Running" : "Idle")
                LabeledContent("Current Step", value: "\(model.currentStep)")
                LabeledContent("Session Trajectory", value: "\(model.trajectoryEvents.count)")
                LabeledContent("Harness Trace", value: "\(model.harnessTraceEvents.count)")
            } header: {
                Label("Current Run", systemImage: "waveform.path.ecg")
            }

            Section {
                Text(model.diagnosticHostStateDescription)
                    .font(.footnote)
                    .textSelection(.enabled)

                if let diagnostics = model.ishPluginHostDiagnostics {
                    LabeledContent("Pending RPCs", value: "\(diagnostics.pendingRequestCount)")
                    LabeledContent(
                        "Queued stdin",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(diagnostics.outboundQueuedBytes),
                            countStyle: .memory
                        )
                    )
                    LabeledContent(
                        "stdin Write",
                        value: diagnostics.outboundWriteInFlight ? "In Progress" : "Idle"
                    )
                    LabeledContent("stdin Rejections", value: "\(diagnostics.rejectedWriteCount)")
                    if let failure = diagnostics.lastTransportFailure {
                        LabeledContent("Last Transport Error") {
                            Text(failure)
                                .font(.caption.monospaced())
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if !diagnostics.stderrTail.isEmpty {
                        DisclosureGroup("Recent stderr Output") {
                            Text(diagnostics.stderrTail)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if let failure = model.ishPluginMarketplaceFailure {
                    Text(failure.message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Label("Cordis Host", systemImage: "terminal")
            }

            Section {
                Button("Refresh Logs", systemImage: "arrow.clockwise") {
                    refresh()
                }
                .disabled(isRefreshing || isPreparingExport)

                Button("Export Detailed Logs", systemImage: "square.and.arrow.up") {
                    prepareExport()
                }
                .disabled(isRefreshing || isPreparingExport)

                if isRefreshing || isPreparingExport {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(isPreparingExport ? "Generating redacted logs…" : "Refreshing local status…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                DisclosureGroup("Export Contents & Redaction") {
                    Text("The export includes device and runtime status, Cordis plugins, Plugin Host stderr, limited runtime telemetry, Harness Trace, and the full trajectory of the current session. API keys, Authorization, and common password/secret fields are redacted on the phone before being written to the file; a copy is also written to the current session's local Downloads workspace.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Redacted on device before export and saved to the current session's Downloads.")
            }

            Section {
                Toggle("Record Limited Performance/Resource Samples", isOn: $preferences.isPerformanceResourceSamplingEnabled)
                    .onChange(of: preferences.isPerformanceResourceSamplingEnabled) { _, _ in
                        Task { await model.configureRuntimePerformanceSampling() }
                    }

                DisclosureGroup("Sampled Data & Privacy") {
                    Text("When on, only bounded numeric markers for thermal state, low power, and foreground/background are recorded; prompts, tool arguments or output, URLs, request headers, cookies, environment variables, and call stacks are never recorded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Performance & Resource Sampling")
            } footer: {
                Text("Off by default; records only bounded numeric system markers.")
            }

            if let workspaceExportPath {
                Section {
                    Text(workspaceExportPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text("Local Copy")
                } footer: {
                    Text("This is a workspace-relative path isolated by the current session's hash; it does not contain the raw session ID.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(HarnessTheme.pageBackground)
        .navigationTitle("Detailed Logs")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isFileExporterPresented,
            document: exportDocument,
            contentType: ConversationExportFileDocument.logContentType,
            defaultFilename: exportFilename
        ) { result in
            exportDocument = nil
            if case let .failure(error) = result {
                model.presentError(error)
            }
        }
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { @MainActor in
            await model.refreshDiagnostics()
            isRefreshing = false
        }
    }

    private func prepareExport() {
        guard !isPreparingExport else { return }
        isPreparingExport = true
        Task { @MainActor in
            defer { isPreparingExport = false }
            do {
                let export = try await model.diagnosticReportExport()
                exportDocument = ConversationExportFileDocument(data: export.data)
                workspaceExportPath = export.workspacePath
                exportFilename = "Harness-Diagnostics-\(Self.filenameTimestamp())"
                isFileExporterPresented = true
            } catch {
                model.presentError(error)
            }
        }
    }

    private static func filenameTimestamp(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

private struct ToolApprovalSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isRevokeAllConfirmationPresented = false

    var body: some View {
        Form {
            if model.trustedToolApprovals.isEmpty {
                Section {
                    Label("No Persistent Tool Approvals", systemImage: "checkmark.shield")
                } footer: {
                    Text("Approvals are saved only when you choose 'Always Allow' in the first prompt; iOS privacy permissions are still managed separately by the system.")
                }
            } else {
                Section {
                    ForEach(model.trustedToolApprovals) { grant in
                        ToolApprovalGrantRow(grant: grant) {
                            model.revokeToolApproval(id: grant.id)
                        }
                    }
                    Button("Revoke All Tool Approvals", role: .destructive) {
                        isRevokeAllConfirmationPresented = true
                    }
                } header: {
                    Text("Persistent Approvals")
                } footer: {
                    Text("iOS privacy permissions are still managed separately by the system.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(HarnessTheme.pageBackground)
        .navigationTitle("Tool Approvals")
        .confirmationDialog(
            "Revoke All Tool Approvals?",
            isPresented: $isRevokeAllConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Revoke All", role: .destructive) {
                model.revokeAllToolApprovals()
            }
        } message: {
            Text("After deletion, tool calls matching the same scope will ask again.")
        }
    }
}

private struct ToolApprovalGrantRow: View {
    let grant: ToolApprovalGrant
    let onRevoke: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HarnessIconTile(
                systemImage: grant.scope.risk.systemImage,
                tint: grant.scope.risk.tint,
                size: 30
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(grant.scope.toolName)
                    .font(.headline)
                Text(grant.scope.risk.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(grant.scope.resourceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(grant.scope.modelDestination)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(role: .destructive, action: onRevoke) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Revoke \(grant.scope.toolName) Approval")
        }
        .accessibilityElement(children: .contain)
    }
}

private extension ToolRisk {
    var systemImage: String {
        switch self {
        case .pure:
            "equal.circle"
        case .localState:
            "iphone"
        case .sensitiveRead:
            "eye"
        case .sideEffect:
            "hammer"
        case .destructive:
            "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .pure, .localState:
            .secondary
        case .sensitiveRead:
            .blue
        case .sideEffect:
            .orange
        case .destructive:
            .red
        }
    }
}

private extension ToolApprovalScope {
    var resourceSummary: String {
        if toolName == Self.allLocalToolsMarker,
           resources == [Self.allLocalToolsResource] {
            return "Local Tools (All Risk Levels)"
        }
        return resources.map { resource in
            switch resource {
            case "tool":
                "Entire Tool"
            case "workspace:root":
                "App Workspace"
            case "ish-sandbox:/workspace":
                "iSH /workspace Sandbox"
            default:
                resource.replacingOccurrences(of: "workspace:file:", with: "Workspace file: ")
            }
        }
        .joined(separator: ", ")
    }
}
