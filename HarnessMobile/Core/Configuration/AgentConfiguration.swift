import Foundation

struct AgentConfiguration: Codable, Sendable, Equatable {
    static let defaultBaseURL = "https://api.deepseek.com/v1"
    static let defaultModel = "deepseek-v4-flash"

    var providerID: ModelProviderID = .deepSeekOfficial
    var profileID: String?
    var credentialReference: CredentialReference?
    var baseURL: String = defaultBaseURL
    var model: String = defaultModel
    var inputModalities: [ModelInputModality]?
    var supportedReasoningModes: [ReasoningMode]?
    var reasoningWireStyle: ModelReasoningWireStyle?
    var reasoningMode: ReasoningMode = .high
    var openAIWireProfile: OpenAICompatibleWireProfile?
    var openAICompatibility: OpenAICompletionsCompatibility?
    var retryPolicy: ProviderRetryPolicyConfiguration?
    var maxSteps: Int = 8
    var maxOutputTokens: Int = 8_192

    init(
        providerID: ModelProviderID = .deepSeekOfficial,
        profileID: String? = nil,
        credentialReference: CredentialReference? = nil,
        baseURL: String = defaultBaseURL,
        model: String = defaultModel,
        inputModalities: [ModelInputModality]? = nil,
        supportedReasoningModes: [ReasoningMode]? = nil,
        reasoningWireStyle: ModelReasoningWireStyle? = nil,
        reasoningMode: ReasoningMode = .high,
        openAIWireProfile: OpenAICompatibleWireProfile? = nil,
        openAICompatibility: OpenAICompletionsCompatibility? = nil,
        retryPolicy: ProviderRetryPolicyConfiguration? = nil,
        maxSteps: Int = 8,
        maxOutputTokens: Int = 8_192
    ) {
        self.providerID = providerID
        self.profileID = profileID
        self.credentialReference = credentialReference
        self.baseURL = baseURL
        self.model = model
        self.inputModalities = inputModalities
        self.supportedReasoningModes = supportedReasoningModes
        self.reasoningWireStyle = reasoningWireStyle
        self.reasoningMode = reasoningMode
        self.openAIWireProfile = openAIWireProfile
        self.openAICompatibility = openAICompatibility
        self.retryPolicy = retryPolicy
        self.maxSteps = maxSteps
        self.maxOutputTokens = maxOutputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case profileID
        case credentialReference
        case baseURL
        case model
        case inputModalities
        case supportedReasoningModes
        case reasoningWireStyle
        case reasoningMode
        case openAIWireProfile
        case openAICompatibility
        case retryPolicy
        case maxSteps
        case maxOutputTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
            ?? Self.defaultBaseURL
        model = try container.decodeIfPresent(String.self, forKey: .model)
            ?? Self.defaultModel
        inputModalities = try container.decodeIfPresent(
            [ModelInputModality].self,
            forKey: .inputModalities
        )
        supportedReasoningModes = try container.decodeIfPresent(
            [ReasoningMode].self,
            forKey: .supportedReasoningModes
        )
        reasoningWireStyle = try container.decodeIfPresent(
            ModelReasoningWireStyle.self,
            forKey: .reasoningWireStyle
        )
        reasoningMode = try container.decodeIfPresent(ReasoningMode.self, forKey: .reasoningMode)
            ?? .high
        openAIWireProfile = try container.decodeIfPresent(
            OpenAICompatibleWireProfile.self,
            forKey: .openAIWireProfile
        )
        openAICompatibility = try container.decodeIfPresent(
            OpenAICompletionsCompatibility.self,
            forKey: .openAICompatibility
        )
        retryPolicy = try container.decodeIfPresent(
            ProviderRetryPolicyConfiguration.self,
            forKey: .retryPolicy
        )
        maxSteps = try container.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 8
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
            ?? 8_192
        profileID = try container.decodeIfPresent(String.self, forKey: .profileID)
        credentialReference = try container.decodeIfPresent(
            CredentialReference.self,
            forKey: .credentialReference
        )
        if let rawProvider = try container.decodeIfPresent(String.self, forKey: .providerID),
           let decodedProvider = ModelProviderID(rawValue: rawProvider) {
            providerID = decodedProvider
        } else {
            providerID = ModelProviderCatalog.inferredProviderID(baseURL: baseURL)
        }
    }

    func chatCompletionsURL() throws -> URL {
        try ModelProviderAdapterRegistry.adapter(for: providerID)
            .chatCompletionsURL(for: self)
    }

    func modelsURL() throws -> URL {
        let descriptor = ModelProviderCatalog.descriptor(for: providerID)
        guard descriptor.supportsRemoteModelDiscovery else {
            throw AgentConfigurationError.unsupportedModelDiscovery(providerID)
        }
        return try ModelProviderAdapterRegistry.adapter(for: providerID)
            .modelListURL(for: self)
    }

