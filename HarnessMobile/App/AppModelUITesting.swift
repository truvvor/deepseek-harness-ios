#if DEBUG
import Foundation

@MainActor
extension AppModel {
    func presentMarkdownTableForUITesting() {
        // This isolated renderer fixture does not contact a model provider.
        // Bypass onboarding so it remains deterministic even when the
        // simulator Keychain is unavailable to the test runner.
        isConfigured = true
        messages = [
            AgentMessage.assistant("""
            ## Tool Capability Comparison

            | Capability | Desktop | Mobile | Status | Notes |
            | :--- | :----: | :----: | ----: | :--- |
            | **File Tools** | Supported | Supported | 100% | Direct read/write inside the working directory |
            | Web Search | Supported | Supported | 95% | Concurrent queries direct from the phone, no server execution |
            """)
        ]
    }

    func presentLongConversationForUITesting() {
        messages = (0..<1_000).map { index in
            let payload = "Long conversation performance fixture"
            if index.isMultiple(of: 2) {
                return AgentMessage.user("perf-message-\(index) \(payload)")
            }
            let toolCalls = index == 999
                ? (0..<100).map { toolIndex in
                    AgentToolCall(
                        id: "perf-call-\(toolIndex)",
                        name: "perf_tool_\(toolIndex)",
                        arguments: "{\"index\":\(toolIndex)}"
                    )
                }
                : []
            return AgentMessage.assistant(
                "perf-message-\(index) \(payload)",
                toolCalls: toolCalls
            )
        }
        var presentation = uiTestingRunPresentation()
        presentation.streamingText = String(repeating: "Streaming tail ", count: 160)
            + "perf-stream-tail"
        presentation.streamingPresentationRevision &+= 1
        selectedRunPresentation = presentation
    }

    func presentChatErrorForUITesting() {
        isConfigured = true
        messages = [
            AgentMessage.user("Continue the current task"),
            AgentMessage.assistant("Current progress is saved in this session.")
        ]
        errorMessage = "The connection was interrupted after switching apps. Retry the last message."
    }

    func presentReasoningForUITesting() {
        isConfigured = true
        messages = [
            AgentMessage.user("Review the current implementation"),
            AgentMessage.assistant(
                "Review complete. The model's original reasoning was not modified.",
                reasoning: "Verify the entry point first, then check state and visible actions."
            )
        ]
    }

    func presentConcurrentSessionRunsForUITesting() async {
        guard let firstSessionID = activeSessionID else { return }
        let firstIdentity = await sessionRunRegistry.allocateIdentity(sessionID: firstSessionID)
        let first = try? await sessionRunRegistry.register(identity: firstIdentity) {
            SessionRunPreparedConfiguration(trajectorySessionID: firstSessionID)
        }
        guard let first else { return }
        _ = await first.handle.beginRunning(for: firstIdentity)
        _ = await first.state.markRunning(for: firstIdentity)
        _ = try? await first.state.enqueue(
            text: "continue with queued input",
            disposition: .queued,
            for: firstIdentity
        )

        await createConversation(title: "Concurrent Session B")
        guard let secondSessionID = activeSessionID else { return }
        let secondIdentity = await sessionRunRegistry.allocateIdentity(sessionID: secondSessionID)
        let second = try? await sessionRunRegistry.register(identity: secondIdentity) {
            SessionRunPreparedConfiguration(trajectorySessionID: secondSessionID)
        }
        guard let second else { return }
        _ = await second.handle.beginRunning(for: secondIdentity)
        _ = await second.state.markRunning(for: secondIdentity)

        // End on the original session so the UI exercise proves that switching
        // away from the newly created session preserves both root runs.
        await switchConversation(to: firstSessionID)
    }

