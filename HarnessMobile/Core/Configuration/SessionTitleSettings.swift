import Foundation

enum SessionTitleAutomaticMode: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case disabled
    case firstPrompt
    case allPrompts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: return "Local Titles Only"
        case .firstPrompt: return "Generate After First Prompt"
        case .allPrompts: return "Update After Every Prompt"
        }
    }
}

struct SessionTitleSettings: Codable, Sendable, Equatable {
    var automaticMode: SessionTitleAutomaticMode
    var route: CompactionSummaryRoute?

    init(
        automaticMode: SessionTitleAutomaticMode = .disabled,
        route: CompactionSummaryRoute? = nil
    ) {
        self.automaticMode = automaticMode
        self.route = route
    }

    func validated(in directory: ProviderProfileDirectory) throws -> Self {
        var copy = self
        copy.route = try route?.validated(in: directory)
        return copy
    }

    func configuration(
        inheriting fallback: AgentConfiguration,
        in directory: ProviderProfileDirectory
    ) throws -> AgentConfiguration {
        var configuration = try route?.configuration(in: directory) ?? fallback.validated()
        configuration.maxOutputTokens = 128
        configuration.reasoningMode = ReasoningMode.supportedModes(for: configuration.providerID)
            .contains(.off) ? .off : .providerDefault
        return try configuration.validated()
    }
}

enum SessionTitleGeneratorError: LocalizedError, Equatable {
    case noMessages
    case inputTooLarge
    case outputTooLarge
    case emptyOutput
    case unexpectedToolCall
    case incompleteFinish
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noMessages: return "No user messages available to generate a title."
        case .inputTooLarge: return "Title generation input exceeds 64 KiB."
        case .outputTooLarge: return "Title model output exceeds 1 KiB."
        case .emptyOutput: return "Title model returned an empty title."
        case .unexpectedToolCall: return "Title model unexpectedly requested a tool."
        case .incompleteFinish: return "Title model did not finish its output normally."
        case .timedOut: return "Title model did not finish within 15 seconds."
        }
    }
}

enum SessionTitleGenerator {
    static let maximumInputBytes = 64 * 1_024
    static let maximumOutputBytes = 1_024

    static func selectedMessages(
        from messages: [AgentMessage],
        mode: SessionTitleAutomaticMode
    ) throws -> [AgentMessage] {
        let userMessages = messages.filter { $0.role == .user && !$0.isHiddenContextMessage }
        guard !userMessages.isEmpty else { throw SessionTitleGeneratorError.noMessages }
        switch mode {
        case .disabled:
            throw SessionTitleGeneratorError.noMessages
        case .firstPrompt:
            return [userMessages[0]]
        case .allPrompts:
            return userMessages
        }
    }

    static func providerID(for mode: SessionTitleAutomaticMode) -> String {
        switch mode {
        case .firstPrompt:
            return "@deepseek-ai/dsh-session-title-first-prompt-llm"
        case .disabled, .allPrompts:
            return "@deepseek-ai/dsh-session-title-all-prompts-llm"
        }
    }

    static func generate(
        client: any LLMStreamingClient,
        configuration: AgentConfiguration,
        apiKey: String,
        messages: [AgentMessage]
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await generateStream(
                    client: client,
                    configuration: configuration,
                    apiKey: apiKey,
                    messages: messages
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw SessionTitleGeneratorError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw SessionTitleGeneratorError.emptyOutput
            }
            return result
        }
    }

    private static func generateStream(
        client: any LLMStreamingClient,
        configuration: AgentConfiguration,
        apiKey: String,
        messages: [AgentMessage]
    ) async throws -> String {
        let framed = messages.map { message in
            ["id": message.id.uuidString, "text": message.content]
        }
        let inputData = try JSONSerialization.data(withJSONObject: framed, options: [.sortedKeys])
        guard inputData.count <= maximumInputBytes else {
            throw SessionTitleGeneratorError.inputTooLarge
        }
        let input = "Generate the session title from this JSON array of human messages:\n"
            + String(decoding: inputData, as: UTF8.self)
        let system = [
            "Create a concise title for an AI coding-assistant session from the supplied human messages.",
            "Return only the title on one line, in plain natural-language text, with no quotes, prefix, explanation, Markdown, XML, terminal control codes, or code.",
            "Use the language of the messages. Aim for about 6 words in non-CJK languages or 12 CJK characters."
        ].joined(separator: "\n")
        let request = ModelRequest(
            configuration: configuration,
            apiKey: apiKey,
            systemPrompt: system,
            messages: [.user(input)],
            tools: [],
            purpose: "session-title"
        )
        var output = ""
        var finish: ModelFinishReason?
        for try await event in client.stream(request) {
            try Task.checkCancellation()
            switch event {
            case let .text(text):
                output += text
                guard output.utf8.count <= maximumOutputBytes else {
                    throw SessionTitleGeneratorError.outputTooLarge
                }
            case .reasoning, .reasoningSignature, .usage:
                continue
            case .toolCallDelta:
                throw SessionTitleGeneratorError.unexpectedToolCall
            case let .finish(reason):
                finish = reason
            }
        }
        guard finish == .stop else { throw SessionTitleGeneratorError.incompleteFinish }
        let normalized = normalize(output)
        guard !normalized.isEmpty else { throw SessionTitleGeneratorError.emptyOutput }
        return String(normalized.prefix(80))
    }

    static func normalize(_ value: String) -> String {
        let firstLine = value
            .replacingOccurrences(of: "\u{0000}", with: "")
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        return firstLine
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "\"'`")
            ))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
