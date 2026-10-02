import Foundation

struct HarnessBrowserTool: LocalAgentTool {
    let risk: ToolRisk = .sensitiveRead

    private let service: HarnessBrowserService
    private let sessionID: String

    var definition: ModelToolDefinition {
        ModelToolDefinition(
            name: "browser_use",
            description: "Use the isolated on-device browser for bounded navigation, readable text, screenshots, and tab management. Each conversation has at most three tabs; arbitrary JavaScript, cookies, credentials, headers, and remote executors are not available.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array(HarnessBrowserAction.allCases.map { .string($0.rawValue) })
                    ]),
                    "tab_id": .object([
                        "type": .string("string"),
                        "description": .string("Existing tab UUID for navigate/read_text/screenshot/close.")
                    ]),
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("HTTP or HTTPS URL without embedded credentials; required for open/navigate.")
                    ])
                ]),
                "required": .array([.string("action")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    init(service: HarnessBrowserService = .shared, sessionID: String) {
        self.service = service
        self.sessionID = sessionID
    }

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["action", "tab_id", "url"])
        let action = try parseAction(arguments)
        let tabID = try parseTabID(arguments)
        let url = try parseURL(arguments)
        switch action {
        case .open:
            guard tabID == nil, url != nil else { throw HarnessBrowserServiceError.invalidAction }
        case .navigate:
            guard tabID != nil, url != nil else { throw HarnessBrowserServiceError.invalidAction }
        case .readText, .screenshot, .close:
            guard tabID != nil, url == nil else { throw HarnessBrowserServiceError.invalidAction }
        case .listTabs:
            guard tabID == nil, url == nil else { throw HarnessBrowserServiceError.invalidAction }
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        guard let action = try? parseAction(arguments) else { return "Use the local isolated browser" }
        switch action {
        case .open, .navigate: return "Navigate in the local isolated browser"
        case .readText: return "Read local browser page text"
        case .screenshot: return "Capture a local browser page screenshot"
        case .close: return "Close a local browser tab"
        case .listTabs: return "List browser tabs for the current session"
        }
    }

    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool {
        try validate(arguments: arguments)
        return false
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        try validate(arguments: arguments)
        let tab = arguments["tab_id"]?.stringValue ?? "pool"
        return ["browser:session:\(sessionID):\(tab)"]
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        try validate(arguments: arguments)
        return ["browser:session:\(sessionID)"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let action = try parseAction(arguments)
        let tabID = try parseTabID(arguments)
        let url = try parseURL(arguments)
        let result = try await service.execute(
            sessionID: sessionID,
            action: action,
            tabID: tabID,
            url: url
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(result), as: UTF8.self)
    }

    private func parseAction(_ arguments: [String: JSONValue]) throws -> HarnessBrowserAction {
        guard let raw = arguments["action"]?.stringValue,
              let action = HarnessBrowserAction(rawValue: raw) else {
            throw HarnessBrowserServiceError.invalidAction
        }
        return action
    }

    private func parseTabID(_ arguments: [String: JSONValue]) throws -> UUID? {
        guard let raw = arguments["tab_id"]?.stringValue else { return nil }
        guard let id = UUID(uuidString: raw) else { throw HarnessBrowserServiceError.tabNotFound }
        return id
    }

    private func parseURL(_ arguments: [String: JSONValue]) throws -> URL? {
        guard let raw = arguments["url"]?.stringValue else { return nil }
        guard let url = URL(string: raw) else { throw HarnessBrowserServiceError.invalidURL }
        return url
    }
}

private extension HarnessBrowserAction {
    static let allCases: [HarnessBrowserAction] = [.open, .navigate, .readText, .screenshot, .close, .listTabs]
}
