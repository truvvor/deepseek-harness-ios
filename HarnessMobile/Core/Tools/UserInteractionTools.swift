import Foundation

// MARK: - User questions

/// A selectable answer offered by `ask_user_question`.
struct AskUserQuestionOption: Codable, Sendable, Equatable {
    let label: String
    let description: String?

    init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

/// A presentation hint. It changes the native card, never the answer wire format.
struct AskUserQuestionIntent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, Equatable {
        case planReview = "plan-review"
    }

    let kind: Kind
    let approve: String

    init(kind: Kind = .planReview, approve: String) {
        self.kind = kind
        self.approve = approve
    }
}

/// One model-authored question. `detail` is used by plan review to carry the
/// markdown body without putting it in a button label.
struct AskUserQuestionItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let question: String
    let detail: String?
    let header: String?
    let options: [AskUserQuestionOption]?
    let multiSelect: Bool
    let intent: AskUserQuestionIntent?

    init(
        id: String,
        question: String,
        detail: String? = nil,
        header: String? = nil,
        options: [AskUserQuestionOption]? = nil,
        multiSelect: Bool = false,
        intent: AskUserQuestionIntent? = nil
    ) {
        self.id = id
        self.question = question
        self.detail = detail
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
        self.intent = intent
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case question
        case detail
        case header
        case options
        case multiSelect = "multi_select"
        case intent
    }
}

/// A request shown by the native question surface.
struct AskUserQuestionRequest: Sendable, Equatable {
    let id: UUID
    let questions: [AskUserQuestionItem]

    init(id: UUID = UUID(), questions: [AskUserQuestionItem]) {
        self.id = id
        self.questions = questions
    }
}

/// A request narrowed to the dedicated plan-review presentation. The option
/// labels remain the caller's exact wire values; only the native layout changes.
struct PlanReviewPresentation: Sendable, Equatable {
    let id: String
    let question: String
    let plan: String
    let approve: AskUserQuestionOption
    let decline: AskUserQuestionOption?

    init?(request: AskUserQuestionRequest) {
        guard request.questions.count == 1,
              let question = request.questions.first,
              let intent = question.intent,
              intent.kind == .planReview,
              let plan = question.detail,
              !question.multiSelect else {
            return nil
        }

        let options = question.options ?? []
        guard options.count <= 2,
              let approve = options.first(where: { $0.label == intent.approve }) else {
            return nil
        }

        self.id = question.id
        self.question = question.question
        self.plan = plan
        self.approve = approve
        self.decline = options.first(where: { $0.label != intent.approve })
    }
}

/// One answer returned by the native surface. `custom` supplements a
/// multi-select and replaces the selection for a single-select question.
struct AskUserQuestionAnswerItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let selected: [String]
    let custom: String?

    init(id: String, selected: [String] = [], custom: String? = nil) {
        self.id = id
        self.selected = selected
        self.custom = custom
    }

    /// Skip deliberately reuses the upstream blank selection wire shape.
    var isSkipped: Bool {
        selected.isEmpty && custom == nil
    }
}

struct AskUserQuestionAnswer: Codable, Sendable, Equatable {
    let answers: [AskUserQuestionAnswerItem]

    init(answers: [AskUserQuestionAnswerItem]) {
        self.answers = answers
    }
}

/// Stable errors used by the question seam. The codes mirror the upstream
/// service so a tool result can be handled consistently by the model.
enum UserQuestionError: LocalizedError, Sendable, Equatable {
    case duplicateProvider
    case noProvider
    case emptyQuestions
    case badIntent(String)
    case invalidRequest(String)
    case invalidAnswer(String)
    case busy
    case requestNotFound
    case cancelled

    var code: String {
        switch self {
        case .duplicateProvider: "DUPLICATE_PROVIDER"
        case .noProvider: "NO_PROVIDER"
        case .emptyQuestions: "EMPTY_QUESTIONS"
        case .badIntent: "BAD_INTENT"
        case .invalidRequest: "INVALID_REQUEST"
        case .invalidAnswer: "INVALID_ANSWER"
        case .busy: "BUSY"
        case .requestNotFound: "REQUEST_NOT_FOUND"
        case .cancelled: "ASK_CANCELLED"
        }
    }

