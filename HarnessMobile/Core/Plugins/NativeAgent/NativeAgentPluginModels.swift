import Foundation

struct NativeAgentPluginSourceFile: Codable, Sendable, Equatable {
    let path: String
    let content: String
    let truncated: Bool
}

struct NativeAgentPluginSourceSnapshot: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let failureReason: String
    let sourceDigest: String
    let source: ISHMarketplacePluginSource
    let packageName: String?
    let version: String?
    let description: String?
    let files: [NativeAgentPluginSourceFile]

    func validated() throws -> Self {
        guard schemaVersion == 1,
              Self.isDigest(sourceDigest),
              !failureReason.isEmpty,
              failureReason.utf8.count <= 128,
              !files.isEmpty,
              files.count <= 48 else {
            throw NativeAgentPluginError.invalidSourceSnapshot
        }
        var paths = Set<String>()
        var totalBytes = 0
        for file in files {
            guard Self.isSafeRelativePath(file.path),
                  paths.insert(file.path).inserted,
                  file.content.utf8.count <= 32 * 1_024 else {
                throw NativeAgentPluginError.invalidSourceSnapshot
            }
            totalBytes += file.content.utf8.count
        }
        guard totalBytes <= 180 * 1_024 else {
            throw NativeAgentPluginError.invalidSourceSnapshot
        }
        return self
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 512,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.split(separator: "/").contains("..") else { return false }
        return !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}

/// The production tools that a compiled native plugin may delegate to.
/// Developer plugins can use local execution and filesystem capabilities; only
/// recursive graph control and plugin installation stay outside this boundary.
enum NativeAgentPluginPolicy {
    /// Native plugins should see almost the complete production catalog. Keep
    /// the deny list explicit because these tools can create recursive work or
    /// install more plugins. Keep this mirrored with ProductionToolCatalog as
    /// new production tools are added.
    static let deniedBaseToolNames: Set<String> = [
        // These boundaries prevent a downloaded plugin from installing more
        // plugins or recursively controlling the parent Agent graph. All
        // ordinary production tools, including local code/shell/terminal/LSP
        // tools, remain available to developer-oriented native plugins.
        "plugin_marketplace",
        "ralph",
        "subagent",
        "subagent_control",
        "subagent_fork",
        "subagent_list",
        "workflow"
    ]

    private static let productionBaseToolNames: Set<String> = [
        "ask_user_question", "camera_ocr", "code_execute", "diagnostics_read",
        "device_time", "edit", "exit_plan_mode", "glob", "grep",
        "job_kill", "job_list", "job_output", "lsp", "schedule_create",
        "schedule_list", "schedule_delete", "read", "read_image", "ralph",
        "run_code", "session_event_get", "session_event_types", "session_search",
        "session_trace", "send_message", "shell_execute", "skill",
        "str_replace_editor", "subagent", "subagent_fork", "subagent_control",
        "subagent_list", "terminal_open", "terminal_read", "terminal_send",
        "terminal_signal", "terminal_list", "terminal_close", "web_fetch",
        "web_search", "browser_use", "workflow", "workspace_search",
        "workspace_diff", "deliverable_write", "work_state_replace_plan",
        "work_state_replace_todos", "work_state_set_goal", "write",
        "workspace_list_files", "workspace_read_text", "workspace_write_text",
        "plugin_marketplace"
    ]

    static let approvedBaseToolNames: Set<String> =
        productionBaseToolNames.union(MobileNativeToolKit.approvedNames)
            .subtracting(deniedBaseToolNames)

    private static let ishRuntimeToolNames: Set<String> = [
        "code_execute", "lsp", "run_code", "shell_execute",
        "terminal_close", "terminal_list", "terminal_open", "terminal_read",
        "terminal_send", "terminal_signal"
    ]

    static let executionBackendByToolName: [String: String] =
        Dictionary(uniqueKeysWithValues: approvedBaseToolNames.sorted().map { name in
            let backend: String
            if ishRuntimeToolNames.contains(name) {
                backend = "ish-runtime"
            } else if ["job_kill", "job_list", "job_output", "schedule_create", "schedule_delete", "schedule_list", "send_message"].contains(name) {
                backend = "swift-orchestration"
            } else {
                backend = "swift-native"
            }
            return (name, backend)
        })
}