    func apiEndpointURL(
        appending endpointPath: String,
        replacingTrailingPath trailingPath: String? = nil
    ) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw AgentConfigurationError.invalidHTTPSURL
        }

        components.query = nil
        components.fragment = nil

        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }
        if let trailingPath {
            let normalizedTrailingPath = "/" + trailingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.hasSuffix(normalizedTrailingPath) {
                path.removeLast(normalizedTrailingPath.count)
            }
        }
        let normalizedEndpointPath = "/" + endpointPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.hasSuffix(normalizedEndpointPath) {
            path += normalizedEndpointPath
        }
        components.path = path

        guard let url = components.url else {
            throw AgentConfigurationError.invalidHTTPSURL
        }
        return url
    }

    func validated() throws -> AgentConfiguration {
        guard ModelProviderCatalog.descriptor(for: providerID).supportsCurrentInferenceWire else {
            throw AgentConfigurationError.unsupportedProviderWire(providerID)
        }
        _ = try chatCompletionsURL()
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentConfigurationError.emptyModel
        }
        if let inputModalities {
            guard !inputModalities.isEmpty,
                  inputModalities.contains(.text),
                  Set(inputModalities).count == inputModalities.count else {
                throw AgentConfigurationError.invalidInputModalities
            }
        }
        // Output capacity is a provider/model contract, not an app-level
        // throttle. Known models are resolved by ProviderProfile before this
        // point; an unlisted compatible model may still advertise a capacity
        // above the historic 65,536-token UI limit, so only reject values the
        // wire protocol cannot represent.
        guard maxOutputTokens >= 128 else {
            throw AgentConfigurationError.invalidMaxOutputTokens
        }
        let allowedReasoningModes = self.supportedReasoningModes
            ?? ReasoningMode.supportedModes(for: providerID)
        guard allowedReasoningModes.contains(reasoningMode) else {
            throw AgentConfigurationError.unsupportedReasoningMode(providerID, reasoningMode)
        }
        if ModelProviderCatalog.descriptor(for: providerID).wireProtocol != .openAIChatCompletions,
           (openAIWireProfile != nil || openAICompatibility != nil) {
            throw AgentConfigurationError.unsupportedWireCompatibility(providerID)
        }
        if let retryPolicy {
            _ = try ModelRetryPolicy.resolved(retryPolicy)
        }
        return self
    }

    func credentialOrigin() throws -> String {
        let endpoint = try chatCompletionsURL()
        guard let host = endpoint.host?.lowercased() else {
            throw AgentConfigurationError.invalidHTTPSURL
        }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        origin.port = endpoint.port ?? 443
        guard let value = origin.string else {
            throw AgentConfigurationError.invalidHTTPSURL
        }
        return value
    }

    var requiresDeepSeekReasoningReplay: Bool {
        guard reasoningMode != .providerDefault && reasoningMode != .off,
              let host = try? chatCompletionsURL().host?.lowercased() else {
            return false
        }
        return providerID == .deepSeekOfficial || host == "api.deepseek.com"
    }
}

enum ReasoningMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case providerDefault
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .providerDefault:
            return "Provider Default"
        case .off:
            return "Off"
        case .minimal:
            return "Minimal"
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .xhigh:
            return "XHigh"
        case .max:
            return "Max"
        }
    }

    static func supportedModes(for providerID: ModelProviderID) -> [ReasoningMode] {
        switch ModelProviderCatalog.descriptor(for: providerID).wireProtocol {
        case .anthropicMessages:
            return allCases
        case .openAIChatCompletions:
            return allCases
        }
    }
}

enum AgentConfigurationError: LocalizedError, Sendable {
    case invalidHTTPSURL
    case emptyModel
    case invalidInputModalities
    case invalidMaxOutputTokens
    case unsupportedProviderWire(ModelProviderID)
    case unsupportedModelDiscovery(ModelProviderID)
    case unsupportedReasoningMode(ModelProviderID, ReasoningMode)
    case unsupportedWireCompatibility(ModelProviderID)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPSURL:
            return "API URL must be a valid HTTPS URL."
        case .emptyModel:
            return "Model name cannot be empty."
        case .invalidInputModalities:
            return "Model input types must include text and cannot contain duplicates."
        case .invalidMaxOutputTokens:
            return "Max output tokens must be at least 128. Known models use the output limit declared by their API."
        case let .unsupportedProviderWire(providerID):
            let provider = ModelProviderCatalog.descriptor(for: providerID)
            return provider.compatibilityNotice
                ?? "This version does not yet implement the inference protocol for \(provider.displayName)."
        case let .unsupportedModelDiscovery(providerID):
            let provider = ModelProviderCatalog.descriptor(for: providerID)
            return "This version can't fetch the model list from \(provider.displayName). Use the built-in catalog or enter a model manually."
        case let .unsupportedReasoningMode(providerID, mode):
            let provider = ModelProviderCatalog.descriptor(for: providerID)
            return "\(provider.displayName) can't currently use the \(mode.title) thinking mode. Choose 'Provider Default' or 'Off'."
        case let .unsupportedWireCompatibility(providerID):
            let provider = ModelProviderCatalog.descriptor(for: providerID)
            return "\(provider.displayName) does not use the OpenAI Chat Completions compatibility settings."
        }
    }
}