    var errorDescription: String? {
        switch self {
        case .duplicateProvider:
            return "This local session already has a user question interface registered."
        case .noProvider:
            return "No local user question interface is available."
        case .emptyQuestions:
            return "ask_user_question requires at least one question."
        case let .badIntent(message):
            return "Invalid user question intent: " + message
        case let .invalidRequest(message):
            return "Invalid user question arguments: " + message
        case let .invalidAnswer(message):
            return "Invalid user question answer: " + message
        case .busy:
            return "A user question is already awaiting an answer."
        case .requestNotFound:
            return "The user question has ended or does not exist."
        case .cancelled:
            return "The user cancelled this question."
        }
    }
}

/// UI-side provider for structured questions. A provider must honor task
/// cancellation so an interrupted Agent run never leaves a continuation live.
protocol UserQuestionProvider: Sendable {
    func ask(_ request: AskUserQuestionRequest) async throws -> AskUserQuestionAnswer
}

/// The capability seam used by `AskUserQuestionTool` and `ExitPlanModeTool`.
/// Exactly one provider may be active, matching the upstream context service.
actor UserQuestionService {
    typealias Provider = any UserQuestionProvider

    private var provider: Provider?

    init(provider: Provider? = nil) {
        self.provider = provider
    }

    /// Install one UI provider. The returned token is required to remove it,
    /// which prevents an old UI from unregistering a newer one after reload.
    @discardableResult
    func registerProvider(_ provider: Provider) throws -> UUID {
        guard self.provider == nil else {
            throw UserQuestionError.duplicateProvider
        }
        self.provider = provider
        return UUID()
    }

    func unregisterProvider() {
        provider = nil
    }

    func ask(_ request: AskUserQuestionRequest) async throws -> AskUserQuestionAnswer {
        try Self.validate(request: request)
        guard let provider else { throw UserQuestionError.noProvider }
        try Task.checkCancellation()
        let answer = try await provider.ask(request)
        try Self.validate(answer: answer, for: request)
        return answer
    }

    nonisolated static func validate(request: AskUserQuestionRequest) throws {
        guard !request.questions.isEmpty else {
            throw UserQuestionError.emptyQuestions
        }
        guard request.questions.count <= Limits.maximumQuestions else {
            throw UserQuestionError.invalidRequest("Number of questions exceeds the limit of \(Limits.maximumQuestions)")
        }

        var ids = Set<String>()
        for question in request.questions {
            guard Limits.valid(question.id, maximumBytes: Limits.questionIDBytes),
                  !question.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UserQuestionError.invalidRequest("Invalid question id")
            }
            guard ids.insert(question.id).inserted else {
                throw UserQuestionError.invalidRequest("Question id must be unique: \(question.id)")
            }
            guard Limits.valid(question.question, maximumBytes: Limits.questionTextBytes),
                  !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UserQuestionError.invalidRequest("Invalid question text: \(question.id)")
            }
            if let header = question.header {
                guard Limits.valid(header, maximumBytes: Limits.headerBytes),
                      !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw UserQuestionError.invalidRequest("Invalid question header: \(question.id)")
                }
            }
            if let detail = question.detail,
               !Limits.valid(detail, maximumBytes: Limits.detailBytes) {
                throw UserQuestionError.invalidRequest("Question detail too long: \(question.id)")
            }
            if let options = question.options {
                guard options.count <= Limits.maximumOptions else {
                    throw UserQuestionError.invalidRequest("Number of options exceeds the limit of \(Limits.maximumOptions)")
                }
                var labels = Set<String>()
                for option in options {
                    guard Limits.valid(option.label, maximumBytes: Limits.optionLabelBytes),
                          !option.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw UserQuestionError.invalidRequest("Invalid option label: \(question.id)")
                    }
                    guard labels.insert(option.label).inserted else {
                        throw UserQuestionError.invalidRequest("Option labels must be unique: \(option.label)")
                    }
                    if let description = option.description,
                       !Limits.valid(description, maximumBytes: Limits.optionDescriptionBytes) {
                        throw UserQuestionError.invalidRequest("Option description too long: \(option.label)")
                    }
                }
            }
            if let intent = question.intent {
                guard intent.kind == .planReview else {
                    throw UserQuestionError.badIntent("Unknown intent")
                }
                guard question.detail != nil else {
                    throw UserQuestionError.badIntent("plan-review is missing detail")
                }
                guard question.options?.contains(where: { $0.label == intent.approve }) == true else {
                    throw UserQuestionError.badIntent("approve does not match any option of this question")
                }
                guard Limits.valid(intent.approve, maximumBytes: Limits.optionLabelBytes) else {
                    throw UserQuestionError.badIntent("approve label too long")
                }
            }
        }
    }

    nonisolated static func validate(
        answer: AskUserQuestionAnswer,
        for request: AskUserQuestionRequest
    ) throws {
        guard answer.answers.count == request.questions.count else {
            throw UserQuestionError.invalidAnswer("All \(request.questions.count) questions must be answered")
        }
        var seen = Set<String>()
        let byID = Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, $0) })
        for item in answer.answers {
            guard seen.insert(item.id).inserted,
                  let question = byID[item.id] else {
                throw UserQuestionError.invalidAnswer("Answer id mismatch: \(item.id)")
            }
            guard item.selected.count <= Limits.maximumOptions else {
                throw UserQuestionError.invalidAnswer("Too many selections: \(item.id)")
            }
            let allowed = Set(question.options?.map(\.label) ?? [])
            guard item.selected.allSatisfy({ allowed.contains($0) }),
                  Set(item.selected).count == item.selected.count else {
                throw UserQuestionError.invalidAnswer("Answer contains an option that was not offered: \(item.id)")
            }
            if !question.multiSelect, item.selected.count > 1 {
                throw UserQuestionError.invalidAnswer("A single-choice question cannot have multiple selections: \(item.id)")
            }
            if let custom = item.custom {
                guard Limits.valid(custom, maximumBytes: Limits.customAnswerBytes) else {
                    throw UserQuestionError.invalidAnswer("Custom answer too long: \(item.id)")
                }
            }
            if item.isSkipped {
                continue
            }
            let customIsEmpty = item.custom?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true
            guard !item.selected.isEmpty || !customIsEmpty else {
                throw UserQuestionError.invalidAnswer("Answer cannot be empty: \(item.id)")
            }
        }
    }
}

