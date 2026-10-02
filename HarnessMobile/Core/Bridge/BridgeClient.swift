import Foundation

/// Supplies the desktop bridge bearer token.
///
/// The token is resolved per request from the Keychain so it is never stored on
/// the client, never placed in a URL, and never written to a log. Only the
/// `Authorization` header of an outbound bridge request ever carries it.
typealias BridgeTokenProvider = @Sendable () async -> String?

enum BridgeClientError: Error, LocalizedError, Sendable, Equatable {
    case disabled
    case missingBaseURL
    case missingToken
    case unauthorized
    case forbidden
    case notFound
    case server(status: Int)
    case badResponse
    case decoding(String)
    case notConnected
    case transport(String)
    case cancelled
    case streamEnded(String?)
    /// A non-2xx answer whose body carried the bridge `{error:{code,message}}`
    /// shape, for example `session/agent-busy` or `session/writer-held`.
    case rejected(status: Int, code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "The desktop bridge is turned off in Settings."
        case .missingBaseURL:
            return "No desktop bridge address is configured."
        case .missingToken:
            return "The desktop bridge access token is missing."
        case .unauthorized:
            return "The desktop bridge rejected the access token (HTTP 401)."
        case .forbidden:
            return "The desktop bridge refused the request (HTTP 403)."
        case .notFound:
            return "The desktop bridge has no such session or route (HTTP 404)."
        case let .server(status):
            return "The desktop bridge reported a server error (HTTP \(status))."
        case .badResponse:
            return "The desktop bridge returned a response this app cannot use."
        case let .decoding(detail):
            return "The desktop bridge response could not be decoded: \(detail)"
        case .notConnected:
            return "No network route to the desktop bridge."
        case let .transport(detail):
            return "The desktop bridge request failed: \(detail)"
        case .cancelled:
            return "The desktop bridge request was cancelled."
        case let .streamEnded(reason):
            return reason.map { "The desktop session stream ended: \($0)" }
                ?? "The desktop session stream ended."
        case let .rejected(status, code, message):
            switch code {
            case "session/agent-busy":
                return "The desktop agent is already running a turn in this session."
            case "session/writer-held":
                return "Another client currently owns this desktop session."
            case "session/not-found":
                return "The desktop session is not open on the desktop host."
            default:
                let detail = message ?? code ?? "HTTP \(status)"
                return "The desktop bridge rejected the request: \(detail)"
            }
        }
    }
}

