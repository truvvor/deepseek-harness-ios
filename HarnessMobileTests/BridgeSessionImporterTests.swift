import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Import-path contracts for the desktop session mirror: identity mapping,
/// idempotency, the read-only provenance flag, and rollback of a partial import.
///
/// The client is a protocol-free seam: these tests drive
/// `importConverted(...)`/`importSession(...)` through a stub `URLProtocol`, so no
/// live desktop bridge and no real token is involved. The token value used by the
/// stub is deliberately fake.
final class BridgeSessionImporterTests: XCTestCase {
    private let bridgeSessionID = "session-3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411"

    /// Obviously fake, and never sent anywhere: the importer tests drive the
    /// write path directly instead of opening a socket.
    private static let fixtureToken = "fixture-token-not-a-real-credential"

    private struct Harness {
        let importer: BridgeSessionImporter
        let sessionStore: SessionStore
        let trajectory: SessionTrajectoryRepository
        let mappings: BridgeSessionMirrorStore
        let root: URL
    }

    private func fixtureData(_ name: String = "desktop-session-export-v4") throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("\(name).jsonl")
        return try Data(contentsOf: url)
    }

    private func makeHarness(protocolClasses: [AnyClass]? = nil) throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-import-\(UUID().uuidString)", isDirectory: true)
        let trajectory = SessionTrajectoryRepository(root: root)
        let sessionStore = SessionStore(root: root)
        let mappings = BridgeSessionMirrorStore(
            fileURL: root.appendingPathComponent("bridge-sessions.json")
        )
        let client = BridgeClient(
            configuration: try BridgeClientConfiguration(
                settings: BridgeSettings(
                    baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:19387")),
                    isEnabled: true
                )
            ),
            tokenProvider: { Self.fixtureToken },
            protocolClasses: protocolClasses
        )
        let importer = BridgeSessionImporter(
            client: client,
            sessionStore: sessionStore,
            trajectory: trajectory,
            queryModel: nil,
            mappings: mappings
        )
        return Harness(
            importer: importer,
            sessionStore: sessionStore,
            trajectory: trajectory,
            mappings: mappings,
            root: root
        )
    }

    private func converted(_ data: Data) throws -> BridgeSessionEventConverter.Report {
        try BridgeSessionEventConverter.decodeLog(data)
    }

    // MARK: - First import

    func testFirstImportCreatesALocalMirrorSessionWithDesktopTitleAndEvents() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let report = try converted(try fixtureData())

        let outcome = try await harness.importer.importConverted(
            bridgeSessionID: bridgeSessionID,
            listTitle: nil,
            header: report.header,
            events: report.events,
            lastBridgeSequence: report.lastBridgeSequence
        )

        guard case let .created(localSessionID) = outcome else {
            return XCTFail("Expected a newly created mirror, got \(outcome)")
        }

        let session = try await harness.sessionStore.session(id: localSessionID)
        XCTAssertEqual(session.title, "Fixture desktop session")
        // Append-only mirror: the fixture's draft answer stays next to the final
        // one, exactly as the desktop log (and its GUI) holds it.
        XCTAssertEqual(session.messages.count, 5)
        XCTAssertEqual(session.messages.first?.content, "Summarise the fixture file.")
        XCTAssertEqual(session.messages.last?.content, "Final answer.")

        let events = try await harness.trajectory.allEvents(sessionID: localSessionID)
        XCTAssertEqual(events.count, report.events.count)
        XCTAssertEqual(events.map(\.seq), report.events.map(\.seq))
    }

    // MARK: - Provenance

    func testMirrorSessionIsMarkedReadOnlyAndSaysWhereItCameFrom() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let report = try converted(try fixtureData())

        let outcome = try await harness.importer.importConverted(
            bridgeSessionID: bridgeSessionID,
            listTitle: nil,
            header: report.header,
            events: report.events,
            lastBridgeSequence: report.lastBridgeSequence
        )

        let session = try await harness.sessionStore.session(id: outcome.localSessionID)
        XCTAssertTrue(session.isDesktopMirror)
        XCTAssertEqual(session.bridgeMirror?.bridgeSessionID, bridgeSessionID)
        XCTAssertFalse(
            session.isResumable,
            "A mirror must never look resumable: the local agent loop cannot run for it."
        )

        let summary = try await harness.sessionStore.listSessions()
            .first { $0.id == outcome.localSessionID }
        XCTAssertEqual(summary?.bridgeMirror?.bridgeSessionID, bridgeSessionID)
        XCTAssertEqual(summary?.isDesktopMirror, true)
    }

    func testMirrorFlagSurvivesASnapshotRoundTripIncludingLegacyRows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let mirrorID = UUID()

        _ = try await store.createSession(
            id: mirrorID,
            title: "Desktop work",
            bridgeMirror: BridgeSessionMirror(bridgeSessionID: bridgeSessionID),
            makeActive: false
        )
        _ = try await store.createSession(title: "Local work", makeActive: false)

        // A fresh actor over the same file proves the flag is persisted, not held
        // in memory.
        let reloaded = SessionStore(root: root)
        let mirror = try await reloaded.session(id: mirrorID)
        XCTAssertTrue(mirror.isDesktopMirror)

        let readBack = try await reloaded.listSessions()
        let local = try XCTUnwrap(readBack.first { $0.title == "Local work" })
        XCTAssertFalse(local.isDesktopMirror)
        XCTAssertNil(local.bridgeMirror)
    }

    func testSnapshotWrittenBeforeMirrorsExistedStillDecodesWithNilFlag() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Write a real snapshot, then strip every `bridgeMirror` key so the
        // file has exactly the shape an older build wrote.
        let seed = SessionStore(root: root)
        let legacyID = try await seed.createSession(title: "Legacy").id
        let snapshotURL = root.appendingPathComponent("current-session.json")
        var snapshot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any]
        )
        let sessions = try XCTUnwrap(snapshot["sessions"] as? [[String: Any]])
        snapshot["sessions"] = sessions.map { row -> [String: Any] in
            var row = row
            row.removeValue(forKey: "bridgeMirror")
            return row
        }
        try JSONSerialization.data(withJSONObject: snapshot).write(to: snapshotURL, options: .atomic)

        let store = SessionStore(root: root)
        let state = try await store.loadState()
        let session = try XCTUnwrap(state.sessions.first { $0.id == legacyID })
        XCTAssertNil(session.bridgeMirror)
        XCTAssertFalse(session.isDesktopMirror)
    }

    // MARK: - Mapping and idempotency

    func testMappingRecordsBothIdentitiesAndTheFollowPosition() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let report = try converted(try fixtureData())

        let outcome = try await harness.importer.importConverted(
            bridgeSessionID: bridgeSessionID,
            listTitle: nil,
            header: report.header,
            events: report.events,
            lastBridgeSequence: report.lastBridgeSequence
        )

        let recorded = try await harness.mappings.mapping(bridgeSessionID: bridgeSessionID)
        let mapping = try XCTUnwrap(recorded)
        XCTAssertEqual(mapping.localSessionID, outcome.localSessionID)
        XCTAssertEqual(mapping.bridgeSessionID, bridgeSessionID)
        XCTAssertEqual(mapping.importedThroughBridgeSeq, report.lastBridgeSequence)
        XCTAssertEqual(mapping.importedEventCount, report.events.count)

        // The correspondence is a file, not just in-memory state.
        let reloaded = BridgeSessionMirrorStore(
            fileURL: harness.root.appendingPathComponent("bridge-sessions.json")
        )
        let reloadedMapping = try await reloaded.mapping(localSessionID: outcome.localSessionID)
        XCTAssertEqual(reloadedMapping?.bridgeSessionID, bridgeSessionID)
    }

    func testSecondImportOfTheSameLogIsIdempotentAndCreatesNoSecondSession() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let report = try converted(try fixtureData())

        let first = try await harness.importer.importConverted(
            bridgeSessionID: bridgeSessionID,
            listTitle: nil,
            header: report.header,
            events: report.events,
            lastBridgeSequence: report.lastBridgeSequence
        )
        let second = try await harness.importer.importConverted(
            bridgeSessionID: bridgeSessionID,
            listTitle: nil,
            header: report.header,
            events: report.events,
            lastBridgeSequence: report.lastBridgeSequence
        )

        XCTAssertEqual(second, .unchanged(localSessionID: first.localSessionID))
        let summaries = try await harness.sessionStore.listSessions()
        XCTAssertEqual(summaries.count, 1)
        let events = try await harness.trajectory.allEvents(sessionID: first.localSessionID)
        XCTAssertEqual(events.count, report.events.count)
    }

    func testMirrorDeletedFromTheSessionListIsReimportedFromScratch() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let report = try converted(try fixtureData())

        let first = try await harness.importer.importConverted(
            bridgeSessionID: bridgeSessionID,
            listTitle: nil,
            header: report.header,
            events: report.events,
            lastBridgeSequence: report.lastBridgeSequence
        )
        // Deleting the conversation from the session list leaves the mapping.
        _ = try await harness.sessionStore.deleteSession(id: first.localSessionID)
        try await harness.trajectory.delete(sessionID: first.localSessionID)

        let second = try await harness.importer.importConverted(
            bridgeSessionID: bridgeSessionID,
            listTitle: nil,
            header: report.header,
            events: report.events,
            lastBridgeSequence: report.lastBridgeSequence
        )

        guard case let .created(localSessionID) = second else {
            return XCTFail("Expected a fresh mirror, got \(second)")
        }
        XCTAssertNotEqual(localSessionID, first.localSessionID)
        let session = try await harness.sessionStore.session(id: localSessionID)
        XCTAssertEqual(session.messages.count, 5)
        let mapping = try await harness.mappings.mapping(bridgeSessionID: bridgeSessionID)
        XCTAssertEqual(mapping?.localSessionID, localSessionID)
    }

    func testReimportWithNewDesktopSuffixAppendsOnlyTheSuffix() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let report = try converted(try fixtureData())

        let first = try await harness.importer.importConverted(
            bridgeSessionID: bridgeSessionID,
            listTitle: nil,
            header: report.header,
            events: report.events,
            lastBridgeSequence: report.lastBridgeSequence
        )

        // The desktop session grew by two events.
        let grown = report.events + [
            try SessionEvent(
                type: SessionEventVocabulary.turnStart,
                seq: UInt64(report.events.count),
                time: 1_735_689_601_000,
                data: .object(["turn": .number(2)])
            ),
            try SessionEvent(
                type: SessionEventVocabulary.userMessage,
                seq: UInt64(report.events.count + 1),
                time: 1_735_689_601_100,
                data: .object([
                    // A DSH user message carries its id and role; the
                    // projection skips one without them.
                    "id": .string("66666666-6666-4666-8666-666666666666"),
                    "role": .string("user"),
                    "content": .array([.object(["type": .string("text"), "text": .string("Follow-up")])])
                ])
            )
        ]

        let second = try await harness.importer.importConverted(
            bridgeSessionID: bridgeSessionID,
            listTitle: nil,
            header: report.header,
            events: grown,
            lastBridgeSequence: Int64(grown.count - 1)
        )

        XCTAssertEqual(
            second,
            .refreshed(localSessionID: first.localSessionID, appendedEvents: 2)
        )
        let events = try await harness.trajectory.allEvents(sessionID: first.localSessionID)
        XCTAssertEqual(events.count, grown.count)

        let session = try await harness.sessionStore.session(id: first.localSessionID)
        XCTAssertEqual(session.messages.last?.content, "Follow-up")
        XCTAssertTrue(session.isDesktopMirror)
    }

    // MARK: - Incremental export

    private static let suffixLines = [
        #"{"type":"turn/start","seq":10,"time":1735689601000,"data":{"turn":2}}"#,
        #"{"type":"user/message","seq":11,"time":1735689601100,"data":{"id":"66666666-6666-4666-8666-666666666666","role":"user","content":[{"type":"text","text":"Follow-up"}]}}"#
    ]

    private static func ndjson(_ request: URLRequest, body: String, headers: [String: String]) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/x-ndjson"].merging(headers) { $1 }
        )!
        return (response, Data(body.utf8))
    }

    func testRefreshReadsOnlyTheDesktopTailAfterTheStoredCursor() async throws {
        defer { BridgeExportURLProtocolStub.handler = nil }
        let harness = try makeHarness(protocolClasses: [BridgeExportURLProtocolStub.self])
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let report = try converted(try fixtureData())
        let first = try await harness.importer.importConverted(
            bridgeSessionID: bridgeSessionID,
            listTitle: nil,
            header: report.header,
            events: report.events,
            lastBridgeSequence: report.lastBridgeSequence
        )
        XCTAssertEqual(report.lastBridgeSequence, 9)

        let queries = RequestLog()
        BridgeExportURLProtocolStub.handler = { request in
            queries.append(request.url?.query ?? "")
            return Self.ndjson(
                request,
                body: Self.suffixLines.joined(separator: "\n") + "\n",
                headers: ["x-dsh-since": "9", "x-dsh-through-seq": "11"]
            )
        }

        let outcome = try await harness.importer.importSession(bridgeSessionID: bridgeSessionID, listTitle: nil)

        XCTAssertEqual(outcome, .refreshed(localSessionID: first.localSessionID, appendedEvents: 2))
        XCTAssertEqual(queries.values, ["since=9&limit=1000"])
        let mapping = try await harness.mappings.mapping(bridgeSessionID: bridgeSessionID)
        XCTAssertEqual(mapping?.importedThroughBridgeSeq, 11)
        XCTAssertEqual(mapping?.importedEventCount, report.events.count + 2)
        let events = try await harness.trajectory.allEvents(sessionID: first.localSessionID)
        XCTAssertEqual(events.map(\.seq), (0...11).map { UInt64($0) })
        let session = try await harness.sessionStore.session(id: first.localSessionID)
        XCTAssertEqual(session.messages.last?.content, "Follow-up")
    }

    func testBridgeWithoutIncrementalExportFallsBackToTheFullLog() async throws {
        defer { BridgeExportURLProtocolStub.handler = nil }
        let harness = try makeHarness(protocolClasses: [BridgeExportURLProtocolStub.self])
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let fixture = try fixtureData()
        let report = try converted(fixture)
        let first = try await harness.importer.importConverted(
            bridgeSessionID: bridgeSessionID,
            listTitle: nil,
            header: report.header,
            events: report.events,
            lastBridgeSequence: report.lastBridgeSequence
        )
        let fullLog = String(decoding: fixture, as: UTF8.self) + Self.suffixLines.joined(separator: "\n") + "\n"
        // An older bridge ignores `since`, sends no cursor headers and the full log.
        BridgeExportURLProtocolStub.handler = { request in
            Self.ndjson(request, body: fullLog, headers: [:])
        }

        let outcome = try await harness.importer.importSession(bridgeSessionID: bridgeSessionID, listTitle: nil)

        XCTAssertEqual(outcome, .refreshed(localSessionID: first.localSessionID, appendedEvents: 2))
        let mapping = try await harness.mappings.mapping(bridgeSessionID: bridgeSessionID)
        XCTAssertEqual(mapping?.importedThroughBridgeSeq, 11)
    }

    func testDesktopLogRewoundBehindTheCursorRebuildsTheSameMirror() async throws {
        defer { BridgeExportURLProtocolStub.handler = nil }
        let harness = try makeHarness(protocolClasses: [BridgeExportURLProtocolStub.self])
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let fixture = try fixtureData()
        let report = try converted(fixture)
        let first = try await harness.importer.importConverted(
            bridgeSessionID: bridgeSessionID,
            listTitle: nil,
            header: report.header,
            events: report.events,
            lastBridgeSequence: report.lastBridgeSequence
        )
        // The desktop now holds only seq 0...4 (header + five events).
        let rewound = String(decoding: fixture, as: UTF8.self)
            .split(separator: "\n")
            .prefix(6)
            .joined(separator: "\n") + "\n"
        let header = String(rewound.split(separator: "\n")[0]) + "\n"
        let queries = RequestLog()
        BridgeExportURLProtocolStub.handler = { request in
            let query = request.url?.query ?? ""
            queries.append(query)
            if query.hasPrefix("since=9") {
                // Paged bridge: the cursor is echoed, the real end is head-seq.
                return Self.ndjson(
                    request,
                    body: header,
                    headers: ["x-dsh-since": "9", "x-dsh-through-seq": "9", "x-dsh-head-seq": "4", "x-dsh-has-more": "false"]
                )
            }
            return Self.ndjson(
                request,
                body: rewound,
                headers: ["x-dsh-since": "-1", "x-dsh-through-seq": "4", "x-dsh-head-seq": "4", "x-dsh-has-more": "false"]
            )
        }

        let outcome = try await harness.importer.importSession(bridgeSessionID: bridgeSessionID, listTitle: nil)

        XCTAssertEqual(outcome, .refreshed(localSessionID: first.localSessionID, appendedEvents: 5))
        XCTAssertEqual(queries.values, ["since=9&limit=1000", "since=-1&limit=1000"])
        let events = try await harness.trajectory.allEvents(sessionID: first.localSessionID)
        XCTAssertEqual(events.map(\.seq), (0...4).map { UInt64($0) })
        let mapping = try await harness.mappings.mapping(bridgeSessionID: bridgeSessionID)
        XCTAssertEqual(mapping?.localSessionID, first.localSessionID)
        XCTAssertEqual(mapping?.importedThroughBridgeSeq, 4)
    }

    /// Serves the fixture as a paged bridge would, `pageSize` events per page,
    /// optionally failing the page that starts after `failAfter`.
    private static func pagedFixtureHandler(
        _ fixture: Data,
        pageSize: Int,
        failAfter: Int64? = nil,
        log: RequestLog
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        let lines = String(decoding: fixture, as: UTF8.self).split(separator: "\n").map(String.init)
        let header = lines[0]
        let events = Array(lines.dropFirst())
        return { request in
            let query = request.url?.query ?? ""
            log.append(query)
            let since = query.split(separator: "&")
                .first { $0.hasPrefix("since=") }
                .flatMap { Int64($0.dropFirst("since=".count)) } ?? -1
            if let failAfter, since == failAfter {
                throw URLError(.networkConnectionLost)
            }
            let start = Int(since + 1)
            let page = Array(events.dropFirst(start).prefix(pageSize))
            let through = since + Int64(page.count)
            let head = Int64(events.count - 1)
            return Self.ndjson(
                request,
                body: ([header] + page).joined(separator: "\n") + "\n",
                headers: [
                    "x-dsh-since": String(since),
                    "x-dsh-through-seq": String(through),
                    "x-dsh-head-seq": String(head),
                    "x-dsh-has-more": through < head ? "true" : "false"
                ]
            )
        }
    }

    func testFirstImportIsPagedAndRecordsTheCursorAfterEveryPage() async throws {
        defer { BridgeExportURLProtocolStub.handler = nil }
        let harness = try makeHarness(protocolClasses: [BridgeExportURLProtocolStub.self])
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let queries = RequestLog()
        BridgeExportURLProtocolStub.handler = Self.pagedFixtureHandler(try fixtureData(), pageSize: 4, log: queries)

        let outcome = try await harness.importer.importSession(bridgeSessionID: bridgeSessionID, listTitle: nil)

        guard case let .created(localSessionID) = outcome else {
            return XCTFail("Expected a new mirror, got \(outcome)")
        }
        XCTAssertEqual(queries.values, ["since=-1&limit=1000", "since=3&limit=1000", "since=7&limit=1000"])
        let events = try await harness.trajectory.allEvents(sessionID: localSessionID)
        XCTAssertEqual(events.map(\.seq), (0...9).map { UInt64($0) })
        let mapping = try await harness.mappings.mapping(bridgeSessionID: bridgeSessionID)
        XCTAssertEqual(mapping?.importedThroughBridgeSeq, 9)
        XCTAssertEqual(mapping?.importedEventCount, 10)
        let session = try await harness.sessionStore.session(id: localSessionID)
        XCTAssertEqual(session.title, "Fixture desktop session")
        XCTAssertEqual(session.messages.last?.content, "Final answer.")
    }

    func testFailedPageKeepsEarlierPagesAndTheNextSyncResumesAfterThem() async throws {
        defer { BridgeExportURLProtocolStub.handler = nil }
        let harness = try makeHarness(protocolClasses: [BridgeExportURLProtocolStub.self])
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let fixture = try fixtureData()
        let failing = RequestLog()
        BridgeExportURLProtocolStub.handler = Self.pagedFixtureHandler(fixture, pageSize: 4, failAfter: 3, log: failing)

        do {
            _ = try await harness.importer.importSession(bridgeSessionID: bridgeSessionID, listTitle: nil)
            XCTFail("The second page fails")
        } catch {}
        let partial = try await harness.mappings.mapping(bridgeSessionID: bridgeSessionID)
        XCTAssertEqual(partial?.importedThroughBridgeSeq, 3)

        let resumed = RequestLog()
        BridgeExportURLProtocolStub.handler = Self.pagedFixtureHandler(fixture, pageSize: 4, log: resumed)
        let outcome = try await harness.importer.importSession(bridgeSessionID: bridgeSessionID, listTitle: nil)

        let localSessionID = try XCTUnwrap(partial?.localSessionID)
        XCTAssertEqual(outcome, .refreshed(localSessionID: localSessionID, appendedEvents: 6))
        XCTAssertEqual(resumed.values, ["since=3&limit=1000", "since=7&limit=1000"])
        let events = try await harness.trajectory.allEvents(sessionID: localSessionID)
        XCTAssertEqual(events.map(\.seq), (0...9).map { UInt64($0) })
    }

    func testMirrorImportedMidTurnGetsNoSyntheticClosersOnColdOpen() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let report = try converted(try fixtureData())
        // Imported while the desktop turn was still running: turn/start and the
        // user message, no turn/end yet.
        let openTurn = Array(report.events.prefix(3))
        let first = try await harness.importer.importConverted(
            bridgeSessionID: bridgeSessionID,
            listTitle: nil,
            header: report.header,
            events: openTurn,
            lastBridgeSequence: 2
        )

        // A relaunch opens the log with a fresh repository.
        let reopened = SessionTrajectoryRepository(root: harness.root)
        let next = try await reopened.nextSequence(sessionID: first.localSessionID)

        XCTAssertEqual(next, 3)
        let isMirror = await reopened.isAppendOnlyMirror(sessionID: first.localSessionID)
        XCTAssertTrue(isMirror)
    }

    func testSuffixWithAGapIsRejectedSoTheFullLogIsUsed() {
        let gap = Data(#"{"type":"turn/start","seq":12,"time":1,"data":{"turn":2}}"#.utf8)
        XCTAssertThrowsError(try BridgeSessionEventConverter.decodeLog(gap, firstSequence: 10)) { error in
            XCTAssertEqual(error as? BridgeLogConversionError, .nonContiguousSuffix(expected: 10))
        }
        let empty = try? BridgeSessionEventConverter.decodeLog(Data(), firstSequence: 10)
        XCTAssertEqual(empty?.events.count, 0)
        XCTAssertEqual(empty?.lastBridgeSequence, 9)
        // The bridge answers an up-to-date cursor with the header line only.
        let headerOnly = Data((#"{"type":"session","version":4,"id":"session-3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411"}"# + "\n").utf8)
        let caughtUp = try? BridgeSessionEventConverter.decodeLog(headerOnly, firstSequence: 10)
        XCTAssertEqual(caughtUp?.events.count, 0)
        XCTAssertNotNil(caughtUp?.header)
    }

    func testUpToDateCursorAnsweredWithTheHeaderOnlyIsUnchanged() async throws {
        defer { BridgeExportURLProtocolStub.handler = nil }
        let harness = try makeHarness(protocolClasses: [BridgeExportURLProtocolStub.self])
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let report = try converted(try fixtureData())
        let first = try await harness.importer.importConverted(
            bridgeSessionID: bridgeSessionID,
            listTitle: nil,
            header: report.header,
            events: report.events,
            lastBridgeSequence: report.lastBridgeSequence
        )
        BridgeExportURLProtocolStub.handler = { request in
            Self.ndjson(
                request,
                body: #"{"type":"session","version":4,"id":"session-3f1c9a54-6b2e-4d77-9a10-8c5e2b7d4411"}"# + "\n",
                headers: ["x-dsh-since": "9", "x-dsh-through-seq": "9", "x-dsh-event-count": "0"]
            )
        }

        let outcome = try await harness.importer.importSession(bridgeSessionID: bridgeSessionID, listTitle: nil)

        XCTAssertEqual(outcome, .unchanged(localSessionID: first.localSessionID))
        let mapping = try await harness.mappings.mapping(bridgeSessionID: bridgeSessionID)
        XCTAssertEqual(mapping?.importedThroughBridgeSeq, 9)
    }

    // MARK: - Transcript integrity

    func testMirrorKeepsMessagesAfterAnUnansweredToolCall() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        // A replaced draft that called a tool keeps its call without a result
        // in an append-only mirror; everything after it must survive.
        let messages = [
            AgentMessage.user("check the board"),
            AgentMessage.assistant("", toolCalls: [AgentToolCall(id: "draft-call", name: "read", arguments: "{}")]),
            AgentMessage.assistant("final answer"),
            AgentMessage.user("next question"),
            AgentMessage.assistant("tail of the thread")
        ]

        let mirror = try await harness.sessionStore.createSession(
            title: "Mirror",
            bridgeMirror: BridgeSessionMirror(bridgeSessionID: bridgeSessionID),
            makeActive: false
        )
        let savedMirror = try await harness.sessionStore.checkpointSession(
            id: mirror.id,
            checkpoint: ConversationCheckpoint(
                messages: messages,
                workState: ConversationWorkState(),
                bridgeMirror: BridgeSessionMirror(bridgeSessionID: bridgeSessionID)
            )
        )
        XCTAssertEqual(savedMirror.messages.count, 5)
        XCTAssertEqual(savedMirror.messages.last?.content, "tail of the thread")

        // A reload normalises every stored session; the mirror stays whole.
        let reloaded = try await harness.sessionStore.session(id: mirror.id)
        XCTAssertEqual(reloaded.messages.count, 5)

        // A local session is still trimmed to a valid model history.
        let local = try await harness.sessionStore.createSession(title: "Local", makeActive: false)
        let savedLocal = try await harness.sessionStore.checkpointSession(
            id: local.id,
            checkpoint: ConversationCheckpoint(messages: messages, workState: ConversationWorkState())
        )
        XCTAssertEqual(savedLocal.messages.count, 1)
    }

    // MARK: - Failure handling

    func testPartialImportIsRolledBackWhenAdmissionFails() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        // A replacement reaching forward is rejected by `SessionEvent`, but this
        // test bypasses the converter on purpose to exercise the rollback path.
        let events = try [
            SessionEvent(
                type: SessionEventVocabulary.userMessage,
                seq: 0,
                time: 1,
                data: .object(["content": .array([.object(["type": .string("text"), "text": .string("hi")])])])
            ),
            // Non-contiguous sequence: admission must fail closed.
            SessionEvent(
                type: SessionEventVocabulary.assistantMessage,
                seq: 5,
                time: 2,
                data: .object(["message": .object(["content": .array([])])])
            )
        ]

        do {
            _ = try await harness.importer.importConverted(
                bridgeSessionID: bridgeSessionID,
                listTitle: nil,
                header: nil,
                events: events,
                lastBridgeSequence: 5
            )
            XCTFail("Expected admission to fail for a non-contiguous suffix")
        } catch {
            // Expected: the local log is dense and append-only.
        }

        let summaries = try await harness.sessionStore.listSessions()
        XCTAssertTrue(summaries.isEmpty, "A failed import must not leave a half-written session")
        let leftover = try await harness.mappings.mapping(bridgeSessionID: bridgeSessionID)
        XCTAssertNil(leftover)
    }

    func testTitleFallsBackToTheFirstUserMessageThenToTheBridgeListTitle() async throws {
        let withoutTitleEvent = try converted(try fixtureData())
            .events
            .filter { $0.type != "session/title" }
            .enumerated()
            .map { index, event in
                try SessionEvent(
                    type: event.type,
                    seq: UInt64(index),
                    time: event.time,
                    data: event.data,
                    ignorable: event.ignorable,
                    surfaceOp: nil
                )
            }

        let fromUserMessage = BridgeSessionImporter.resolvedTitle(
            events: withoutTitleEvent,
            listTitle: nil,
            header: nil,
            bridgeSessionID: bridgeSessionID
        )
        XCTAssertEqual(fromUserMessage, "Summarise the fixture file.")

        // With no user message at all, the bridge list title is used.
        let empty = withoutTitleEvent.filter { $0.type != SessionEventVocabulary.userMessage }
        XCTAssertEqual(
            BridgeSessionImporter.resolvedTitle(
                events: empty,
                listTitle: "  Desktop list title  ",
                header: nil,
                bridgeSessionID: bridgeSessionID
            ),
            "Desktop list title"
        )

        // And a mirror with nothing usable still gets a stable, explicit label.
        XCTAssertEqual(
            BridgeSessionImporter.provisionalTitle(
                events: empty,
                listTitle: nil,
                header: nil,
                bridgeSessionID: bridgeSessionID
            ),
            "Desktop Session"
        )
    }

    func testTitlePrefersTheExplicitDesktopTitleEvent() throws {
        let report = try converted(try fixtureData())
        XCTAssertEqual(
            BridgeSessionImporter.resolvedTitle(
                events: report.events,
                listTitle: "Bridge list title",
                header: report.header,
                bridgeSessionID: bridgeSessionID
            ),
            "Fixture desktop session"
        )
    }

    // MARK: - Envelope chunking limits

    func testSingleEnvelopeCannotExceedTheSyncEventLimit() {
        XCTAssertEqual(
            BridgeSessionImporter.maximumEventsPerEnvelope,
            HarnessSyncEnvelope.maximumEvents
        )
        XCTAssertLessThanOrEqual(BridgeSessionImporter.maximumEventsPerEnvelope, 512)
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(value)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class BridgeExportURLProtocolStub: URLProtocol, @unchecked Sendable {
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
