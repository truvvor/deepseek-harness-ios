import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Contracts for the live (follow) half of the mirror.
///
/// The network itself is not exercised here. The follow loop treats SSE frames
/// only as a change signal and refreshes the mirror from the lossless export,
/// so the assertions cover when a refresh happens, how reconnects are paced,
/// and the frame conversion helpers.
final class BridgeSessionSyncTests: XCTestCase {
    private static let bridgeSessionID = "session-3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411"

    private actor CountingRefresher: BridgeMirrorRefreshing {
        private(set) var refreshedSessionIDs: [String] = []

        func refreshMirror(bridgeSessionID: String) async throws {
            refreshedSessionIDs.append(bridgeSessionID)
        }
    }

    /// Advances only when told to, so the refresh rate limit is deterministic.
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_735_689_600)

        func now() -> Date {
            lock.lock(); defer { lock.unlock() }
            return current
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
        }
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-sync-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore(_ root: URL) -> BridgeSessionMirrorStore {
        BridgeSessionMirrorStore(fileURL: root.appendingPathComponent("bridge-sessions.json"))
    }

    private func makeSync(
        refresher: CountingRefresher,
        root: URL
    ) throws -> BridgeSessionSync {
        let client = BridgeClient(
            configuration: try BridgeClientConfiguration(
                settings: BridgeSettings(
                    baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:19387")),
                    isEnabled: true
                )
            ),
            tokenProvider: { "bridge-sync-test-token" }
        )
        return BridgeSessionSync(client: client, refresher: refresher, mappings: makeStore(root))
    }

    private func frames(_ json: [String]) throws -> AsyncThrowingStream<BridgeStreamFrame, Error> {
        let decoded = try json.map {
            try JSONDecoder().decode(BridgeStreamFrame.self, from: Data($0.utf8))
        }
        return AsyncThrowingStream { continuation in
            for frame in decoded { continuation.yield(frame) }
            continuation.finish()
        }
    }

    private func eventFrame(_ seq: Int) -> String {
        #"{"type":"event","sessionId":"s","seq":"# + String(seq)
            + #","time":1735689600200,"eventType":"assistant/chunk","role":"assistant","content":"x"}"#
    }

    // MARK: - Refresh signalling

    func testDurableEventsRefreshFromTheExportAndARefreshIsRateLimitedWithinATurn() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let refresher = CountingRefresher()
        let sync = try makeSync(refresher: refresher, root: root)
        let clock = ManualClock()

        let pass = try await sync.consume(
            try frames([
                #"{"type":"snapshot","sessionId":"s","throughSeq":9}"#,
                eventFrame(10),
                eventFrame(11),
                eventFrame(12),
                #"{"type":"turn/end","sessionId":"s","reason":"stop"}"#,
                #"{"type":"closed","sessionId":"s"}"#
            ]),
            bridgeSessionID: Self.bridgeSessionID,
            importedThrough: 9,
            now: { clock.now() }
        )

        XCTAssertTrue(pass.sawEvents)
        XCTAssertTrue(pass.refreshed)
        // Seq 10 refreshes at once; 11 and 12 fall inside the rate limit and are
        // flushed together by `turn/end`.
        let refreshed = await refresher.refreshedSessionIDs
        XCTAssertEqual(refreshed, [Self.bridgeSessionID, Self.bridgeSessionID])
    }

    func testSnapshotAheadOfTheMirrorCatchesUpButACurrentSnapshotDoesNot() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let refresher = CountingRefresher()
        let sync = try makeSync(refresher: refresher, root: root)

        let current = try await sync.consume(
            try frames([
                #"{"type":"snapshot","sessionId":"s","throughSeq":9}"#,
                #"{"type":"closed","sessionId":"s"}"#
            ]),
            bridgeSessionID: Self.bridgeSessionID,
            importedThrough: 9
        )
        XCTAssertFalse(current.sawEvents)
        let afterCurrent = await refresher.refreshedSessionIDs
        XCTAssertTrue(afterCurrent.isEmpty)

        let behind = try await sync.consume(
            try frames([#"{"type":"snapshot","sessionId":"s","throughSeq":14}"#]),
            bridgeSessionID: Self.bridgeSessionID,
            importedThrough: 9
        )
        XCTAssertTrue(behind.sawEvents)
        let afterBehind = await refresher.refreshedSessionIDs
        XCTAssertEqual(afterBehind.count, 1)
    }

    func testTransientFramesNeverRefreshAndAnErrorFrameFailsTheConnection() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let refresher = CountingRefresher()
        let sync = try makeSync(refresher: refresher, root: root)

        do {
            _ = try await sync.consume(
                try frames([
                    #"{"type":"delta","sessionId":"s","text":"partial"}"#,
                    #"{"type":"usage","sessionId":"s"}"#,
                    #"{"type":"error","sessionId":"s","message":"session closed on desktop"}"#
                ]),
                bridgeSessionID: Self.bridgeSessionID,
                importedThrough: 3
            )
            XCTFail("An error frame must end the connection with an error")
        } catch {
            XCTAssertEqual(
                error as? BridgeClientError,
                .streamEnded("session closed on desktop")
            )
        }
        let refreshed = await refresher.refreshedSessionIDs
        XCTAssertTrue(refreshed.isEmpty)
    }

    // MARK: - Reconnect pacing

    func testIdleAndFailingConnectionsBackOffInsteadOfPollingInATightLoop() {
        XCTAssertEqual(BridgeSessionSync.reconnectDelay(consecutiveFailures: 0, consecutiveIdlePasses: 0), 0.5)
        XCTAssertEqual(BridgeSessionSync.reconnectDelay(consecutiveFailures: 0, consecutiveIdlePasses: 1), 2)
        XCTAssertEqual(BridgeSessionSync.reconnectDelay(consecutiveFailures: 0, consecutiveIdlePasses: 3), 8)
        XCTAssertEqual(BridgeSessionSync.reconnectDelay(consecutiveFailures: 0, consecutiveIdlePasses: 50), 32)
        XCTAssertEqual(BridgeSessionSync.reconnectDelay(consecutiveFailures: 1, consecutiveIdlePasses: 0), 1)
        XCTAssertEqual(BridgeSessionSync.reconnectDelay(consecutiveFailures: 4, consecutiveIdlePasses: 9), 8)
        XCTAssertEqual(BridgeSessionSync.reconnectDelay(consecutiveFailures: 50, consecutiveIdlePasses: 0), 16)
    }

    // MARK: - Live frame conversion

    func testLiveEventFrameConvertsIntoALocalSessionEvent() throws {
        let frame = try JSONDecoder().decode(
            BridgeStreamFrame.self,
            from: Data(#"{"type":"event","sessionId":"s","seq":12,"time":1735689600200,"eventType":"user/message","role":"user","content":"hello"}"#.utf8)
        )
        let event = try BridgeSessionEventConverter.makeEvent(
            type: try XCTUnwrap(frame.eventType),
            seq: try XCTUnwrap(frame.seq),
            time: try XCTUnwrap(frame.time),
            data: .object([
                "role": .string(try XCTUnwrap(frame.role)),
                "content": .string(try XCTUnwrap(frame.content))
            ]),
            isKnown: BridgeSessionEventConverter.isKnownEventType(
                try XCTUnwrap(frame.eventType)
            ),
            surfaceStart: nil,
            surfaceEnd: nil
        )

        XCTAssertEqual(event.type, "user/message")
        XCTAssertEqual(event.seq, 12)
        XCTAssertEqual(event.time, 1_735_689_600_200)
        XCTAssertEqual(event.data.objectValue?["role"]?.stringValue, "user")
        XCTAssertNil(event.surfaceOp, "A live frame must stay append-only")
    }

    func testLiveFrameOfAnUnknownTypeIsAdmittedAsIgnorable() throws {
        let event = try BridgeSessionEventConverter.makeEvent(
            type: "future/event-kind",
            seq: 3,
            time: 1,
            data: .object([:]),
            isKnown: BridgeSessionEventConverter.isKnownEventType("future/event-kind"),
            surfaceStart: nil,
            surfaceEnd: nil
        )
        XCTAssertTrue(event.isIgnorable)
    }

    func testForwardReachingReplacementIsNeverRepresentedLocally() throws {
        // `SessionEvent.validateEnvelope` rejects a replacement that reaches
        // forward, so the helper must drop the range instead of producing an
        // event the store cannot admit.
        let event = try BridgeSessionEventConverter.makeEvent(
            type: SessionEventVocabulary.assistantMessage,
            seq: 1,
            time: 1,
            data: .object(["message": .object(["content": .array([])])]),
            isKnown: true,
            surfaceStart: 0,
            surfaceEnd: 1
        )
        XCTAssertNil(event.surfaceOp)
    }

    // MARK: - Follow position

    func testFollowPositionPersistsAndSurvivesAFreshStoreInstance() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        let localSessionID = UUID()

        try await store.record(
            BridgeSessionMapping(
                bridgeSessionID: "session-3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411",
                localSessionID: localSessionID,
                title: "Desktop work",
                createdAt: Date(timeIntervalSince1970: 1_735_689_600),
                updatedAt: Date(timeIntervalSince1970: 1_735_689_600),
                importedThroughBridgeSeq: -1,
                importedEventCount: 0
            )
        )

        try await store.updateFollowPosition(
            bridgeSessionID: "session-3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411",
            importedThroughBridgeSeq: 9,
            importedEventCount: 10
        )

        let reloaded = makeStore(root)
        let reloadedMapping = try await reloaded.mapping(localSessionID: localSessionID)
        let mapping = try XCTUnwrap(reloadedMapping)
        XCTAssertEqual(mapping.importedThroughBridgeSeq, 9)
        XCTAssertEqual(mapping.importedEventCount, 10)
        // `since = throughSeq` is what a reconnect passes back to the bridge.
        XCTAssertEqual(mapping.importedThroughBridgeSeq, 9)
    }

    func testRecordingTheSameDesktopSessionTwiceKeepsOneLocalIdentity() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)

        let mapping = BridgeSessionMapping(
            bridgeSessionID: "session-3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411",
            localSessionID: UUID(),
            title: "Desktop work",
            createdAt: .now,
            updatedAt: .now,
            importedThroughBridgeSeq: 3,
            importedEventCount: 4
        )
        try await store.record(mapping)

        var grown = mapping
        grown.importedThroughBridgeSeq = 7
        grown.importedEventCount = 8
        grown.title = "Renamed on desktop"
        try await store.record(grown)

        let all = try await store.allMappings()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.localSessionID, mapping.localSessionID)
        XCTAssertEqual(all.first?.title, "Renamed on desktop")
        XCTAssertEqual(all.first?.importedThroughBridgeSeq, 7)
    }

    func testForgettingAMappingDropsOnlyThatRow() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)

        for identifier in ["session-a", "session-b"] {
            try await store.record(
                BridgeSessionMapping(
                    bridgeSessionID: identifier,
                    localSessionID: UUID(),
                    title: identifier,
                    createdAt: .now,
                    updatedAt: .now,
                    importedThroughBridgeSeq: 0,
                    importedEventCount: 1
                )
            )
        }

        try await store.forget(bridgeSessionID: "session-a")

        let forgotten = try await store.mapping(bridgeSessionID: "session-a")
        let kept = try await store.mapping(bridgeSessionID: "session-b")
        XCTAssertNil(forgotten)
        XCTAssertNotNil(kept)
    }

    func testUnreadableMappingFileFailsClosed() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("bridge-sessions.json")
        try Data("not-json".utf8).write(to: fileURL)

        let store = BridgeSessionMirrorStore(fileURL: fileURL)
        do {
            _ = try await store.allMappings()
            XCTFail("A corrupt mirror map must not be treated as empty")
        } catch {
            XCTAssertEqual(error as? BridgeSessionMappingError, .unreadableStore)
        }
    }

    func testUnsupportedMappingVersionFailsClosed() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("bridge-sessions.json")
        try Data(#"{"version":99,"mappings":[],"updatedAt":"2025-01-01T00:00:00Z"}"#.utf8)
            .write(to: fileURL)

        let store = BridgeSessionMirrorStore(fileURL: fileURL)
        do {
            _ = try await store.allMappings()
            XCTFail("An unknown mirror map version must not be read as empty")
        } catch {
            XCTAssertEqual(error as? BridgeSessionMappingError, .unsupportedVersion(99))
        }
    }

    func testBridgeLocationErrorsDescribeThemselves() {
        let identifier = UUID()
        XCTAssertEqual(
            BridgeFollowError.mirrorNotFound(identifier).errorDescription?.contains(
                identifier.uuidString
            ),
            true
        )
        XCTAssertNotNil(BridgeFollowError.notConfigured.errorDescription)
        XCTAssertNotNil(BridgeImportError.trajectoryHasAssetsOrTombstones.errorDescription)
        XCTAssertNotNil(BridgeSettingsError.sessionNotMapped("session-x").errorDescription)
    }
}