/// The declarative compilation result authored either by the main Agent or by
/// the optional marketplace UI compiler. Signed Swift code remains the only
/// authority that can materialize and validate it as an installed plugin.
struct NativeAgentPluginManifestDraft: Codable, Sendable, Equatable {
    struct PromptSection: Codable, Sendable, Equatable {
        let order: Int
        let text: String
        let complete: Bool?
    }

    struct Tool: Codable, Sendable, Equatable {
        let name: String
        let description: String
        let parameters: JSONValue
        let risk: ToolRisk
        let instructions: String
        let allowedTools: [String]

        enum CodingKeys: String, CodingKey {
            case name
            case description
            case parameters
            case risk
            case instructions
            case allowedTools = "allowed_tools"
        }
    }

    struct PromptContext: Codable, Sendable, Equatable {
        let name: String
        let order: Int
        let source: NativeAgentPromptContextSource
        let path: String?
        let maximumCharacters: Int
        let prefix: String
        let suffix: String

        enum CodingKeys: String, CodingKey {
            case name
            case order
            case source
            case path
            case maximumCharacters = "maximum_characters"
            case prefix
            case suffix
        }
    }

    struct Settings: Codable, Sendable, Equatable {
        let schema: JSONValue
        let defaults: JSONValue
    }

    struct ToolGuard: Codable, Sendable, Equatable {
        let label: String
        let toolNames: [String]
        let risks: [ToolRisk]
        let decision: NativeAgentToolGuardDecision
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case label
            case toolNames = "tool_names"
            case risks
            case decision
            case reason
        }
    }

    let adaptable: Bool
    let reason: String?
    let name: String
    let description: String?
    let promptSections: [PromptSection]
    let promptContexts: [PromptContext]?
    let settings: Settings?
    let tools: [Tool]
    let toolGuards: [ToolGuard]?
    let compatibilityNotes: [String]

    enum CodingKeys: String, CodingKey {
        case adaptable
        case reason
        case name
        case description
        case promptSections = "prompt_sections"
        case promptContexts = "prompt_contexts"
        case settings
        case tools
        case toolGuards = "tool_guards"
        case compatibilityNotes = "compatibility_notes"
    }
}

struct NativeAgentPromptSection: Codable, Sendable, Equatable {
    let order: Int
    let text: String
    let complete: Bool?

    init(order: Int, text: String, complete: Bool? = nil) {
        self.order = order
        self.text = text
        self.complete = complete
    }
}

enum NativeAgentPromptContextSource: String, Codable, Sendable, Equatable {
    case file
    case conversation
    case settings
}

struct NativeAgentPromptContext: Codable, Sendable, Equatable {
    let name: String
    let order: Int
    let source: NativeAgentPromptContextSource
    let path: String?
    let maximumCharacters: Int
    let prefix: String
    let suffix: String
}

struct NativeAgentPluginSettings: Codable, Sendable, Equatable {
    let schema: JSONValue
    let defaults: JSONValue
    var values: JSONValue
}

enum NativeAgentToolGuardDecision: String, Codable, Sendable, Equatable {
    case allow
    case ask
    case deny
}

struct NativeAgentToolGuard: Codable, Sendable, Equatable {
    let label: String
    let toolNames: [String]
    let risks: [ToolRisk]
    let decision: NativeAgentToolGuardDecision
    let reason: String?
}

struct NativeAgentCompiledTool: Codable, Sendable, Equatable, Identifiable {
    var id: String { name }

    let name: String
    let description: String
    let parameters: JSONValue
    let risk: ToolRisk
    let instructions: String
    let allowedTools: [String]
}

struct NativeAgentCompiledPlugin: Codable, Sendable, Equatable, Identifiable {
    static let schemaVersion = 1
    static let idPrefix = "native-agent."

    let schemaVersion: Int
    let id: String
    let name: String
    let version: String
    let description: String?
    let source: ISHMarketplacePluginSource
    let sourceDigest: String
    let compiledAt: Date
    let compilerProviderID: String
    let compilerModel: String
    var enabled: Bool
    let promptSections: [NativeAgentPromptSection]
    let promptContexts: [NativeAgentPromptContext]
    var settings: NativeAgentPluginSettings?
    let tools: [NativeAgentCompiledTool]
    let toolGuards: [NativeAgentToolGuard]
    let compatibilityNotes: [String]