/// A continuation-backed provider suitable for a native SwiftUI surface. The
/// UI reads `pending()` and calls `submit` or `cancel`; no network or server is
/// involved. Only one pending request can exist at a time.
actor ContinuationUserQuestionProvider: UserQuestionProvider {
    struct Pending: Identifiable, Sendable, Equatable {
        let id: UUID
        let request: AskUserQuestionRequest

        var requestID: UUID { id }
    }

    private var pendingRequest: Pending?
    private var continuation: CheckedContinuation<AskUserQuestionAnswer, Error>?

    func pending() -> Pending? {
        pendingRequest
    }

    func ask(_ request: AskUserQuestionRequest) async throws -> AskUserQuestionAnswer {
        try Task.checkCancellation()
        guard pendingRequest == nil else { throw UserQuestionError.busy }

        let pending = Pending(id: request.id, request: request)
        pendingRequest = pending
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                // Cancellation can race with continuation installation. If the
                // request was already removed, complete immediately with the
                // same typed cancellation instead of leaking the continuation.
                guard self.pendingRequest?.id == pending.id else {
                    continuation.resume(throwing: UserQuestionError.cancelled)
                    return
                }
                self.continuation = continuation
            }
        }, onCancel: {
            Task { try? await self.cancel(requestID: pending.id, error: UserQuestionError.cancelled) }
        })
    }

    func submit(_ answer: AskUserQuestionAnswer, requestID: UUID) throws {
        guard pendingRequest?.id == requestID, let continuation else {
            throw UserQuestionError.requestNotFound
        }
        pendingRequest = nil
        self.continuation = nil
        continuation.resume(returning: answer)
    }

    func cancel(requestID: UUID, error: UserQuestionError = .cancelled) throws {
        guard pendingRequest?.id == requestID else {
            throw UserQuestionError.requestNotFound
        }
        let pendingContinuation = continuation
        pendingRequest = nil
        self.continuation = nil
        pendingContinuation?.resume(throwing: error)
    }
}