/// HTTP client for the DeepSeek Harness desktop API bridge (`/bridge/v1`).
///
/// Reads: `listSessions`, `messages`, `exportLog`, `stream`, `health`.
/// Writes (DECISIONS D-014): `prompt` and `cancel`, which hand a user's text to
/// the *desktop* agent of an already mirrored desktop session. The desktop runs
/// the turn with its own model, tools and agent loop and stays the only writer
/// of that session's log; the app never sends its own prompts, tools, model
/// configuration or agent loop, and offers no archive or chat-completions route.
actor BridgeClient {
    private let configuration: BridgeClientConfiguration
    private let tokenProvider: BridgeTokenProvider
    private let sessionConfiguration: URLSessionConfiguration
    private var session: URLSession

    /// Upper bound for one request, including a long-lived SSE follow.
    static let maximumResourceLifetimeSeconds: TimeInterval = 24 * 60 * 60

    /// `POST …/prompt` answers only after the desktop turn ends and sends no
    /// bytes before that. The bridge aborts the turn when the client
    /// disconnects, so the request must outlive a long agent turn.
    static let promptTimeoutSeconds: TimeInterval = 6 * 60 * 60

    /// `protocolClasses` is a test seam: the client owns its URLSession, so a
    /// stub `URLProtocol` must be installed on that session's configuration.
    init(
        configuration: BridgeClientConfiguration,
        tokenProvider: @escaping BridgeTokenProvider,
        protocolClasses: [AnyClass]? = nil
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeoutSeconds
        // `timeoutIntervalForResource` caps a request's whole lifetime, so it must
        // not be the stream idle timeout: a healthy SSE follow lives for hours.
        // Inactivity is bounded per request through `URLRequest.timeoutInterval`.
        sessionConfiguration.timeoutIntervalForResource = Self.maximumResourceLifetimeSeconds
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        if let protocolClasses {
            sessionConfiguration.protocolClasses = protocolClasses
        }
        self.sessionConfiguration = sessionConfiguration
        self.session = URLSession(configuration: sessionConfiguration)
    }

    /// Replaces the live URLSession, dropping connections bound to an old token.
    func resetConnections() {
        session.invalidateAndCancel()
        session = URLSession(configuration: sessionConfiguration)
    }

    // MARK: - Routes

    func health() async throws -> BridgeSessionHealth {
        try await get("health", query: [])
    }

    func listSessions(includeArchived: Bool) async throws -> [BridgeSessionListEntry] {
        let response: BridgeSessionListResponse = try await get(
            "sessions",
            query: includeArchived ? [URLQueryItem(name: "includeArchived", value: "1")] : []
        )
        return response.data
    }

    func messages(
        sessionID: String,
        throughSeq: Int64? = nil,
        maximumMessages: Int? = nil
    ) async throws -> BridgeMessagePage {
        var query: [URLQueryItem] = []
        if let throughSeq {
            query.append(URLQueryItem(name: "throughSeq", value: String(throughSeq)))
        }
        if let maximumMessages {
            let bounded = min(max(1, maximumMessages), BridgeSettings.maximumMessagePageSize)
            query.append(URLQueryItem(name: "maxMessages", value: String(bounded)))
        }
        return try await get(sessionPath(sessionID, "messages"), query: query)
    }

    /// Canonical v4 JSONL export: one `{"type":"session",...}` header line plus one
    /// line per event. Plain ndjson, no compression.
    func exportLog(sessionID: String) async throws -> Data {
        try await getData(sessionPath(sessionID, "export"), query: [])
    }

    /// Incremental export: only the events with `seq > since`. A bridge that
    /// supports it answers with `x-dsh-since` / `x-dsh-through-seq`; an older
    /// bridge ignores the parameter and returns the full log, which the page
    /// reports as non-incremental.
    func exportLog(sessionID: String, since: Int64, limit: Int? = nil) async throws -> BridgeExportPage {
        var query = [URLQueryItem(name: "since", value: String(since))]
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(max(1, limit))))
        }
        let url = try makeURL(sessionPath(sessionID, "export"), query: query)
        guard let token = await tokenProvider() else {
            throw BridgeClientError.missingToken
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        request.timeoutInterval = configuration.requestTimeoutSeconds
        let (data, response) = try await performWithResponse(request)
        return BridgeExportPage(
            data: data,
            since: response.value(forHTTPHeaderField: "x-dsh-since").flatMap { Int64($0) },
            throughSeq: response.value(forHTTPHeaderField: "x-dsh-through-seq").flatMap { Int64($0) },
            headSeq: response.value(forHTTPHeaderField: "x-dsh-head-seq").flatMap { Int64($0) },
            hasMore: response.value(forHTTPHeaderField: "x-dsh-has-more")?.lowercased() == "true"
        )
    }

    /// Runs one turn of the desktop agent in `sessionID` (D-014). Blocks until
    /// the desktop reports `turn/end`; the durable events arrive through the
    /// mirror (`stream` + `exportLog`), this result is only the turn summary.
    func prompt(
        sessionID: String,
        text: String,
        mode: BridgePromptMode = .queue
    ) async throws -> BridgePromptResult {
        let body = try JSONEncoder().encode(BridgePromptRequest(text: text, mode: mode))
        let data = try await post(
            sessionPath(sessionID, "prompt"),
            body: body,
            timeout: Self.promptTimeoutSeconds
        )
        do {
            return try JSONDecoder().decode(BridgePromptResult.self, from: data)
        } catch {
            throw BridgeClientError.decoding(String(describing: BridgePromptResult.self))
        }
    }

    /// Asks the desktop to cancel the running turn of `sessionID`.
    func cancel(sessionID: String) async throws {
        _ = try await post(
            sessionPath(sessionID, "cancel"),
            body: nil,
            timeout: configuration.requestTimeoutSeconds
        )
    }

    /// Live SSE mirror of one desktop session. `since` reconstructs the resume
    /// point after a reconnect; `nil` asks for the current snapshot only.
    func stream(sessionID: String, since: Int64? = nil) -> AsyncThrowingStream<BridgeStreamFrame, Error> {
        // Resolve everything the read task needs *before* it starts, so the task
        // captures only Sendable values and never reaches back into the actor.
        let url: URL
        do {
            url = try makeURL(
                sessionPath(sessionID, "stream"),
                query: since.map { [URLQueryItem(name: "since", value: String($0))] } ?? []
            )
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return Self.makeStream(
            url: url,
            tokenProvider: tokenProvider,
            session: session,
            requestTimeout: configuration.requestTimeoutSeconds,
            idleTimeout: configuration.streamIdleTimeoutSeconds
        )
    }

    private static func makeStream(
        url: URL,
        tokenProvider: @escaping BridgeTokenProvider,
        session: URLSession,
        requestTimeout: TimeInterval,
        idleTimeout: TimeInterval
    ) -> AsyncThrowingStream<BridgeStreamFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var decoder = SSEEventDecoder()
                do {
                    guard let token = await tokenProvider() else {
                        throw BridgeClientError.missingToken
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    // For a streaming request URLSession applies this as the
                    // maximum silence between received bytes, which is exactly
                    // the stream idle timeout.
                    request.timeoutInterval = max(requestTimeout, idleTimeout)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw BridgeClientError.badResponse
                    }
                    try Self.validate(status: http.statusCode)

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let payload = try decoder.consume(byte: byte) else { continue }
                        guard let data = payload.data(using: .utf8),
                              let frame = try? JSONDecoder().decode(BridgeStreamFrame.self, from: data) else {
                            continue
                        }
                        continuation.yield(frame)
                        if frame.kind == .closed { break }
                    }
                    if let payload = try? decoder.finish(),
                       let data = payload.data(using: .utf8),
                       let frame = try? JSONDecoder().decode(BridgeStreamFrame.self, from: data) {
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: BridgeClientError.cancelled)
                } catch let error as BridgeClientError {
                    continuation.finish(throwing: error)
                } catch let error as SSEEventDecoderError {
                    continuation.finish(
                        throwing: BridgeClientError.streamEnded(error.localizedDescription)
                    )
                } catch let error as URLError {
                    continuation.finish(
                        throwing: error.code == .cancelled
                            ? BridgeClientError.cancelled
                            : BridgeClientError.transport(error.localizedDescription)
                    )
                } catch {
                    continuation.finish(throwing: BridgeClientError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request plumbing

    private func sessionPath(_ sessionID: String, _ suffix: String) -> String {
        // Desktop ids are `session-<uuid>`; the path segment must not be
        // re-encoded into something the bridge cannot route.
        "sessions/\(sessionID)/\(suffix)"
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        let data = try await getData(path, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BridgeClientError.decoding(String(describing: T.self))
        }
    }

    private func getData(_ path: String, query: [URLQueryItem]) async throws -> Data {
        let url = try makeURL(path, query: query)
        guard let token = await tokenProvider() else {
            throw BridgeClientError.missingToken
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = configuration.requestTimeoutSeconds
        return try await perform(request)
    }

    private func post(_ path: String, body: Data?, timeout: TimeInterval) async throws -> Data {
        let url = try makeURL(path, query: [])
        guard let token = await tokenProvider() else {
            throw BridgeClientError.missingToken
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        request.timeoutInterval = timeout
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        try await performWithResponse(request).data
    }

    private func performWithResponse(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw BridgeClientError.badResponse
            }
            if let rejection = Self.rejection(status: http.statusCode, body: data) {
                throw rejection
            }
            try Self.validate(status: http.statusCode)
            return (data, http)
        } catch is CancellationError {
            throw BridgeClientError.cancelled
        } catch let error as BridgeClientError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw BridgeClientError.cancelled
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .timedOut, .dnsLookupFailed:
                throw BridgeClientError.notConnected
            default:
                throw BridgeClientError.transport(error.localizedDescription)
            }
        } catch {
            throw BridgeClientError.transport(error.localizedDescription)
        }
    }

    private func makeURL(_ path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(
            url: configuration.baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw BridgeClientError.missingBaseURL
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + "/" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw BridgeClientError.missingBaseURL
        }
        return url
    }

    /// Maps a non-2xx answer that carries a bridge error code to `.rejected`.
    /// Auth failures keep their dedicated cases.
    static func rejection(status: Int, body: Data) -> BridgeClientError? {
        guard !(200..<300).contains(status), status != 401, status != 403,
              let envelope = try? JSONDecoder().decode(BridgeErrorEnvelope.self, from: body),
              envelope.error.code != nil || envelope.error.message != nil else {
            return nil
        }
        return .rejected(status: status, code: envelope.error.code, message: envelope.error.message)
    }

    private static func validate(status: Int) throws {
        switch status {
        case 200..<300:
            return
        case 401:
            throw BridgeClientError.unauthorized
        case 403:
            throw BridgeClientError.forbidden
        case 404:
            throw BridgeClientError.notFound
        default:
            throw BridgeClientError.server(status: status)
        }
    }
}

/// Immutable request configuration resolved from `BridgeSettings` at the moment
/// the mirror is switched on, so a mid-flight settings edit cannot retarget an
/// in-progress stream.
struct BridgeClientConfiguration: Sendable, Equatable {
    let baseURL: URL
    let requestTimeoutSeconds: TimeInterval
    let streamIdleTimeoutSeconds: TimeInterval

    init(settings: BridgeSettings) throws {
        let validated = try settings.validated()
        guard let baseURL = validated.activeBaseURL else {
            throw settings.isEnabled
                ? BridgeSettingsError.invalidBaseURL
                : BridgeSettingsError.disabled
        }
        self.baseURL = baseURL
        self.requestTimeoutSeconds = validated.requestTimeoutSeconds
        self.streamIdleTimeoutSeconds = validated.streamIdleTimeoutSeconds
    }
}
