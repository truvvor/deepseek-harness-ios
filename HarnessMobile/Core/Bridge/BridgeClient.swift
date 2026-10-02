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

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "The desktop bridge is turned off in Settings."
        case .missingBaseURL:
            return "No desktop bridge address is configured."
        case .missingToken:
            return "The desktop bridge bearer token is missing."
        case .unauthorized:
            return "The desktop bridge rejected the bearer token (HTTP 401)."
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
        }
    }
}

/// Read-only HTTP client for the DeepSeek Harness desktop API bridge
/// (`/bridge/v1`).
///
/// The client can only *read*: `listSessions`, `messages`, `exportLog`,
/// `stream`, `health`. It deliberately offers no prompt, cancel, archive or
/// chat-completions route, so the app cannot send its prompts, tools or agent
/// loop to the desktop host. Outbound publication of the app's own trajectory is
/// a separate, explicitly-triggered concern and is not part of this client.
actor BridgeClient {
    private let configuration: BridgeClientConfiguration
    private let tokenProvider: BridgeTokenProvider
    private let sessionConfiguration: URLSessionConfiguration
    private var session: URLSession

    init(
        configuration: BridgeClientConfiguration,
        tokenProvider: @escaping BridgeTokenProvider
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = configuration.streamIdleTimeoutSeconds
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
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
                    request.timeoutInterval = requestTimeout

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw BridgeClientError.badResponse
                    }
                    try Self.validate(status: http.statusCode)

                    var idle = IdleDeadline(seconds: idleTimeout)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        try idle.touch()
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

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw BridgeClientError.badResponse
            }
            try Self.validate(status: http.statusCode)
            return data
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

/// Bounded idle watchdog for the SSE read loop: a silent socket is treated as a
/// disconnect instead of hanging the mirror until the app is killed.
private struct IdleDeadline {
    private let limit: TimeInterval
    private var started = Date()

    init(seconds: TimeInterval) {
        limit = seconds
    }

    mutating func touch() throws {
        let now = Date()
        if now.timeIntervalSince(started) > limit {
            throw BridgeClientError.streamEnded("no frames received within the idle timeout")
        }
        if now.timeIntervalSince(started) > limit / 4 {
            started = now
        }
    }
}