    func presentTrajectoryForUITesting() async {
        guard let sessionID = activeSessionID else { return }
        let userID = UUID().uuidString
        let assistantID = UUID().uuidString
        let usage = SessionTokenUsage(
            inputTokens: 120,
            outputTokens: 24,
            cacheReadTokens: 80,
            cacheWriteTokens: 0,
            reasoningTokens: 6
        )
        let header: JSONValue = .object([
            "config": .object([
                "provider": .string("deepseek"),
                "model": .string("deepseek-chat"),
                "tools": .array([.string("workspace_read_text")])
            ]),
            "system": .string("UI-008 trajectory fixture")
        ])
        let userMessage: JSONValue = .object([
            "id": .string(userID),
            "role": .string("user"),
            "content": .array([.object([
                "type": .string("text"),
                "text": .string("inspect this trajectory")
            ])]),
            "source": .object(["kind": .string("user")])
        ])
        let assistantMessage: JSONValue = .object([
            "id": .string(assistantID),
            "role": .string("assistant"),
            "content": .array([.object([
                "type": .string("text"),
                "text": .string("I inspected the local session.")
            ]), .object([
                "type": .string("tool-call"),
                "id": .string("ui008-call"),
                "name": .string("workspace_read_text"),
                "arguments": .string("{\"path\":\"/workspace/README.md\"}")
            ])])
        ])
        let toolMessage: JSONValue = .object([
            "id": .string(UUID().uuidString),
            "role": .string("tool"),
            "content": .array([.object([
                "type": .string("text"),
                "text": .string("README fixture output")
            ])]),
            "source": .object([
                "kind": .string("tool"),
                "callId": .string("ui008-call")
            ])
        ])

        do {
            _ = try await trajectoryRepository.append(
                .requestHeader(header: header, reason: .initial, time: 1_000),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .requestContext(
                    provider: "deepseek",
                    model: "deepseek-chat",
                    contextWindow: 128_000,
                    time: 1_010
                ),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .turnStart(turn: 1, time: 1_020),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .stepStart(turn: 1, step: 1, time: 1_030),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .userMessage(userMessage, time: 1_040),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .assistantMessage(
                    turn: 1,
                    step: 1,
                    message: assistantMessage,
                    usage: usage,
                    time: 1_120
                ),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .toolCall(
                    turn: 1,
                    step: 1,
                    callID: "ui008-call",
                    name: "workspace_read_text",
                    arguments: "{\"path\":\"/workspace/README.md\"}",
                    time: 1_140
                ),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .toolResult(
                    turn: 1,
                    step: 1,
                    message: toolMessage,
                    time: 1_240
                ),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .stepEnd(turn: 1, step: 1, time: 1_250),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .turnEnd(turn: 1, reason: .string("completed"), time: 1_260),
                sessionID: sessionID
            )
            try await trajectoryRepository.flush(sessionID: sessionID)
            await refreshTrajectory()
        } catch {
            presentError(error)
        }
    }

    func presentLargeMarkdownForUITesting(characterCount: Int = 1_000_000) {
        isConfigured = true
        let prefix = """
        # large-markdown-start

        """
        let suffix = """


        # large-markdown-end

        [OpenAI](https://openai.com)

        > quoted line one
        > quoted line two

        | Name | Status |
        | :--- | :----: |
        | Harness | ready |

        ~~~~swift
        let localOnly = true
        ~~~~
        """
        let paragraph = String(repeating: "bounded markdown paragraph word ", count: 120) + "\n\n"
        let tailPadding = String(repeating: "x", count: 12_000) + "\n\n"
        let bodyCount = max(
            0,
            characterCount - prefix.count - tailPadding.count - suffix.count
        )
        let repeatedBody = String(repeating: paragraph, count: bodyCount / paragraph.count)
        let remainder = String(repeating: "x", count: bodyCount - repeatedBody.count)
        let markdown = prefix + repeatedBody + remainder + tailPadding + suffix
        messages = [AgentMessage.assistant(markdown)]
    }