    init(
        schemaVersion: Int,
        id: String,
        name: String,
        version: String,
        description: String?,
        source: ISHMarketplacePluginSource,
        sourceDigest: String,
        compiledAt: Date,
        compilerProviderID: String,
        compilerModel: String,
        enabled: Bool,
        promptSections: [NativeAgentPromptSection],
        promptContexts: [NativeAgentPromptContext] = [],
        settings: NativeAgentPluginSettings? = nil,
        tools: [NativeAgentCompiledTool],
        toolGuards: [NativeAgentToolGuard] = [],
        compatibilityNotes: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.source = source
        self.sourceDigest = sourceDigest
        self.compiledAt = compiledAt
        self.compilerProviderID = compilerProviderID
        self.compilerModel = compilerModel
        self.enabled = enabled
        self.promptSections = promptSections
        self.promptContexts = promptContexts
        self.settings = settings
        self.tools = tools
        self.toolGuards = toolGuards
        self.compatibilityNotes = compatibilityNotes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case version
        case description
        case source
        case sourceDigest
        case compiledAt
        case compilerProviderID
        case compilerModel
        case enabled
        case promptSections
        case promptContexts
        case settings
        case tools
        case toolGuards
        case compatibilityNotes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            version: try container.decode(String.self, forKey: .version),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            source: try container.decode(ISHMarketplacePluginSource.self, forKey: .source),
            sourceDigest: try container.decode(String.self, forKey: .sourceDigest),
            compiledAt: try container.decode(Date.self, forKey: .compiledAt),
            compilerProviderID: try container.decode(String.self, forKey: .compilerProviderID),
            compilerModel: try container.decode(String.self, forKey: .compilerModel),
            enabled: try container.decode(Bool.self, forKey: .enabled),
            promptSections: try container.decode(
                [NativeAgentPromptSection].self,
                forKey: .promptSections
            ),
            promptContexts: try container.decodeIfPresent(
                [NativeAgentPromptContext].self,
                forKey: .promptContexts
            ) ?? [],
            settings: try container.decodeIfPresent(
                NativeAgentPluginSettings.self,
                forKey: .settings
            ),
            tools: try container.decode([NativeAgentCompiledTool].self, forKey: .tools),
            toolGuards: try container.decodeIfPresent(
                [NativeAgentToolGuard].self,
                forKey: .toolGuards
            ) ?? [],
            compatibilityNotes: try container.decode(
                [String].self,
                forKey: .compatibilityNotes
            )
        )
    }

    func validated(allowedBaseTools: Set<String>) throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              id.hasPrefix(Self.idPrefix),
              Self.isIdentifier(id, maximumBytes: 120),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 214,
              version.utf8.count <= 80,
              sourceDigest.utf8.count == 64,
              sourceDigest.allSatisfy(\.isHexDigit),
              compilerProviderID.utf8.count <= 128,
              compilerModel.utf8.count <= 256,
              (description?.utf8.count ?? 0) <= 1_000,
              promptSections.count <= 8,
              promptContexts.count <= 12,
              tools.count <= 16,
              toolGuards.count <= 16,
              !promptSections.isEmpty || !promptContexts.isEmpty || !tools.isEmpty
                || !toolGuards.isEmpty,
              compatibilityNotes.count <= 16 else {
            throw NativeAgentPluginError.invalidCompiledPlugin("Plugin metadata is invalid.")
        }
        if let description {
            try Self.validateCredentialSafety(.string(description), field: "description")
        }

        var totalTextBytes = 0
        guard promptSections.count(where: { $0.complete == true }) <= 1 else {
            throw NativeAgentPluginError.invalidCompiledPlugin(
                "prompt_sections can have at most one complete=true; set the other sections to complete=false or merge them into a single complete section."
            )
        }
        for (index, section) in promptSections.enumerated() {
            guard (-10_000...10_000).contains(section.order),
                  !section.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  section.text.utf8.count <= 24 * 1_024 else {
                throw NativeAgentPluginError.invalidCompiledPlugin(
                    "prompt_sections[\(index)] is invalid: order must be within -10000..10000, and text must be non-empty and no more than 24576 UTF-8 bytes."
                )
            }
            try Self.validateCredentialSafety(
                .string(section.text),
                field: "prompt_sections[\(index)].text"
            )
            totalTextBytes += section.text.utf8.count
        }

        var contextNames = Set<String>()
        for (index, context) in promptContexts.enumerated() {
            guard contextNames.insert(context.name).inserted else {
                throw NativeAgentPluginError.invalidCompiledPlugin(
                    "prompt_contexts[\(index)].name duplicates an earlier context."
                )
            }
            guard Self.isContributionName(context.name),
                  (-10_000...10_000).contains(context.order),
                  (1...32_768).contains(context.maximumCharacters),
                  context.prefix.utf8.count <= 8 * 1_024,
                  context.suffix.utf8.count <= 8 * 1_024 else {
                throw NativeAgentPluginError.invalidCompiledPlugin(
                    "prompt_contexts[\(index)] is invalid: name/order/maximum_characters or prefix/suffix length violates constraints."
                )
            }
            switch context.source {
            case .file:
                guard let path = context.path,
                      Self.isPrivateContextPath(path) else {
                    throw Self.invalidPromptContextPath(index, path: context.path)
                }
            case .conversation, .settings:
                guard context.path == nil else {
                    throw NativeAgentPluginError.invalidCompiledPlugin(
                        "Non-file contexts cannot declare path."
                    )
                }
            }
            try Self.validateCredentialSafety(
                .string(context.prefix),
                field: "prompt_contexts[\(index)].prefix"
            )
            try Self.validateCredentialSafety(
                .string(context.suffix),
                field: "prompt_contexts[\(index)].suffix"
            )
            totalTextBytes += context.prefix.utf8.count + context.suffix.utf8.count
        }

        if let settings {
            guard case let .object(schema) = settings.schema,
                  schema["type"] == .string("object"),
                  case .object = settings.defaults,
                  case .object = settings.values,
                  try JSONEncoder().encode(settings.schema).count <= 32 * 1_024,
                  try JSONEncoder().encode(settings.defaults).count <= 32 * 1_024,
                  try JSONEncoder().encode(settings.values).count <= 32 * 1_024 else {
                throw NativeAgentPluginError.invalidCompiledPlugin(
                    "settings is invalid: schema/defaults/values must be objects, and each must encode to no more than 32768 bytes."
                )
            }
            try NativeAgentJSONSchemaValidator.validate(
                value: settings.defaults,
                schema: settings.schema
            )
            try NativeAgentJSONSchemaValidator.validate(
                value: settings.values,
                schema: settings.schema
            )
            try Self.validateCredentialSafety(settings.defaults, field: "settings.defaults")
            try Self.validateCredentialSafety(settings.values, field: "settings.values")
        }

        var names = Set<String>()
        for (index, tool) in tools.enumerated() {
            guard names.insert(tool.name).inserted else {
                throw NativeAgentPluginError.invalidCompiledPlugin(
                    "tools[\(index)].name duplicates an earlier tool."
                )
            }
            guard Self.isToolName(tool.name) else {
                throw NativeAgentPluginError.invalidCompiledPlugin(
                    "tools[\(index)].name is invalid: it must start with a lowercase letter, contain only lowercase letters, digits, hyphens, or underscores, and be at most 64 bytes."
                )
            }
            guard !allowedBaseTools.contains(tool.name) else {
                throw NativeAgentPluginError.invalidCompiledPlugin(
                    "tools[\(index)].name cannot override a built-in native tool; use a plugin-specific lowercase name instead."
                )
            }
            guard !tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  tool.description.utf8.count <= 1_024 else {
                throw NativeAgentPluginError.invalidCompiledPlugin(
                    "tools[\(index)].description must be non-empty and no more than 1024 UTF-8 bytes."
                )
            }
            guard tool.instructions.utf8.count <= 24 * 1_024,
                  !tool.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NativeAgentPluginError.invalidCompiledPlugin(
                    "tools[\(index)].instructions must be non-empty and no more than 24576 UTF-8 bytes."
                )
            }
            guard Set(tool.allowedTools).count == tool.allowedTools.count,
                  tool.allowedTools.count <= 24 else {
                throw NativeAgentPluginError.invalidCompiledPlugin(
                    "tools[\(index)].allowed_tools must not contain duplicates and may have at most 24 entries."
                )
            }
            let unsupportedAllowedTools = tool.allowedTools.filter {
                !allowedBaseTools.contains($0)
            }
            guard unsupportedAllowedTools.isEmpty else {
                let safeNames = unsupportedAllowedTools
                    .filter(Self.isToolName)
                    .prefix(8)
                    .joined(separator: ", ")
                let suffix = safeNames.isEmpty ? "" : " (for example: \(safeNames))"
                throw NativeAgentPluginError.invalidCompiledPlugin(
                    "tools[\(index)].allowed_tools contains unapproved native tools\(suffix); only the allowed_native_tools returned by install may be used. Remove or replace the unapproved names."
                )
            }
            guard case let .object(schema) = tool.parameters,
                  schema["type"] == .string("object") else {
                throw NativeAgentPluginError.invalidCompiledPlugin(
                    "tools[\(index)].parameters must be a JSON Schema with type=object."
                )
            }
            let schemaBytes = try JSONEncoder().encode(tool.parameters).count
            guard schemaBytes <= 32 * 1_024 else {
                throw NativeAgentPluginError.invalidCompiledPlugin(
                    "tools[\(index)].parameters schema exceeds 32768 bytes when encoded."
                )
            }
            try Self.validateCredentialSafety(
                tool.parameters,
                field: "tools[\(index)].parameters"
            )
            try Self.validateCredentialSafety(
                .string(tool.instructions),
                field: "tools[\(index)].instructions"
            )
            try Self.validatePrivateStorageInstructions(tool)
            totalTextBytes += tool.description.utf8.count + tool.instructions.utf8.count
        }

        var guardLabels = Set<String>()
        for (index, guardRule) in toolGuards.enumerated() {
            guard guardLabels.insert(guardRule.label).inserted else {
                throw Self.invalidToolGuard(index, "label duplicates another guard: \(guardRule.label)")
            }
            // Labels are human-readable trace text, not contribution identifiers. The
            // public manifest schema deliberately accepts localized labels with spaces.
            guard Self.isToolGuardLabel(guardRule.label) else {
                throw Self.invalidToolGuard(
                    index,
                    "label must be non-empty text after trimming whitespace (at most 96 UTF-8 bytes, with no control characters)"
                )
            }
            guard guardRule.toolNames.count <= 32 else {
                throw Self.invalidToolGuard(index, "tool_names may have at most 32 entries")
            }
            guard Set(guardRule.toolNames).count == guardRule.toolNames.count else {
                throw Self.invalidToolGuard(index, "tool_names must not contain duplicate tool names")
            }
            guard guardRule.risks.count <= 5 else {
                throw Self.invalidToolGuard(index, "risks may have at most 5 entries")
            }
            guard Set(guardRule.risks).count == guardRule.risks.count else {
                throw Self.invalidToolGuard(index, "risks must not contain duplicate risk levels")
            }
            guard !guardRule.toolNames.isEmpty || !guardRule.risks.isEmpty else {
                throw Self.invalidToolGuard(index, "at least one of tool_names or risks is required")
            }
            guard guardRule.toolNames.allSatisfy({ $0 == "*" || Self.isToolName($0) }) else {
                throw Self.invalidToolGuard(
                    index,
                    "tool_names may only contain declared lowercase tool names, hyphens/underscores, or the wildcard *"
                )
            }
            guard (guardRule.reason?.utf8.count ?? 0) <= 2_048 else {
                throw Self.invalidToolGuard(index, "reason may be at most 2048 UTF-8 bytes")
            }
            if guardRule.decision == .deny {
                guard let reason = guardRule.reason?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !reason.isEmpty else {
                    throw NativeAgentPluginError.invalidCompiledPlugin(
                        "deny tool policies must provide a reason."
                    )
                }
                try Self.validateCredentialSafety(
                    .string(reason),
                    field: "tool_guards[\(index)].reason"
                )
            }
        }
        guard totalTextBytes <= 128 * 1_024,
              compatibilityNotes.allSatisfy({ $0.utf8.count <= 1_024 }) else {
            throw NativeAgentPluginError.invalidCompiledPlugin(
                "Native plugin content is too large: prompt/tool text may total at most 131072 UTF-8 bytes, and each compatibility_notes entry at most 1024 bytes."
            )
        }
        for (index, note) in compatibilityNotes.enumerated() {
            try Self.validateCredentialSafety(
                .string(note),
                field: "compatibility_notes[\(index)]"
            )
        }
        return self
    }

    private static func validateCredentialSafety(
        _ value: JSONValue,
        field: String
    ) throws {
        do {
            try ISHPluginHostCredentialFirewall.validate(value)
        } catch {
            throw NativeAgentPluginError.invalidCompiledPlugin(
                "\(field) contains a suspected credential or sensitive field; remove real tokens/keys and keep only descriptive text about redacted categories."
            )
        }
    }

    private static func validatePrivateStorageInstructions(
        _ tool: NativeAgentCompiledTool
    ) throws {
        let allowed = Set(tool.allowedTools)
        guard allowed.contains("workspace_list_files"),
              !allowed.isDisjoint(with: ["workspace_read_text", "read"]) else { return }

        let text = tool.instructions.lowercased()
        let mentionsPrivatePath = [
            ".harness-mobile", "native-agent-plugins", "<plugin-id>"
        ].contains { text.contains($0) }
        let mentionsListing = [
            "workspace_list_files", "list files", "file listing", "enumerate",
            "列出", "枚举", "文件列表"
        ].contains { text.contains($0) }
        let mentionsMembershipGate = [
            "contains", "if present", "if found", "exists", "existence",
            "列表中", "存在后", "找到后", "发现后"
        ].contains { text.contains($0) }
        let explicitlyForbidsGate = [
            "never use", "do not use", "must not", "禁止", "不要使用", "不得"
        ].contains { text.contains($0) }

        guard mentionsPrivatePath,
              mentionsListing,
              mentionsMembershipGate,
              !explicitlyForbidsGate else { return }
        throw NativeAgentPluginError.invalidCompiledPlugin(
            "Tool \(tool.name) gates reading hidden plugin state behind a file listing/contains/exists check; workspace_list_files does not return dot-prefixed paths. Read `.harness-mobile/native-agent-plugins/<plugin-id>/<filename>` directly, treat not-found as the initial empty state, and remove the unneeded workspace_list_files from allowed_tools."
        )
    }

    var marketplaceProjection: ISHMarketplacePlugin {
        let timestamp = compiledAt.formatted(.iso8601)
        return ISHMarketplacePlugin(
            id: id,
            name: name,
            version: version,
            description: description,
            license: nil,
            source: source,
            enabled: enabled,
            state: enabled ? .enabled : .disabled,
            installedAt: timestamp,
            updatedAt: timestamp,
            entryCount: tools.count + promptSections.count + promptContexts.count
                + toolGuards.count + (settings == nil ? 0 : 1),
            lastError: nil
        )
    }

    static func makeID(packageName: String?, sourceDigest: String) -> String {
        let source = packageName ?? "plugin-\(sourceDigest.prefix(12))"
        var normalized = source
            .lowercased()
            .replacingOccurrences(of: "@", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .unicodeScalars
            .map { scalar -> Character in
                if CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "-" || scalar == "_" || scalar == "." {
                    return Character(scalar)
                }
                return "-"
            }
        while normalized.first == "-" { normalized.removeFirst() }
        while normalized.last == "-" { normalized.removeLast() }
        let suffix = String(normalized.prefix(88))
        return Self.idPrefix + (suffix.isEmpty ? String(sourceDigest.prefix(12)) : suffix)
    }

    private static func isIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        guard let first = value.utf8.first,
              value.utf8.count <= maximumBytes,
              isASCIIAlphaNumeric(first) else { return false }
        return value.utf8.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F
        }
    }

    private static func isToolName(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              value.utf8.count <= 64,
              (0x61...0x7A).contains(first) else { return false }
        return value.utf8.dropFirst().allSatisfy {
            (0x61...0x7A).contains($0)
                || (0x30...0x39).contains($0)
                || $0 == 0x2D
                || $0 == 0x5F
        }
    }

    private static func isContributionName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 96 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-" || scalar == "_" || scalar == "." || scalar == ":"
        }
    }

    private static func isToolGuardLabel(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 96
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func invalidToolGuard(
        _ index: Int,
        _ reason: String
    ) -> NativeAgentPluginError {
        .invalidCompiledPlugin("tool_guards[\(index)] is invalid: \(reason).")
    }

    private static func invalidPromptContextPath(
        _ index: Int,
        path: String?
    ) -> NativeAgentPluginError {
        let actual = path.map { String(reflecting: $0) } ?? "<missing>"
        return .invalidCompiledPlugin(
            "prompt_contexts[\(index)].path is invalid: \(actual). source=file may only use the exact private path templates `<plugin-storage>/<filename>`, `<session-storage>/<filename>`, or `.harness-mobile/native-agent-plugins/<plugin-id>/<filename>`; source repository paths (e.g. `skills/memory.md`) are not mounted at runtime."
        )
    }

    private static func isPrivateContextPath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 512,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.split(separator: "/").contains(".."),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return false }
        return value.hasPrefix("<plugin-storage>/")
            || value.hasPrefix("<session-storage>/")
            || value.hasPrefix(".harness-mobile/native-agent-plugins/<plugin-id>/")
    }

    private static func isASCIIAlphaNumeric(_ value: UInt8) -> Bool {
        (0x30...0x39).contains(value)
            || (0x41...0x5A).contains(value)
            || (0x61...0x7A).contains(value)
    }
}

