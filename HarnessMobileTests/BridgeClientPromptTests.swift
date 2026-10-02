import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Wire contract of the two desktop-turn routes (DECISIONS D-014):
/// `POST /bridge/v1/sessions/{id}/prompt` and `POST …/cancel`. Driven through a
/// stub `URLProtocol`; the token is fake and no socket is opened.
final class BridgeClientPromptTests: XCTestCase {
    private static let fixtureToken = "fixture-token-not-a-real-credential"
    private let desktopSessionID = "session-ef73f246-d32b-417e-a241-2731b26044f2"

    override func tearDown() {
        BridgePromptURLProtocolStub.handler = nil
        super.tearDown()
    }

    private func makeClient() throws -> BridgeClient {
        BridgeClient(
            configuration: try BridgeClientConfiguration(
                settings: BridgeSettings(
                    baseURL: try XCTUnwrap(URL(string: "http://192.0.2.10:19387")),
                    isEnabled: true
                )
            ),
            tokenProvider: { Self.fixtureToken },
            protocolClasses: [BridgePromptURLProtocolStub.self]
        )
    }

    private static func response(_ request: URLRequest, status: Int, json: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    func testPromptPostsTextAndModeWithBearerTokenAndDecodesTheTurnSummary() async throws {
        let captured = CapturedRequest()
        BridgePromptURLProtocolStub.handler = { request in
            captured.store(request)
            return Self.response(request, status: 200, json: #"""
            {"sessionId":"session-ef73f246-d32b-417e-a241-2731b26044f2","text":"test",
             "usage":{"inputTokens":86154,"outputTokens":3,"totalTokens":86669},"completed":true}
            """#)
        }

        let result = try await makeClient().prompt(sessionID: desktopSessionID, text: "Answer in one word: test")

        XCTAssertEqual(result.sessionID, desktopSessionID)
        XCTAssertEqual(result.text, "test")
        XCTAssertEqual(result.completed, true)
        let request = try XCTUnwrap(captured.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://192.0.2.10:19387/bridge/v1/sessions/\(desktopSessionID)/prompt"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.fixtureToken)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertGreaterThanOrEqual(request.timeoutInterval, BridgeClient.promptTimeoutSeconds)
        let body = try XCTUnwrap(captured.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["text": "Answer in one word: test", "mode": "queue"])
    }

    func testSteerModeIsSentVerbatim() async throws {
        let captured = CapturedRequest()
        BridgePromptURLProtocolStub.handler = { request in
            captured.store(request)
            return Self.response(request, status: 200, json: #"{"completed":true}"#)
        }

        _ = try await makeClient().prompt(sessionID: desktopSessionID, text: "stop and summarize", mode: .steer)

        let body = try XCTUnwrap(captured.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object["mode"], "steer")
    }

    func testBusyDesktopAgentMapsToARejectionWithItsCode() async throws {
        BridgePromptURLProtocolStub.handler = { request in
            Self.response(request, status: 409, json: #"""
            {"error":{"message":"agent busy","code":"session/agent-busy","type":"dsh_error"}}
            """#)
        }

        do {
            _ = try await makeClient().prompt(sessionID: desktopSessionID, text: "hello")
            XCTFail("A 409 must not read as a completed turn")
        } catch let error as BridgeClientError {
            XCTAssertEqual(error, .rejected(status: 409, code: "session/agent-busy", message: "agent busy"))
            XCTAssertEqual(
                error.errorDescription,
                "The desktop agent is already running a turn in this session."
            )
        }
    }

    func testCancelPostsWithoutABodyAndAcceptsTheAcknowledgement() async throws {
        let captured = CapturedRequest()
        BridgePromptURLProtocolStub.handler = { request in
            captured.store(request)
            return Self.response(
                request,
                status: 200,
                json: #"{"accepted":true,"sessionId":"session-ef73f246-d32b-417e-a241-2731b26044f2"}"#
            )
        }

        try await makeClient().cancel(sessionID: desktopSessionID)

        let request = try XCTUnwrap(captured.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/bridge/v1/sessions/\(desktopSessionID)/cancel")
        XCTAssertNil(captured.body)
    }

    func testCancelOfASessionThatIsNotLiveReportsNotOpenOnTheDesktop() async throws {
        BridgePromptURLProtocolStub.handler = { request in
            Self.response(request, status: 404, json: #"""
            {"error":{"message":"session \"session-x\" not found (not attached)","code":"session/not-found","type":"dsh_error","stack":"..."}}
            """#)
        }

        do {
            try await makeClient().cancel(sessionID: desktopSessionID)
            XCTFail("A 404 must surface")
        } catch let error as BridgeClientError {
            XCTAssertEqual(error.errorDescription, "The desktop session is not open on the desktop host.")
        }
    }

    func testUnauthorizedKeepsItsDedicatedErrorEvenWithAnErrorBody() async throws {
        BridgePromptURLProtocolStub.handler = { request in
            Self.response(request, status: 401, json: #"{"error":{"message":"bad token","code":"auth/invalid"}}"#)
        }

        do {
            _ = try await makeClient().prompt(sessionID: desktopSessionID, text: "hello")
            XCTFail("A 401 must surface")
        } catch let error as BridgeClientError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testHealthWithoutAStatusFieldReadsAsReachable() throws {
        let health = try JSONDecoder().decode(
            BridgeSessionHealth.self,
            from: Data(#"{"build":"rev-2026-10-02-j","services":{"sessionController":true}}"#.utf8)
        )
        XCTAssertEqual(health.displayStatus, "reachable")

        let ok = try JSONDecoder().decode(BridgeSessionHealth.self, from: Data(#"{"ok":true}"#.utf8))
        XCTAssertTrue(ok.isHealthy)
        XCTAssertEqual(ok.displayStatus, "ok")
    }
}

private final class CapturedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?
    private var storedBody: Data?

    func store(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        storedRequest = request
        storedBody = request.httpBody ?? request.httpBodyStream.flatMap(Self.drain)
    }

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    var body: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedBody
    }

    private static func drain(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}

private final class BridgePromptURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