private enum Limits {
    static let maximumQuestions = 8
    static let maximumOptions = 16
    static let questionIDBytes = 128
    static let questionTextBytes = 4 * 1_024
    static let headerBytes = 256
    static let detailBytes = 64 * 1_024
    static let optionLabelBytes = 256
    static let optionDescriptionBytes = 2 * 1_024
    static let customAnswerBytes = 4 * 1_024

    static func valid(_ value: String, maximumBytes: Int) -> Bool {
        value.utf8.count <= maximumBytes
    }
}

private enum UserQuestionWire {
    static func encode(_ value: AskUserQuestionAnswer) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func optionalString(_ key: String, maximumBytes: Int) throws -> String? {
        guard let value = self[key] else { return nil }
        guard let string = value.stringValue, Limits.valid(string, maximumBytes: maximumBytes) else {
            throw UserQuestionError.invalidRequest("Argument \(key) must be a length-limited string")
        }
        return string
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let value = self[key] else { return nil }
        guard case let .bool(bool) = value else {
            throw UserQuestionError.invalidRequest("Argument \(key) must be a boolean")
        }
        return bool
    }
}

private extension AskUserQuestionTool {
    static func parseRequest(arguments: [String: JSONValue]) throws -> [AskUserQuestionItem] {
        try arguments.requireOnlyKeys(["questions"])
        guard case let .array(rawQuestions) = arguments["questions"] else {
            throw UserQuestionError.invalidRequest("questions must be an array")
        }
        guard !rawQuestions.isEmpty else { throw UserQuestionError.emptyQuestions }
        guard rawQuestions.count <= Limits.maximumQuestions else {
            throw UserQuestionError.invalidRequest("Number of questions exceeds the limit of \(Limits.maximumQuestions)")
        }

        return try rawQuestions.map { rawQuestion in
            guard case let .object(question) = rawQuestion else {
                throw UserQuestionError.invalidRequest("Each question must be an object")
            }
            guard let id = question["id"]?.stringValue,
                  let text = question["question"]?.stringValue else {
                throw UserQuestionError.invalidRequest("Each question requires id and question")
            }
            let header = try question.optionalString("header", maximumBytes: Limits.headerBytes)
            let detail = try question.optionalString("detail", maximumBytes: Limits.detailBytes)
            let multiSelect = try question.optionalBool("multi_select") ?? false

            var options: [AskUserQuestionOption]?
            if let rawOptions = question["options"] {
                guard case let .array(values) = rawOptions else {
                    throw UserQuestionError.invalidRequest("options must be an array")
                }
                guard values.count <= Limits.maximumOptions else {
                    throw UserQuestionError.invalidRequest("Number of options exceeds the limit of \(Limits.maximumOptions)")
                }
                options = try values.map { rawOption in
                    guard case let .object(option) = rawOption,
                          let label = option["label"]?.stringValue else {
                        throw UserQuestionError.invalidRequest("Each option requires a label")
                    }
                    let description = try option.optionalString(
                        "description",
                        maximumBytes: Limits.optionDescriptionBytes
                    )
                    return AskUserQuestionOption(label: label, description: description)
                }
            }

            var intent: AskUserQuestionIntent?
            if let rawIntent = question["intent"] {
                guard case let .object(value) = rawIntent,
                      let rawKind = value["kind"]?.stringValue,
                      let kind = AskUserQuestionIntent.Kind(rawValue: rawKind),
                      let approve = value["approve"]?.stringValue else {
                    throw UserQuestionError.badIntent("intent must include kind and approve")
                }
                intent = AskUserQuestionIntent(kind: kind, approve: approve)
            }

            let item = AskUserQuestionItem(
                id: id,
                question: text,
                detail: detail,
                header: header,
                options: options,
                multiSelect: multiSelect,
                intent: intent
            )
            try UserQuestionService.validate(request: AskUserQuestionRequest(questions: [item]))
            return item
        }
    }
}

