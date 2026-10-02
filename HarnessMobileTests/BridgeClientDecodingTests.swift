import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Decoding and configuration contracts for the desktop bridge wire. Every
/// payload below is synthetic; the bearer values are obviously fake and are never
/// part of a fixture file.
final class BridgeClientDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - BridgeSettings

    func testBaseURLNormalizationAcceptsLocalHTTPAndAppendsBridgePath() throws {
        let bare = try BridgeSettings.validatedBaseURL(
            try XCTUnwrap(URL(string: "http://192.0.2.10:19387"))
        )
        XCTAssertEqual(bare.absoluteString, "http://192.0.2.10:19387/bridge/v1")

        let withSlash = try BridgeSettings.validatedBaseURL(
            try XCTUnwrap(URL(string: "http://192.0.2.10:19387/"))
        )
        XCTAssertEqual(withSlash.absoluteString, "http://192.0.2.10:19387/bridge/v1")

        let alreadyVersioned = try BridgeSettings.validatedBaseURL(
            try XCTUnwrap(URL(string: "https://desk.tailnet.example/bridge/v1"))
        )
        XCTAssertEqual(alreadyVersioned.absoluteString, "https://desk.tailnet.example/bridge/v1")
    }

    func testBaseURLRejectsCredentialsQueryFragmentAndUnsupportedScheme() {
        let rejected = [
            "ftp://192.0.2.10:19387",
            "http://user:pass@192.0.2.10:19387",
            "http://192.0.2.10:19387?token=fake",
            "http://192.0.2.10:19387#fragment",
            "http://"
        ]
        for raw in rejected {
            guard let url = URL(string: raw) else { continue }
            XCTAssertThrowsError(
                try BridgeSettings.validatedBaseURL(url),
                "Expected \(raw) to be rejected"
            ) { error in
                XCTAssertEqual(error as? BridgeSettingsError, .invalidBaseURL)
            }
        }
    }

    func testDisabledOrInvalidSettingsHaveNoActiveBaseURL() throws {
        var settings = BridgeSettings(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:19387")))
        XCTAssertNil(settings.activeBaseURL, "A disabled bridge must produce no address at all.")

        settings.isEnabled = true
        XCTAssertEqual(settings.activeBaseURL?.absoluteString, "http://127.0.0.1:19387/bridge/v1")
        XCTAssertEqual(settings.displayHost, "127.0.0.1:19387")
    }

    func testPersistedSettingsWithoutNewFieldsDecodeWithSafeDefaults() throws {
        // A row written before the follow preference existed.
        let legacy = Data(#"{"baseURL":"http://127.0.0.1:19387","isEnabled":true,"includesArchivedSessions":true}"#.utf8)
        let decoded = try JSONDecoder().decode(BridgeSettings.self, from: legacy)

        XCTAssertTrue(decoded.isEnabled)
        XCTAssertTrue(decoded.includesArchivedSessions)
        XCTAssertFalse(decoded.followsSelectedMirrorAutomatically)
        XCTAssertEqual(decoded.requestTimeoutSeconds, BridgeSettings.defaultRequestTimeoutSeconds)
        XCTAssertEqual(decoded.streamIdleTimeoutSeconds, BridgeSettings.defaultStreamIdleTimeoutSeconds)
    }

    func testOutOfBoundsTimeoutsFallBackOnValidation() throws {
        var settings = BridgeSettings(
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:19387")),
            isEnabled: true,
            requestTimeoutSeconds: 0,
            streamIdleTimeoutSeconds: 100_000
        )
        settings = try settings.validated()

        XCTAssertEqual(settings.requestTimeoutSeconds, BridgeSettings.defaultRequestTimeoutSeconds)
        XCTAssertEqual(settings.streamIdleTimeoutSeconds, BridgeSettings.defaultStreamIdleTimeoutSeconds)
    }

    func testSettingsRoundTripThroughSettingsStore() throws {
        let suiteName = "com.llf.harnessmobile.bridge.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)

        // Nothing configured yet: the mirror must be off, not "on by accident".
        XCTAssertEqual(store.loadBridgeSettings(), BridgeSettings())

        let settings = BridgeSettings(
            baseURL: try XCTUnwrap(URL(string: "http://192.0.2.10:19387")),
            isEnabled: true,
            includesArchivedSessions: true,
            followsSelectedMirrorAutomatically: true
        )
        try store.saveBridgeSettings(settings)
        XCTAssertEqual(store.loadBridgeSettings(), settings)

        // A damaged row must fall back to the disabled defaults.
        defaults.set(Data("not-json".utf8), forKey: "bridge.desktop-mirror.v1")
        XCTAssertEqual(store.loadBridgeSettings(), BridgeSettings())
    }

    func testBridgeSettingsNeverEncodeABearerToken() throws {
        // Structural guard: the persisted settings type has no credential field,
        // so the token cannot reach UserDefaults by accident.
        let settings = BridgeSettings(
            baseURL: try XCTUnwrap(URL(string: "http://192.0.2.10:19387")),
            isEnabled: true
        )
        let encoded = try JSONEncoder().encode(settings)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.lowercased().contains("token"))
        XCTAssertFalse(text.lowercased().contains("bearer"))
        XCTAssertFalse(text.lowercased().contains("authorization"))
    }

    func testCredentialStoreUsesDedicatedBridgeAccount() {
        XCTAssertEqual(CredentialStore.bridgeTokenAccount, "desktop-bridge-token")
        XCTAssertFalse(CredentialStore.bridgeTokenAccount.hasPrefix("model-api-key"))
    }

    // MARK: - Session list

    func testSessionListDecodesTitlesArchiveStateAndCamelCasedIDs() throws {
        let json = """
        {"object":"list","data":[
          {"sessionId":"session-3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411","title":"Desktop work",
           "updatedAt":1735689600000,"running":false,"blank":false,"archived":false,
           "cwd":"/home/example/project","origin":"desktop"},
          {"sessionId":"session-00000000-0000-4000-8000-000000000001","updatedAt":1735689500000,
           "archived":true,"parentSessionId":"session-3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411"}
        ]}
        """
        let response = try decode(BridgeSessionListResponse.self, json)

        XCTAssertEqual(response.object, "list")
        XCTAssertEqual(response.data.count, 2)
        XCTAssertEqual(response.data[0].sessionID, "session-3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411")
        XCTAssertEqual(response.data[0].displayTitle, "Desktop work")
        XCTAssertFalse(response.data[0].isArchived)
        XCTAssertEqual(response.data[0].cwd, "/home/example/project")
        XCTAssertTrue(response.data[1].isArchived)
        // A title-less session falls back to its id rather than to an empty label.
        XCTAssertEqual(response.data[1].displayTitle, response.data[1].sessionID)
        XCTAssertEqual(
            response.data[1].parentSessionID,
            "session-3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411"
        )
    }

    func testSessionListDecodesEmptyData() throws {
        let response = try decode(BridgeSessionListResponse.self, #"{"object":"list","data":[]}"#)
        XCTAssertTrue(response.data.isEmpty)
    }

    // MARK: - Messages

    func testMessagePageDecodesRolesAndOptionalFields() throws {
        let json = """
        {"sessionId":"session-3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411","throughSeq":9,"hasMore":false,
         "messages":[
           {"role":"user","content":"hello","seq":2,"time":1735689600200},
           {"role":"assistant","content":"hi","seq":7,"time":1735689600700,
            "model":"fixture-model","provider":"fixture","usage":{"inputTokens":10,"outputTokens":2}}
         ]}
        """
        let page = try decode(BridgeMessagePage.self, json)

        XCTAssertEqual(page.throughSeq, 9)
        XCTAssertEqual(page.hasMore, false)
        XCTAssertEqual(page.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(page.messages[1].model, "fixture-model")
        XCTAssertEqual(page.messages[1].usage?.objectValue?["inputTokens"], .number(10))
    }

    // MARK: - Stream frames

    func testStreamFrameKindsMatchTheDocumentedBridgeVocabulary() throws {
        let cases: [(String, BridgeStreamFrame.Kind)] = [
            (#"{"type":"snapshot","sessionId":"s","throughSeq":26,"messages":[]}"#, .snapshot),
            (#"{"type":"event","sessionId":"s","seq":27,"time":1,"eventType":"turn/start"}"#, .event),
            (#"{"type":"delta","sessionId":"s","text":"Pa"}"#, .delta),
            (#"{"type":"reasoning","sessionId":"s","text":"thinking"}"#, .reasoning),
            (#"{"type":"usage","sessionId":"s","usage":{"outputTokens":3}}"#, .usage),
            (#"{"type":"turn/end","sessionId":"s","seq":30,"reason":"completed"}"#, .turnEnd),
            (#"{"type":"closed","sessionId":"s","throughSeq":30}"#, .closed),
            (#"{"type":"error","sessionId":"s","message":"boom"}"#, .error),
            (#"{"type":"future-frame","sessionId":"s"}"#, .unknown("future-frame"))
        ]
        for (json, expected) in cases {
            let frame = try decode(BridgeStreamFrame.self, json)
            XCTAssertEqual(frame.kind, expected, "Unexpected kind for \(json)")
        }
    }

    func testStreamEventFrameCarriesRoleContentAndTurnEndReason() throws {
        let event = try decode(
            BridgeStreamFrame.self,
            #"{"type":"event","sessionId":"s","seq":12,"time":1735689600200,"eventType":"user/message","role":"user","content":"hello"}"#
        )
        XCTAssertEqual(event.eventType, "user/message")
        XCTAssertEqual(event.role, "user")
        XCTAssertEqual(event.content, "hello")
        XCTAssertEqual(event.seq, 12)

        // The desktop bridge reports the turn/end reason as the `reason` field.
        let turnEnd = try decode(
            BridgeStreamFrame.self,
            #"{"type":"turn/end","sessionId":"s","seq":30,"reason":"completed"}"#
        )
        XCTAssertEqual(turnEnd.reason, "completed")
        XCTAssertNil(turnEnd.message)
    }

    func testStreamFrameToleratesUnknownFieldsAndMissingOptionals() throws {
        let frame = try decode(
            BridgeStreamFrame.self,
            #"{"type":"snapshot","sessionId":"s","throughSeq":3,"extra":{"nested":true}}"#
        )
        XCTAssertEqual(frame.throughSeq, 3)
        XCTAssertNil(frame.messages)
        XCTAssertNil(frame.text)
    }

    // MARK: - Export header

    func testExportHeaderDecodesSessionPrefixAndOptionalMetadata() throws {
        let json = #"{"type":"session","version":4,"id":"session-3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411","createdAt":1735689600000,"cwd":"/home/example/project","agentPreset":"cordis","isSeeded":false,"delegationDepth":0}"#
        let header = try decode(BridgeSessionLogHeader.self, json)

        XCTAssertEqual(header.version, 4)
        XCTAssertEqual(header.agentPreset, "cordis")
        XCTAssertEqual(header.delegationDepth, 0)
        XCTAssertEqual(
            header.sessionUUID?.uuidString.lowercased(),
            "3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411"
        )
    }

    func testExportHeaderAcceptsABareUUIDAndRejectsSomethingElse() throws {
        let bare = try decode(
            BridgeSessionLogHeader.self,
            #"{"type":"session","version":4,"id":"3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411"}"#
        )
        XCTAssertEqual(bare.sessionUUID?.uuidString.lowercased(), "3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411")

        let invalid = try decode(
            BridgeSessionLogHeader.self,
            #"{"type":"session","version":4,"id":"not-a-session-id"}"#
        )
        XCTAssertNil(invalid.sessionUUID)
    }

    // MARK: - Error mapping

    func testClientErrorsExplainThemselvesWithoutLeakingTheToken() {
        let errors: [BridgeClientError] = [
            .disabled, .missingBaseURL, .missingToken, .unauthorized, .forbidden,
            .notFound, .server(status: 500), .badResponse, .decoding("T"),
            .notConnected, .transport("offline"), .cancelled, .streamEnded("die")
        ]
        for error in errors {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "\(error) needs a message")
            XCTAssertFalse(
                description.lowercased().contains("bearer "),
                "No error message may quote a bearer value."
            )
        }
        XCTAssertTrue(BridgeClientError.server(status: 500).errorDescription?.contains("500") == true)
    }
}
