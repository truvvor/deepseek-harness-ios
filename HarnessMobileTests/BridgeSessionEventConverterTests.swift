import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Contract tests for the canonical DeepSeek Harness **v4 JSONL** session export
/// as converted into the app's local trajectory representation.
///
/// All input is synthetic (`HarnessMobileTests/Fixtures/desktop-session-export-v4.jsonl`):
/// no real desktop log, no personal data, no credential.
final class BridgeSessionEventConverterTests: XCTestCase {
    private func fixtureData(
        _ name: String = "desktop-session-export-v4"
    ) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("\(name).jsonl")
        return try Data(contentsOf: url)
    }

    private func line(_ json: String) -> Data {
        Data((json + "\n").utf8)
    }

    // MARK: - Fixture contract

    func testFixtureExportConvertsHeaderEventsAndDropsTheHeaderLine() throws {
        let report = try BridgeSessionEventConverter.decodeLog(try fixtureData())

        XCTAssertEqual(report.header?.id, "session-3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411")
        XCTAssertEqual(report.header?.version, 4)
        XCTAssertEqual(report.header?.cwd, "/home/example/project")
        XCTAssertEqual(report.header?.sessionUUID?.uuidString.lowercased(), "3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411")

        // The `{"type":"session"}` header is not an event and must be dropped.
        XCTAssertEqual(report.events.count, 10)
        XCTAssertFalse(report.renumberedSequences)
        XCTAssertEqual(report.lastBridgeSequence, 9)
        XCTAssertEqual(report.unknownEventTypes, ["fixture/telemetry-note"])
        // The fixture's replacement is well formed, so nothing is rejected.
        XCTAssertEqual(report.droppedSurfaceOperations, 0)

        XCTAssertEqual(report.events.map(\.seq), Array(0..<10).map(UInt64.init))
        XCTAssertEqual(report.events.first?.type, "session/title")
        XCTAssertEqual(report.events.last?.type, "turn/end")
    }

    /// The desktop is the master and its GUI renders the whole log, so a mirror
    /// must not carry `surfaceOp.replace`: otherwise a compaction on the desktop
    /// hides everything it replaced and the phone shows a fraction of the
    /// conversation.
    func testFixtureReplacementIsParsedButNotAppliedToTheMirror() throws {
        let report = try BridgeSessionEventConverter.decodeLog(try fixtureData())
        let replacementSource = try XCTUnwrap(report.events.first(where: { $0.seq == 7 }))

        XCTAssertEqual(replacementSource.surfaceOp, .append)
        let encoded = try JSONEncoder().encode(replacementSource)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNil(object["surfaceOp"])

        // Every mirrored event is append-only, so the desktop's history survives
        // in log order.
        XCTAssertTrue(report.events.allSatisfy { $0.surfaceOp == .append })
    }

    func testFixtureUnknownTypeIsAdmittedAsIgnorable() throws {
        let report = try BridgeSessionEventConverter.decodeLog(try fixtureData())
        let unknown = try XCTUnwrap(
            report.events.first(where: { $0.type == "fixture/telemetry-note" })
        )
        XCTAssertTrue(unknown.isIgnorable)

        // Known vocabulary keeps the app's normal, non-ignorable envelope.
        let known = try XCTUnwrap(report.events.first(where: { $0.type == "turn/start" }))
        XCTAssertNil(known.ignorable)
        XCTAssertFalse(known.isIgnorable)
    }

    /// The whole point of the conversion: the app's own store accepts the result
    /// and the conversation projection agrees with the desktop surface.
    func testConvertedFixtureRendersThroughTrajectoryStoreAndProjection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-converter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let sessionID = UUID()
        let report = try BridgeSessionEventConverter.decodeLog(try fixtureData())

        let admitted = try await repository.admitSyncEnvelope(
            try HarnessSyncEnvelope(
                sessionID: sessionID,
                baseSequence: .max,
                events: report.events,
                metadata: ["transport": "dsh-api-bridge"]
            )
        )
        XCTAssertEqual(admitted.count, report.events.count)

        let persisted = try await repository.allEvents(sessionID: sessionID)
        let messages = SessionTrajectoryConversationProjection.messages(from: persisted)

        // The fixture has five message events (user, assistant with a tool
        // call, tool result, draft, final). A mirror is append-only, so the
        // desktop's replacement at seq 7 does not remove the draft: the phone
        // must show the same history the desktop GUI shows.
        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages.first?.content, "Summarise the fixture file.")
        XCTAssertEqual(messages.last?.content, "Final answer.")
        XCTAssertTrue(
            messages.contains { $0.content.contains("replaces") },
            "A compacted desktop message must survive into the mirror."
        )
    }

    // MARK: - Standalone conversion contracts

    func testEmptyPayloadAndHeaderOnlyPayloadAreRejected() throws {
        XCTAssertThrowsError(try BridgeSessionEventConverter.decodeLog(Data())) { error in
            XCTAssertEqual(error as? BridgeLogConversionError, .emptyLog)
        }
        let headerOnly = line(
            #"{"type":"session","version":4,"id":"session-00000000-0000-4000-8000-000000000000"}"#
        )
        XCTAssertThrowsError(try BridgeSessionEventConverter.decodeLog(headerOnly)) { error in
            XCTAssertEqual(error as? BridgeLogConversionError, .emptyLog)
        }
    }

    func testMalformedEventLineIsRejectedWithItsLineNumber() {
        let payload = line(#"{"type":"turn/start","seq":0,"time":1,"data":{}}"#)
            + Data("not json\n".utf8)
        XCTAssertThrowsError(try BridgeSessionEventConverter.decodeLog(payload)) { error in
            XCTAssertEqual(error as? BridgeLogConversionError, .malformedEvent(line: 2))
        }
    }

    func testSecondHeaderIsRejected() {
        let payload = line(#"{"type":"turn/start","seq":0,"time":1,"data":{}}"#)
            + line(#"{"type":"session","version":4,"id":"session-00000000-0000-4000-8000-000000000000"}"#)
        XCTAssertThrowsError(try BridgeSessionEventConverter.decodeLog(payload)) { error in
            XCTAssertEqual(error as? BridgeLogConversionError, .malformedHeader)
        }
    }

    func testSparseSequenceLogIsRenumberedAndStaysAppendOnly() throws {
        // A sparse log cannot enter the local append-only store, so the converter
        // renumbers in file order. Replacements are never installed on a mirror,
        // so a compacted desktop session keeps every message.
        let payload = line(#"{"type":"turn/start","seq":5,"time":1,"data":{"turn":1}}"#)
            + line(#"{"type":"user/message","seq":9,"time":2,"data":{"content":[{"type":"text","text":"hello"}]}}"#)
            + line(#"{"type":"assistant/message","seq":20,"time":3,"data":{"message":{"content":[{"type":"text","text":"hi"}]}}}"#)
            + line(#"{"type":"assistant/message","seq":31,"time":4,"data":{"message":{"content":[{"type":"text","text":"final"}]}},"surfaceOp":{"op":"replace","startSeq":20,"endSeq":20}}"#)
            + line(#"{"type":"turn/end","seq":47,"time":5,"data":{"turn":1,"reason":{"kind":"completed"}}}"#)

        let report = try BridgeSessionEventConverter.decodeLog(payload)

        XCTAssertTrue(report.renumberedSequences)
        XCTAssertEqual(report.events.map(\.seq), [0, 1, 2, 3, 4])
        XCTAssertEqual(report.lastBridgeSequence, 47)
        XCTAssertEqual(report.events[3].surfaceOp, .append)
        XCTAssertEqual(report.droppedSurfaceOperations, 0)
    }

    func testReplacementRangeOutsideTheLogIsDroppedAndReported() throws {
        let payload = line(#"{"type":"assistant/message","seq":0,"time":1,"data":{"message":{"content":[]}}}"#)
            + line(#"{"type":"assistant/message","seq":1,"time":2,"data":{"message":{"content":[]}}}"#)
            + line(#"{"type":"assistant/message","seq":2,"time":3,"data":{"message":{"content":[]}},"surfaceOp":{"op":"replace","startSeq":900,"endSeq":901}}"#)

        let report = try BridgeSessionEventConverter.decodeLog(payload)

        XCTAssertEqual(report.droppedSurfaceOperations, 1)
        XCTAssertNil(report.events.last?.surfaceOp)
        // The event itself is still imported: one unmappable range must not
        // discard a session.
        XCTAssertEqual(report.events.count, 3)
    }

    func testForwardReachingReplacementIsDropped() throws {
        let payload = line(#"{"type":"assistant/message","seq":0,"time":1,"data":{"message":{"content":[]}}}"#)
            + line(#"{"type":"assistant/message","seq":1,"time":2,"data":{"message":{"content":[]}},"surfaceOp":{"op":"replace","startSeq":0,"endSeq":1}}"#)

        let report = try BridgeSessionEventConverter.decodeLog(payload)

        XCTAssertEqual(report.droppedSurfaceOperations, 1)
        XCTAssertNil(report.events.last?.surfaceOp)
    }

    func testOlderStartEndSpellingIsStillAccepted() throws {
        let payload = line(#"{"type":"assistant/message","seq":0,"time":1,"data":{"message":{"content":[]}}}"#)
            + line(#"{"type":"assistant/message","seq":1,"time":2,"data":{"message":{"content":[]}}}"#)
            + line(#"{"type":"assistant/message","seq":2,"time":3,"data":{"message":{"content":[]}},"surfaceOp":{"op":"replace","start":0,"end":1}}"#)

        let report = try BridgeSessionEventConverter.decodeLog(payload)

        // The older spelling parses without being rejected, and — like every
        // replacement — is still not installed on a mirror.
        XCTAssertEqual(report.events.last?.surfaceOp, .append)
        XCTAssertEqual(report.droppedSurfaceOperations, 0)
    }

    func testPlainAppendStringAndMissingSurfaceOperationBothMeanAppend() throws {
        let payload = line(#"{"type":"assistant/message","seq":0,"time":1,"data":{"message":{"content":[]}},"surfaceOp":"append"}"#)
            + line(#"{"type":"assistant/message","seq":1,"time":2,"data":{"message":{"content":[]}}}"#)

        let report = try BridgeSessionEventConverter.decodeLog(payload)

        XCTAssertNil(report.events[0].surfaceOp)
        XCTAssertNil(report.events[1].surfaceOp)
        XCTAssertEqual(report.droppedSurfaceOperations, 0)
    }

    func testDuplicateSequenceLogIsRenumberedSoAdmissionStaysContiguous() throws {
        let payload = line(#"{"type":"turn/start","seq":0,"time":1,"data":{"turn":1}}"#)
            + line(#"{"type":"turn/start","seq":0,"time":2,"data":{"turn":2}}"#)

        let report = try BridgeSessionEventConverter.decodeLog(payload)

        XCTAssertTrue(report.renumberedSequences)
        XCTAssertEqual(report.events.map(\.seq), [0, 1])
    }

    func testOversizedLogIsRejectedBeforeParsing() {
        let oversized = Data(repeating: 0x41, count: BridgeSessionEventConverter.maximumLogBytes + 1)
        XCTAssertThrowsError(try BridgeSessionEventConverter.decodeLog(oversized)) { error in
            XCTAssertEqual(
                error as? BridgeLogConversionError,
                .logTooLarge(BridgeSessionEventConverter.maximumLogBytes)
            )
        }
    }

    func testTooManyEventsAreRejected() {
        // Built here instead of committed as a fixture: the limit is what matters,
        // not the file.
        var payload = Data()
        for sequence in 0...BridgeSessionEventConverter.maximumEvents {
            payload.append(Data("{\"type\":\"turn/start\",\"seq\":\(sequence),\"time\":1,\"data\":{\"turn\":1}}\n".utf8))
        }
        XCTAssertThrowsError(try BridgeSessionEventConverter.decodeLog(payload)) { error in
            XCTAssertEqual(
                error as? BridgeLogConversionError,
                .tooManyEvents(BridgeSessionEventConverter.maximumEvents)
            )
        }
    }

    func testNegativeTimeIsClampedToZeroAndMissingTimeIsFilled() throws {
        let payload = line(#"{"type":"turn/start","seq":0,"time":-5,"data":{"turn":1}}"#)
            + line(#"{"type":"turn/start","seq":1,"time":0,"data":{"turn":2}}"#)
        let report = try BridgeSessionEventConverter.decodeLog(payload)

        XCTAssertEqual(report.events.first?.time, 0)
        XCTAssertGreaterThan(report.events[1].time, 0, "A zero timestamp is replaced by the import clock")
    }
}