/// Model-facing structured question tool. It never performs network or shell
/// work; it only waits on the registered on-device question provider.
struct AskUserQuestionTool: LocalAgentTool {
    let service: UserQuestionService

    let definition = ModelToolDefinition(
        name: "ask_user_question",
        description: "Ask the user a concise question when you need confirmation, a choice, or missing information before proceeding. Send one or more questions, each with a stable id that will be echoed in the answer.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "questions": .object([
                    "type": .string("array"),
                    "minItems": .number(1),
                    "maxItems": .number(Double(Limits.maximumQuestions)),
                    "items": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(true),
                        "properties": .object([
                            "id": .object(["type": .string("string")]),
                            "question": .object(["type": .string("string")]),
                            "detail": .object(["type": .string("string")]),
                            "header": .object(["type": .string("string")]),
                            "options": .object([
                                "type": .string("array"),
                                "maxItems": .number(Double(Limits.maximumOptions)),
                                "items": .object([
                                    "type": .string("object"),
                                    "additionalProperties": .bool(true),
                                    "properties": .object([
                                        "label": .object(["type": .string("string")]),
                                        "description": .object(["type": .string("string")])
                                    ]),
                                    "required": .array([.string("label")])
                                ])
                            ]),
                            "multi_select": .object(["type": .string("boolean")]),
                            "intent": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "kind": .object(["type": .string("string"), "enum": .array([.string("plan-review")])]),
                                    "approve": .object(["type": .string("string")])
                                ]),
                                "required": .array([.string("kind"), .string("approve")]),
                                "additionalProperties": .bool(false)
                            ])
                        ]),
                        "required": .array([.string("id"), .string("question")])
                    ])
                ])
            ]),
            "required": .array([.string("questions")]),
            "additionalProperties": .bool(false)
        ])
    )

    let risk: ToolRisk = .localState

    func validate(arguments: [String: JSONValue]) throws {
        _ = try Self.parseRequest(arguments: arguments)
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let count: Int
        if case let .array(values) = arguments["questions"] {
            count = values.count
        } else {
            count = 0
        }
        return "Waiting for user answer (" + String(count) + " questions)"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let questions = try Self.parseRequest(arguments: arguments)
        let request = AskUserQuestionRequest(questions: questions)
        let answer = try await service.ask(request)
        return try UserQuestionWire.encode(answer)
    }
}

// MARK: - Plan review

/// Per-active-runtime plan state. Approval is queued until the next model-step
/// boundary, matching the upstream `pendingIntents` behavior. The prompt can
/// therefore remain in plan mode for the rest of the current tool batch.
actor PlanModeStateStore {
    private var active: Bool
    private var pendingExit = false

    init(active: Bool = false) {
        self.active = active
    }

    func isActive() -> Bool { active }

    func hasPendingExit() -> Bool { pendingExit }

    func setActive(_ active: Bool) {
        self.active = active
        pendingExit = false
    }

    /// Queue an approved exit. Returns false if this runtime is not in plan
    /// mode, allowing the tool to report the same explicit upstream error.
    @discardableResult
    func requestExit() -> Bool {
        guard active else { return false }
        pendingExit = true
        return true
    }

    /// Apply a queued transition at a request boundary. The host should call
    /// this immediately before assembling the next model request.
    @discardableResult
    func commitPendingExit() -> Bool {
        guard pendingExit else { return false }
        active = false
        pendingExit = false
        return true
    }
}

enum PlanReviewError: LocalizedError, Sendable, Equatable {
    case inactive
    case invalidPlan
    case unavailable
    case dismissed
    case rejected(String?)

