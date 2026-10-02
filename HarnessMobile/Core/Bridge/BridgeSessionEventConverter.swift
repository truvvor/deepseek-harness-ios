import Foundation

enum BridgeLogConversionError: Error, LocalizedError, Sendable, Equatable {
    case emptyLog
    case malformedHeader
    case malformedEvent(line: Int)
    case unsupportedEventType(line: Int, type: String)
    case tooManyEvents(Int)
    case logTooLarge(Int)
    case nonContiguousSuffix(expected: UInt64)

    var errorDescription: String? {
        switch self {
        case .emptyLog:
            return "The desktop session export contained no events."
        case .malformedHeader:
            return "The desktop session export header is malformed."
        case let .malformedEvent(line):
            return "Event on line \(line) of the desktop export is not a well-formed session event."
        case let .unsupportedEventType(line, type):
            return "Event on line \(line) has an unsupported type '\(type)'."
        case let .tooManyEvents(limit):
            return "The desktop session export exceeds the \(limit)-event import limit."
        case let .logTooLarge(limit):
            return "The desktop session export exceeds the \(limit)-byte import limit."
        case let .nonContiguousSuffix(expected):
            return "The incremental desktop export does not continue at sequence \(expected)."
        }
    }
}

/// Converts the canonical DeepSeek Harness **v4 JSONL** session export into the
/// app's local `SessionEvent` representation.
///
/// Wire-vs-local differences this converter owns:
/// - the export starts with a `{"type":"session",...}` header line, which is not
///   a `SessionEvent` at all and must never reach the trajectory store;
/// - the desktop spelling of a surface replacement is
///   `{"op":"replace","startSeq":N,"endSeq":M}` while the app's own
///   `SessionSurfaceOperation` wire form is `{op, start, end}`. The app format is
///   not changed; the input is normalized (older `start`/`end` spellings are
///   still accepted, matching `dsh-api-bridge`'s own `normalizeSurfaceOp`);
/// - event types outside `SessionEventVocabulary.upstreamKnown` are kept but
///   flagged `ignorable: true`, which is how `SessionEventJSONLStore` accepts
///   vocabulary it does not know without dropping the event.
///
/// Sequence numbers are preserved verbatim whenever the desktop log is dense
/// from seq 0, which is the contract for a DSH session log. If it is not, the
/// events are renumbered in file order (the local log is append-only and dense)
/// and every surface replacement is remapped through the same table; a
/// replacement whose range cannot be mapped is dropped and reported.
enum BridgeSessionEventConverter {
    /// Bounded import size. The trajectory store enforces its own limits too;
    /// this keeps a hostile or runaway export from being parsed at all. Long
    /// desktop working sessions routinely exceed 16 MiB, so the bound is sized
    /// for real logs, and lines are decoded from byte slices so the export is
    /// not duplicated into a second in-memory string.
    static let maximumEvents = 200_000
    static let maximumLogBytes = 128 * 1_024 * 1_024

    struct Report: Sendable, Equatable {
        let header: BridgeSessionLogHeader?
        let events: [SessionEvent]
        /// Types outside the app vocabulary that were admitted as ignorable.
        let unknownEventTypes: [String]
        /// `{"op":"replace"}` ranges that could not be represented locally.
        let droppedSurfaceOperations: Int
        /// True when the desktop log was sparse and local sequences were reassigned.
        let renumberedSequences: Bool
        /// Last desktop sequence number seen, which `/stream?since=` resumes from.
        let lastBridgeSequence: Int64
    }

    private struct WireEvent {
        let type: String
        let seq: UInt64
        let time: Int64
        let data: JSONValue
        let surfaceStart: UInt64?
        let surfaceEnd: UInt64?
    }