    func presentPluginMarketplaceForUITesting() {
        ishPluginMarketplaceCatalog = ISHMarketplaceCatalog(
            sourceURL: "https://example.invalid/market/README.md",
            fetchedAt: "2026-08-16T00:00:00Z",
            stale: false,
            items: [
                ISHMarketplaceCatalogItem(
                    id: "git-tools",
                    name: "Git Tools",
                    repositoryURL: "https://github.com/example/git-tools",
                    repositoryKey: "example/git-tools",
                    description: "Organize commits, branches, and change summaries in on-device iSH.",
                    category: "Tools & Capabilities",
                    compatibility: .supported,
                    unsupportedReason: nil,
                    installed: false,
                    installedPluginID: nil,
                    installedVersion: nil
                ),
                ISHMarketplaceCatalogItem(
                    id: "memory-notes",
                    name: "Memory Notes",
                    repositoryURL: "https://github.com/example/memory-notes",
                    repositoryKey: "example/memory-notes",
                    description: "Provides a pluggable local Markdown memory index for the Agent.",
                    category: "Memory",
                    compatibility: .review,
                    unsupportedReason: "Host service compatibility is verified on the phone during installation.",
                    installed: true,
                    installedPluginID: "memory-notes",
                    installedVersion: "1.2.0"
                ),
                ISHMarketplaceCatalogItem(
                    id: "file-memory-native",
                    name: "File Memory Native",
                    repositoryURL: "https://github.com/example/file-memory",
                    repositoryKey: "example/file-memory",
                    description: "A native file memory plugin, isolated per conversation, that can dynamically inject context.",
                    category: "Memory",
                    compatibility: .supported,
                    unsupportedReason: nil,
                    installed: true,
                    installedPluginID: "native-agent.file-memory",
                    installedVersion: "1.0.0-native"
                ),
                ISHMarketplaceCatalogItem(
                    id: "desktop-theme",
                    name: "Desktop Theme",
                    repositoryURL: "https://github.com/example/desktop-theme",
                    repositoryKey: "example/desktop-theme",
                    description: "Provides only a desktop Web Client theme; the mobile Host does not run it.",
                    category: "Themes & Appearance",
                    compatibility: .unsupported,
                    unsupportedReason: "This category mainly injects into the DSH desktop Web UI and is not currently compatible with mobile.",
                    installed: false,
                    installedPluginID: nil,
                    installedVersion: nil
                ),
            ]
        )
        ishMarketplacePlugins = [
            ISHMarketplacePlugin(
                id: "memory-notes",
                name: "Memory Notes",
                version: "1.2.0",
                description: "Provides a pluggable local Markdown memory index for the Agent.",
                license: "MIT",
                source: ISHMarketplacePluginSource(
                    kind: .market,
                    location: "https://github.com/example/memory-notes"
                ),
                enabled: true,
                state: .enabled,
                installedAt: "2026-08-15T12:00:00Z",
                updatedAt: "2026-08-16T00:00:00Z",
                entryCount: 3,
                lastError: nil
            ),
        ]
        let nativePlugin = NativeAgentCompiledPlugin(
            schemaVersion: NativeAgentCompiledPlugin.schemaVersion,
            id: "native-agent.file-memory",
            name: "File Memory Native",
            version: "1.0.0-native",
            description: "A native file memory plugin isolated per conversation.",
            source: ISHMarketplacePluginSource(
                kind: .github,
                location: "https://github.com/example/file-memory"
            ),
            sourceDigest: String(repeating: "c", count: 64),
            compiledAt: .now,
            compilerProviderID: "ui-test",
            compilerModel: "ui-test",
            enabled: true,
            promptSections: [],
            promptContexts: [
                NativeAgentPromptContext(
                    name: "memory",
                    order: 120,
                    source: .file,
                    path: "<session-storage>/notes.md",
                    maximumCharacters: 6_000,
                    prefix: "<memory>\n",
                    suffix: "\n</memory>"
                )
            ],
            settings: NativeAgentPluginSettings(
                schema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "maxRecallChars": .object([
                            "type": .string("integer"),
                            "title": .string("Max Recall Characters"),
                            "description": .string("Maximum characters injected into context at once."),
                            "minimum": .number(256),
                            "maximum": .number(32_768),
                            "default": .number(6_000)
                        ])
                    ]),
                    "required": .array([.string("maxRecallChars")]),
                    "additionalProperties": .bool(false)
                ]),
                defaults: .object(["maxRecallChars": .number(6_000)]),
                values: .object(["maxRecallChars": .number(6_000)])
            ),
            tools: [],
            toolGuards: [],
            compatibilityNotes: [
                "Desktop Node fs has been replaced with the iPhone workspace file system.",
                "Each conversation uses its own storage directory."
            ]
        )
        nativeAgentPlugins = [nativePlugin]
        ishMarketplacePlugins.append(nativePlugin.marketplaceProjection)
        ishPluginMarketplaceFailure = nil
        ishPluginMarketplaceOperation = nil
    }

    func presentPluginSettingsForUITesting() {
        ishPluginHostState = .running(hostVersion: "ui-test", processID: nil)
        ishPluginSettingsSnapshot = ISHPluginSettingsSnapshot(
            writable: true,
            hasDocument: true,
            namespaces: [
                ISHPluginSettingsNamespace(
                    ns: "memory-notes",
                    schema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "autoIndex": .object([
                                "type": .string("boolean"),
                                "title": .string("Auto Index"),
                                "description": .string("Automatically updates the local memory index after saving files."),
                                "default": .bool(true)
                            ]),
                            "maxItems": .object([
                                "type": .string("integer"),
                                "title": .string("Max Records"),
                                "description": .string("Maximum records kept per namespace."),
                                "minimum": .number(10),
                                "maximum": .number(500),
                                "default": .number(50)
                            ])
                        ]),
                        "required": .array([.string("autoIndex"), .string("maxItems")]),
                        "additionalProperties": .bool(false)
                    ]),
                    value: .object(["autoIndex": .bool(true), "maxItems": .number(80)]),
                    base: .object(["autoIndex": .bool(true), "maxItems": .number(50)]),
                    user: .object(["maxItems": .number(80)]),
                    revision: 7,
                    applies: .live,
                    secrets: [],
                    editable: true,
                    unsupportedReason: nil
                )
            ]
        )
    }

    func presentPluginCompilationFailureForUITesting() {
        presentPluginMarketplaceForUITesting()

        let timestamp = Date(timeIntervalSince1970: 1_724_587_200)
        var trace = NativePluginCompilationTrace(
            source: "example/unsupported-web-client",
            now: timestamp
        )
        trace.finishedAt = timestamp.addingTimeInterval(12)
        trace.outcome = "Failed: unaudited Web client contribution detected."
        trace.diagnostic = NativeAgentCompilationDiagnostic(
            code: "UNSUPPORTED_CLIENT_CONTRIBUTION",
            stage: NativePluginCompilationStage.validation.rawValue,
            message: "This plugin requests a Web client slot; mobile does not dynamically load Web or Swift code.",
            retryable: false,
            suggestedAction: "Remove the Web client contribution, switch to a controlled native manifest, and recompile."
        )
        trace.steps = trace.steps.map { step in
            var updated = step
            switch step.stage {
            case .sourceAcquisition:
                updated.state = .succeeded
                updated.detail = "Source snapshot complete; credentials remain in Keychain."
            case .sourceAnalysis:
                updated.state = .succeeded
                updated.detail = "Plugin contributions and on-device Host boundaries identified."
            case .adaptability:
                updated.state = .succeeded
                updated.detail = "Core capabilities can be projected into a controlled native manifest."
            case .modelCompilation:
                updated.state = .succeeded
                updated.detail = "Agent returned a candidate native plugin manifest."
            case .validation:
                updated.state = .failed
                updated.detail = "Rejected unaudited Web client contribution."
            case .nativeInstallation, .ishFallback:
                updated.state = .skipped
                updated.detail = "Validation failed; execution stopped."
            }
            updated.updatedAt = timestamp
            return updated
        }
        trace.logs = [
            NativePluginCompilationLogEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
                timestamp: timestamp,
                stage: .sourceAcquisition,
                state: .succeeded,
                message: "Source snapshot complete; credentials remain in Keychain."
            ),
            NativePluginCompilationLogEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                timestamp: timestamp.addingTimeInterval(12),
                stage: .validation,
                state: .failed,
                message: "Rejected unaudited Web client contribution."
            ),
        ]
        nativePluginCompilationTrace = trace
    }

    func presentPlanReviewForUITesting() {
        let request = AskUserQuestionRequest(
            questions: [
                AskUserQuestionItem(
                    id: "plan-review",
                    question: "Approve this plan and leave plan mode?",
                    detail: "# Harness Mobile plan\n\n1. Inspect the local runtime.\n2. Apply the change.\n3. Verify it on iPhone.",
                    header: "Plan review",
                    options: [
                        AskUserQuestionOption(
                            label: "Refuse",
                            description: "Keep Plan mode and revise the plan."
                        ),
                        AskUserQuestionOption(
                            label: "Approve",
                            description: "Approve and leave Plan mode at the next model boundary."
                        ),
                    ],
                    intent: AskUserQuestionIntent(approve: "Approve")
                ),
            ]
        )
        var presentation = uiTestingRunPresentation()
        presentation.pendingUserQuestion = ContinuationUserQuestionProvider.Pending(
            id: request.id,
            request: request
        )
        selectedRunPresentation = presentation
    }

    private func uiTestingRunPresentation() -> SessionRunPresentation {
        if let selectedRunPresentation {
            return selectedRunPresentation
        }
        let identity = RunIdentity(
            sessionID: activeSessionID ?? UUID(),
            runID: UUID(),
            generation: 1
        )
        var presentation = SessionRunPresentation(identity: identity)
        presentation.phase = .running
        presentation.runStartedAt = .now
        return presentation
    }
}
#endif