    var errorDescription: String? {
        switch self {
        case .inactive:
            return "exit_plan_mode can only be used in Plan mode."
        case .invalidPlan:
            return "exit_plan_mode requires a non-empty plan that starts with a level-1 Markdown heading."
        case .unavailable:
            return "No local plan review interface is currently available."
        case .dismissed:
            return "The user closed the plan review to type a message directly. Stay in Plan mode and wait for the user's message."
        case let .rejected(feedback):
            if let feedback, !feedback.isEmpty {
                return "The user chose to keep planning. Feedback: " + feedback
            }
            return "The user chose to keep planning. Revise the plan and submit it for review again."
        }
    }
}

/// `exit_plan_mode` asks for an exact named approval and queues the mode flip.
struct ExitPlanModeTool: LocalAgentTool {
    static let reviewID = "plan-review"
    static let approveLabel = "Approve"
    static let keepPlanningLabel = "Keep planning"

    let questionService: UserQuestionService
    let planState: PlanModeStateStore

    let definition = ModelToolDefinition(
        name: "exit_plan_mode",
        description: "Use only in plan mode. Present your complete Markdown plan for the user's review and leave plan mode only after an exact approval.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "plan": .object([
                    "type": .string("string"),
                    "minLength": .number(3),
                    "maxLength": .number(Double(Limits.detailBytes)),
                    "description": .string("The complete plan as markdown, starting with a # heading that names it.")
                ])
            ]),
            "required": .array([.string("plan")]),
            "additionalProperties": .bool(false)
        ])
    )

    let risk: ToolRisk = .localState

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["plan"])
        guard let plan = arguments["plan"]?.stringValue,
              Self.isValidPlan(plan) else {
            throw PlanReviewError.invalidPlan
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let plan = arguments["plan"]?.stringValue ?? "Plan"
        let title = Self.firstHeading(in: plan) ?? "Plan"
        return "Submit plan for review: " + String(title.prefix(128))
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        guard let plan = arguments["plan"]?.stringValue else {
            throw PlanReviewError.invalidPlan
        }
        guard await planState.isActive() else {
            throw PlanReviewError.inactive
        }

        let question = AskUserQuestionItem(
            id: Self.reviewID,
            question: "Approve this plan and leave plan mode?",
            detail: plan,
            header: "Plan review",
            options: [
                AskUserQuestionOption(
                    label: Self.approveLabel,
                    description: "Leave plan mode; carry out the plan from the next step."
                ),
                AskUserQuestionOption(
                    label: Self.keepPlanningLabel,
                    description: "Stay in plan mode; feedback goes back to the model."
                )
            ],
            multiSelect: false,
            intent: AskUserQuestionIntent(approve: Self.approveLabel)
        )

        let answer: AskUserQuestionAnswer
        do {
            answer = try await questionService.ask(
                AskUserQuestionRequest(questions: [question])
            )
        } catch let error as UserQuestionError where error == .cancelled {
            throw PlanReviewError.dismissed
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as UserQuestionError where error == .noProvider {
            throw PlanReviewError.unavailable
        }

        guard let item = answer.answers.first(where: { $0.id == Self.reviewID }),
              item.selected.count == 1,
              item.selected.first == Self.approveLabel,
              item.custom == nil else {
            let feedback = answer.answers.first(where: { $0.id == Self.reviewID })?.custom
            throw PlanReviewError.rejected(feedback)
        }
        guard await planState.requestExit() else {
            throw PlanReviewError.inactive
        }
        return "{\"approved\":true}"
    }

    private static func isValidPlan(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Limits.valid(trimmed, maximumBytes: Limits.detailBytes) else {
            return false
        }
        guard let firstLine = trimmed.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first else { return false }
        return firstLine.hasPrefix("# ")
            && firstLine.dropFirst(2).contains { !$0.isWhitespace }
    }

    private static func firstHeading(in raw: String) -> String? {
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("# ") else { continue }
            let title = line.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return nil
    }
}
