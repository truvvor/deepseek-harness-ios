import Foundation

struct SettingsStore {
    private let defaults: UserDefaults
    private let legacyConfigurationKey = "agent.configuration.v1"
    private let providerDirectoryKey = "model.provider-directory.v1"
    private let compactionSummaryRouteKey = "agent.compaction-summary-route.v1"
    private let timeContextSettingsKey = "agent.time-context.v1"
    private let sessionTitleSettingsKey = "agent.session-title.v1"
    private let toolApprovalGrantsKey = "tool.approval-grants.v1"
    private let defaultAgentPresetKey = "agent.default-preset.v1"
    /// Desktop-bridge (read-only session mirror) preferences. A new key, so no
    /// existing setting is renamed, moved or reinterpreted by this addition.
    /// `bridge.desktop-mirror.v1` never contains the bearer token: that lives in
    /// the Keychain (`CredentialStore.bridgeTokenAccount`).
    private let bridgeSettingsKey = "bridge.desktop-mirror.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AgentConfiguration {
        if let profile = loadProviderDirectory().directory.activeProfile {
            return profile.configuration()
        }
        return loadLegacyConfiguration() ?? AgentConfiguration()
    }

    func save(_ configuration: AgentConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: legacyConfigurationKey)
    }

    func loadProviderDirectory() -> ProviderProfileDirectoryLoadResult {
        if let data = defaults.data(forKey: providerDirectoryKey),
           let directory = try? JSONDecoder().decode(ProviderProfileDirectory.self, from: data),
           let validated = try? directory.validated() {
            return ProviderProfileDirectoryLoadResult(
                directory: validated,
                legacyConfiguration: nil
            )
        }

        if let legacyConfiguration = loadLegacyConfiguration() {
            return ProviderProfileDirectoryLoadResult(
                directory: .migrating(legacyConfiguration),
                legacyConfiguration: legacyConfiguration
            )
        }

        return ProviderProfileDirectoryLoadResult(
            directory: .initial(),
            legacyConfiguration: nil
        )
    }

    func save(_ directory: ProviderProfileDirectory) throws {
        let validated = try directory.validated()
        let data = try JSONEncoder().encode(validated)
        defaults.set(data, forKey: providerDirectoryKey)
        defaults.removeObject(forKey: legacyConfigurationKey)
    }

    func loadCompactionSummaryRoute(
        in directory: ProviderProfileDirectory
    ) -> CompactionSummaryRoute? {
        guard let data = defaults.data(forKey: compactionSummaryRouteKey),
              let decoded = try? JSONDecoder().decode(CompactionSummaryRoute.self, from: data),
              let validated = try? decoded.validated(in: directory) else {
            return nil
        }
        return validated
    }

    func saveCompactionSummaryRoute(
        _ route: CompactionSummaryRoute?,
        in directory: ProviderProfileDirectory
    ) throws {
        guard let route else {
            defaults.removeObject(forKey: compactionSummaryRouteKey)
            return
        }
        let validated = try route.validated(in: directory)
        defaults.set(try JSONEncoder().encode(validated), forKey: compactionSummaryRouteKey)
    }

    func loadTimeContextSettings() -> TimeContextSettings {
        guard let data = defaults.data(forKey: timeContextSettingsKey),
              let decoded = try? JSONDecoder().decode(TimeContextSettings.self, from: data),
              let validated = try? decoded.validated() else {
            return TimeContextSettings()
        }
        return validated
    }

    func saveTimeContextSettings(_ settings: TimeContextSettings) throws {
        let validated = try settings.validated()
        defaults.set(try JSONEncoder().encode(validated), forKey: timeContextSettingsKey)
    }

    func loadSessionTitleSettings(in directory: ProviderProfileDirectory) -> SessionTitleSettings {
        guard let data = defaults.data(forKey: sessionTitleSettingsKey),
              let decoded = try? JSONDecoder().decode(SessionTitleSettings.self, from: data),
              let validated = try? decoded.validated(in: directory) else {
            return SessionTitleSettings()
        }
        return validated
    }

    func saveSessionTitleSettings(
        _ settings: SessionTitleSettings,
        in directory: ProviderProfileDirectory
    ) throws {
        let validated = try settings.validated(in: directory)
        defaults.set(try JSONEncoder().encode(validated), forKey: sessionTitleSettingsKey)
    }

    func loadToolApprovalGrants() -> [ToolApprovalGrant] {
        guard let data = defaults.data(forKey: toolApprovalGrantsKey),
              let decoded = try? JSONDecoder().decode([ToolApprovalGrant].self, from: data) else {
            return []
        }

        var scopes = Set<ToolApprovalScope>()
        return decoded
            .compactMap { try? $0.validated() }
            .sorted { lhs, rhs in
                if lhs.grantedAt != rhs.grantedAt {
                    return lhs.grantedAt > rhs.grantedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .filter { scopes.insert($0.scope).inserted }
            .prefix(ToolApprovalGrant.maximumStoredGrants)
            .map { $0 }
    }

    func saveToolApprovalGrants(_ grants: [ToolApprovalGrant]) throws {
        guard grants.count <= ToolApprovalGrant.maximumStoredGrants else {
            throw ToolApprovalScopeError.tooManyGrants
        }
        let validated = try grants.map { try $0.validated() }
        guard Set(validated.map(\.scope)).count == validated.count else {
            throw ToolApprovalScopeError.invalidResource
        }
        defaults.set(
            try JSONEncoder().encode(validated),
            forKey: toolApprovalGrantsKey
        )
    }

    func clearToolApprovalGrants() {
        defaults.removeObject(forKey: toolApprovalGrantsKey)
    }

    func loadDefaultAgentPresetID() -> String {
        guard let id = defaults.string(forKey: defaultAgentPresetKey),
              AgentPresetIdentifier.isValid(id) else {
            return AgentPresetRegistry.defaultID
        }
        return id
    }

    func saveDefaultAgentPresetID(_ id: String) throws {
        guard AgentPresetIdentifier.isValid(id) else {
            throw AgentPresetError.invalidID(id)
        }
        defaults.set(id, forKey: defaultAgentPresetKey)
    }

    /// Missing, corrupt, or out-of-bounds values fall back to the disabled
    /// defaults, so a damaged row can never silently switch on bridge traffic.
    func loadBridgeSettings() -> BridgeSettings {
        guard let data = defaults.data(forKey: bridgeSettingsKey),
              let decoded = try? JSONDecoder().decode(BridgeSettings.self, from: data),
              let validated = try? decoded.validated() else {
            return BridgeSettings()
        }
        return validated
    }

    func saveBridgeSettings(_ settings: BridgeSettings) throws {
        let validated = try settings.validated()
        defaults.set(try JSONEncoder().encode(validated), forKey: bridgeSettingsKey)
    }

    func clearBridgeSettings() {
        defaults.removeObject(forKey: bridgeSettingsKey)
    }

    func clear() {
        defaults.removeObject(forKey: legacyConfigurationKey)
        defaults.removeObject(forKey: providerDirectoryKey)
        defaults.removeObject(forKey: compactionSummaryRouteKey)
        defaults.removeObject(forKey: timeContextSettingsKey)
        defaults.removeObject(forKey: sessionTitleSettingsKey)
        defaults.removeObject(forKey: defaultAgentPresetKey)
        defaults.removeObject(forKey: bridgeSettingsKey)
    }

    private func loadLegacyConfiguration() -> AgentConfiguration? {
        guard let data = defaults.data(forKey: legacyConfigurationKey) else { return nil }
        return try? JSONDecoder().decode(AgentConfiguration.self, from: data)
    }
}

struct ProviderProfileDirectoryLoadResult: Sendable, Equatable {
    let directory: ProviderProfileDirectory
    let legacyConfiguration: AgentConfiguration?
}