enum NativeAgentPluginError: LocalizedError, Sendable, Equatable {
    case invalidSourceSnapshot
    case sourceNotAdaptable(String)
    case compilerDidNotReturnManifest
    case invalidCompiledPlugin(String)
    case alreadyInstalled(String)
    case notFound(String)
    case noExecutionResult

    var errorDescription: String? {
        switch self {
        case .invalidSourceSnapshot:
            "The plugin source snapshot is incomplete and cannot be handed to the phone Agent for compilation."
        case let .sourceNotAdaptable(reason):
            "The phone Agent cannot convert this plugin into native tools: \(reason)"
        case .compilerDidNotReturnManifest:
            "The phone Agent did not return a valid native plugin manifest."
        case let .invalidCompiledPlugin(reason):
            "The native plugin generated by the phone Agent failed validation: \(reason)"
        case let .alreadyInstalled(id):
            "Native plugin \(id) is already installed; updating requires replace=true."
        case let .notFound(id):
            "Native plugin \(id) not found."
        case .noExecutionResult:
            "The native plugin subagent returned no result."
        }
    }
}

/// Small machine-readable facts that the parent Agent can use to repair and
/// retry a native manifest. The full compilation trace stays in diagnostics.
struct NativeAgentCompilationDiagnostic: Codable, Sendable, Equatable {
    let code: String
    let stage: String
    let message: String
    let retryable: Bool
    let preparedToken: String?
    let suggestedAction: String

    init(
        code: String,
        stage: String,
        message: String,
        retryable: Bool,
        preparedToken: String? = nil,
        suggestedAction: String
    ) {
        self.code = code
        self.stage = stage
        self.message = message
        self.retryable = retryable
        self.preparedToken = preparedToken
        self.suggestedAction = suggestedAction
    }
}

extension NativeAgentPluginError {
    var shouldFallbackToISH: Bool {
        switch self {
        case .sourceNotAdaptable:
            true
        case .invalidSourceSnapshot, .compilerDidNotReturnManifest, .invalidCompiledPlugin,
             .alreadyInstalled, .notFound, .noExecutionResult:
            false
        }
    }
}

extension ISHPluginHostError {
    var nativeAgentCompilationCandidate: NativeAgentPluginSourceSnapshot? {
        guard case let .remote(code, _, data) = self,
              code == -32_010,
              let candidate = data?.objectValue?["nativeCandidate"] else { return nil }
        do {
            let encoded = try JSONEncoder().encode(candidate)
            return try JSONDecoder()
                .decode(NativeAgentPluginSourceSnapshot.self, from: encoded)
                .validated()
        } catch {
            return nil
        }
    }
}
