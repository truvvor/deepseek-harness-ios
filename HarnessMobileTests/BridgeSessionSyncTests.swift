import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Contracts for the live (follow) half of the mirror.
///
/// The network itself is not exercised here: the follow loop reads from
/// `BridgeClient`, and the assertions below cover the two properties that make a
/// reconnect safe — idempotent appends by sequence, and the conversion applied to
/// a live `event` frame.
final class BridgeSessionSyncTests: XCTestCase {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-sync-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore(_ root: URL) -> BridgeSessionMirrorStore {
        BridgeSessionMirrorStore(fileURL: root.appendingPathComponent("bridge-sessions.json"))
    }

    private func makeEvent(
        type: String,
        seq: UInt64,
        content: String
    ) throws -> SessionEvent {
        try SessionEvent(
            type: type,
            seq: seq,
            time: 1_735_689_600_000 + Int64(seq),
            data: .object([
                "content": .array([.object(["type": .string("text"), "text": .string(content)])])
            ])
        )
    }

    // MARK: - Idempotency

    func testRepeatedAppendOfTheSameSequenceNeverDuplicatesHistory() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let sessionID = UUID()
        let first = try makeEvent(type: SessionEventVocabulary.userMessage, seq: 0, content: "one")
        let second = try makeEvent(type: SessionEventVocabulary.assistantMessage, seq: 1, content: "two")

        _ = try await repository.append(first, sessionID: sessionID)
        _ = try await repository.append(second, sessionID: sessionID)

        // A reconnect replays the same frames from `since`; the store rejects a
        // re-used sequence instead of reordering or duplicating the log.
        do {
            _ = try await repository.append(first, sessionID: sessionID)
            XCTFail("A duplicate sequence must be refused by the canonical log")
        } catch let error as SessionEventLogError {
            guard case .invalidSequence = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
        }

        let events = try await repository.allEvents(sessionID: sessionID)
        XCTAssertEqual(events.map(\.seq), [0, 1])
        XCTAssertEqual(events.count, 2)
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
        let mapping = try XCTUnwrap(
            try await reloaded.mapping(localSessionID: localSessionID)
        )
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

        XCTAssertNil(try await store.mapping(bridgeSessionID: "session-a"))
        XCTAssertNotNil(try await store.mapping(bridgeSessionID: "session-b"))
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