    /// Decodes a v4 export. With `firstSequence > 0` the data is an incremental
    /// export (`?since=firstSequence-1`): it must continue densely at
    /// `firstSequence`, keeps the desktop sequence numbers, and may be empty.
    static func decodeLog(
        _ data: Data,
        now: Date = .now,
        firstSequence: UInt64 = 0
    ) throws -> Report {
        guard data.count <= maximumLogBytes else {
            throw BridgeLogConversionError.logTooLarge(maximumLogBytes)
        }
        var header: BridgeSessionLogHeader?
        var wireEvents: [WireEvent] = []
        var lineNumber = 0
        let decoder = JSONDecoder()

        for rawLine in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            lineNumber += 1
            if rawLine.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
            let lineData = Data(rawLine)
            guard let value = try? decoder.decode(JSONValue.self, from: lineData),
                  let object = value.objectValue,
                  let type = object["type"]?.stringValue else {
                throw BridgeLogConversionError.malformedEvent(line: lineNumber)
            }

            if type == "session" {
                // A header is only meaningful as the first record; a later one is
                // a malformed export, not a second session.
                guard header == nil, wireEvents.isEmpty else {
                    throw BridgeLogConversionError.malformedHeader
                }
                header = try? decoder.decode(BridgeSessionLogHeader.self, from: lineData)
                guard header != nil else {
                    throw BridgeLogConversionError.malformedHeader
                }
                continue
            }

            guard let seqValue = number(object["seq"]),
                  let seq = UInt64(exactly: seqValue),
                  let timeValue = number(object["time"]),
                  let time = Int64(exactly: timeValue) else {
                throw BridgeLogConversionError.malformedEvent(line: lineNumber)
            }
            let data = object["data"] ?? .object([:])
            let surface = surfaceRange(object["surfaceOp"])
            wireEvents.append(
                WireEvent(
                    type: type,
                    seq: seq,
                    time: time,
                    data: data,
                    surfaceStart: surface?.start,
                    surfaceEnd: surface?.end
                )
            )
            guard wireEvents.count <= maximumEvents else {
                throw BridgeLogConversionError.tooManyEvents(maximumEvents)
            }
        }

        let isSuffix = firstSequence > 0
        guard !wireEvents.isEmpty else {
            guard isSuffix else { throw BridgeLogConversionError.emptyLog }
            return Report(
                header: header,
                events: [],
                unknownEventTypes: [],
                droppedSurfaceOperations: 0,
                renumberedSequences: false,
                lastBridgeSequence: clampedSequence(firstSequence - 1)
            )
        }

        var seenSequences = Set<UInt64>()
        let isDense = wireEvents.enumerated().allSatisfy { index, event in
            UInt64(index) &+ firstSequence == event.seq && seenSequences.insert(event.seq).inserted
        }
        // A suffix cannot be renumbered: its local sequences must continue the
        // mirror exactly, so a gap means the caller has to re-read the full log.
        if isSuffix, !isDense {
            throw BridgeLogConversionError.nonContiguousSuffix(expected: firstSequence)
        }
        let localSequences = wireEvents.indices.map { UInt64($0) &+ firstSequence }
        var originalToLocal: [UInt64: UInt64] = [:]
        if isDense {
            for (index, wire) in wireEvents.enumerated() {
                originalToLocal[wire.seq] = localSequences[index]
            }
        }

        var events: [SessionEvent] = []
        events.reserveCapacity(wireEvents.count)
        var unknownTypes = Set<String>()
        var droppedSurfaceOperations = 0
        let fallbackTime = SessionEventTimestamp.nowMilliseconds(date: now)

        for (index, wire) in wireEvents.enumerated() {
            let localSeq = localSequences[index]
            var surfaceStart: UInt64?
            var surfaceEnd: UInt64?
            if let start = wire.surfaceStart, let end = wire.surfaceEnd, start <= end {
                let mappedStart = isDense ? originalToLocal[start] : mapIfEarlier(start, wireEvents: wireEvents)
                let mappedEnd = isDense ? originalToLocal[end] : mapIfEarlier(end, wireEvents: wireEvents)
                if let mappedStart, let mappedEnd,
                   mappedStart <= mappedEnd,
                   mappedEnd < localSeq,
                   localSeq >= 2 {
                    surfaceStart = mappedStart
                    surfaceEnd = mappedEnd
                } else {
                    droppedSurfaceOperations += 1
                }
            } else if wire.surfaceStart != nil || wire.surfaceEnd != nil {
                droppedSurfaceOperations += 1
            }

            let isKnown = isKnownEventType(wire.type)
            if !isKnown { unknownTypes.insert(wire.type) }
            // Negative clocks clamp to 0; an unset (0) time takes the import clock.
            let resolvedTime = wire.time < 0 ? 0 : (wire.time == 0 ? fallbackTime : wire.time)
            do {
                events.append(
                    try makeEvent(
                        type: wire.type,
                        seq: localSeq,
                        time: resolvedTime,
                        data: wire.data,
                        isKnown: isKnown,
                        surfaceStart: surfaceStart,
                        surfaceEnd: surfaceEnd
                    )
                )
            } catch {
                // A single event the envelope validator rejects (for example an
                // out-of-range replacement) must not discard the whole session.
                droppedSurfaceOperations += 1
                events.append(
                    try makeEvent(
                        type: wire.type,
                        seq: localSeq,
                        time: resolvedTime,
                        data: wire.data,
                        isKnown: isKnown,
                        surfaceStart: nil,
                        surfaceEnd: nil
                    )
                )
            }
        }

        return Report(
            header: header,
            events: events,
            unknownEventTypes: unknownTypes.sorted(),
            droppedSurfaceOperations: droppedSurfaceOperations,
            renumberedSequences: !isDense,
            lastBridgeSequence: clampedSequence(wireEvents.map(\.seq).max() ?? 0)
        )
    }

    /// `Int64` is the wire type for the follow cursor; a value that cannot be
    /// represented saturates instead of trapping the import.
    private static func clampedSequence(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }

    /// Admissible `surfaceOp` shapes:
    /// - absent or the string `"append"` -> no replacement;
    /// - `{op:"replace", startSeq:N, endSeq:M}` -> replacement;
    /// - `{op:"replace", start:N, end:M}` -> replacement (older desktop spelling).
    /// Anything else is ignored rather than guessed.
    static func surfaceRange(_ value: JSONValue?) -> (start: UInt64, end: UInt64)? {
        guard let object = value?.objectValue else { return nil }
        guard object["op"]?.stringValue == "replace" else { return nil }
        let start = number(object["startSeq"]) ?? number(object["start"])
        let end = number(object["endSeq"]) ?? number(object["end"])
        guard let startValue = start, let startSequence = UInt64(exactly: startValue),
              let endValue = end, let endSequence = UInt64(exactly: endValue) else {
            return nil
        }
        return (startSequence, endSequence)
    }

    /// Builds one local event from a desktop envelope.
    ///
    /// `isKnown` is false for a type outside the app vocabulary, which is
    /// admitted as `ignorable` so `SessionEventJSONLStore` accepts it without
    /// dropping the event. The `surfaceOp` is only represented when its range can
    /// point at an earlier local sequence, because `SessionEvent.validateEnvelope`
    /// rejects a replacement that reaches forward.
    ///
    /// Mirror transcripts are deliberately **append-only**: the desktop is the
    /// master and its GUI renders the whole log, while the app's own projection
    /// *honours* `surfaceOp.replace` (compaction removes the replaced prefix from
    /// the model-visible surface). Carrying the replacement into a mirror hid
    /// everything the desktop had compacted — a 458-message session arrived as a
    /// single message. The range is still parsed and validated by `decodeLog`
    /// (invalid ranges are counted in `droppedSurfaceOperations`); it is simply
    /// not installed on the mirrored event, so the mirror shows the desktop's
    /// full history in log order.
    static func makeEvent(
        type: String,
        seq: UInt64,
        time: Int64,
        data: JSONValue,
        isKnown: Bool,
        surfaceStart: UInt64?,
        surfaceEnd: UInt64?
    ) throws -> SessionEvent {
        let ignorable: Bool? = isKnown ? nil : true
        _ = (surfaceStart, surfaceEnd) // validated upstream; never applied to a mirror
        return try SessionEvent(
            type: type,
            seq: seq,
            time: time,
            data: data,
            ignorable: ignorable
        )
    }

    static func isKnownEventType(_ type: String) -> Bool {
        SessionEventVocabulary.upstreamKnown.contains(type)
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard case let .number(number)? = value, number.isFinite else { return nil }
        return number
    }

    private static func mapIfEarlier(_ sequence: UInt64, wireEvents: [WireEvent]) -> UInt64? {
        guard let index = wireEvents.firstIndex(where: { $0.seq == sequence }) else { return nil }
        return UInt64(index)
    }
}
