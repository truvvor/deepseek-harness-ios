import Foundation

/// Projected transcript of one desktop mirror, one `AgentMessage` per JSONL
/// line, append-only, in log order.
///
/// A mirror of a long desktop session has thousands of messages. Keeping them
/// all in the `SessionStore` snapshot made every refresh rewrite the whole
/// snapshot and hand the whole array to SwiftUI. The session now keeps only
/// the newest `sessionTailLimit` messages, and this store serves the rest by
/// position while the chat scrolls back. A line-offset index is built on
/// first access (one scan for newlines, no JSON decoding) and maintained on
/// append, so a page costs one bounded read.
actor BridgeMirrorTranscriptStore {
    /// Newest messages a mirror session keeps inline for instant display.
    static let sessionTailLimit = 120

    private struct Index {
        var lineOffsets: [UInt64]
        var fileSize: UInt64
    }

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var indexes: [UUID: Index] = [:]

    init(directory: URL = BridgeMirrorTranscriptStore.applicationSupportDirectory()) {
        self.directory = directory
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    /// `…/Application Support/HarnessMobile/Bridge/Transcripts/`.
    static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("HarnessMobile", isDirectory: true)
            .appendingPathComponent("Bridge", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
    }

    func count(sessionID: UUID) throws -> Int {
        try index(for: sessionID).lineOffsets.count
    }

    /// Appends in order and returns the new total.
    @discardableResult
    func append(_ messages: [AgentMessage], sessionID: UUID) throws -> Int {
        var index = try index(for: sessionID)
        guard !messages.isEmpty else { return index.lineOffsets.count }
        var data = Data()
        var offsets: [UInt64] = []
        for message in messages {
            offsets.append(index.fileSize + UInt64(data.count))
            data.append(try encoder.encode(message))
            data.append(0x0A)
        }
        let handle = try FileHandle(forWritingTo: fileURL(for: sessionID))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        index.lineOffsets.append(contentsOf: offsets)
        index.fileSize += UInt64(data.count)
        indexes[sessionID] = index
        return index.lineOffsets.count
    }

    /// Drops the transcript and writes `messages` as its new content.
    func replaceAll(_ messages: [AgentMessage], sessionID: UUID) throws {
        try delete(sessionID: sessionID)
        try append(messages, sessionID: sessionID)
    }

    func delete(sessionID: UUID) throws {
        indexes[sessionID] = nil
        let url = fileURL(for: sessionID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// The newest `limit` messages.
    func tail(sessionID: UUID, limit: Int) throws -> [AgentMessage] {
        let total = try count(sessionID: sessionID)
        return try page(sessionID: sessionID, before: total, limit: limit)
    }

    /// Up to `limit` messages immediately before position `before`
    /// (`0 ≤ position < count`, log order), oldest first.
    func page(sessionID: UUID, before: Int, limit: Int) throws -> [AgentMessage] {
        let index = try index(for: sessionID)
        let end = min(max(0, before), index.lineOffsets.count)
        let start = max(0, end - max(0, limit))
        guard start < end else { return [] }
        let from = index.lineOffsets[start]
        let to = end < index.lineOffsets.count ? index.lineOffsets[end] : index.fileSize
        let handle = try FileHandle(forReadingFrom: fileURL(for: sessionID))
        defer { try? handle.close() }
        try handle.seek(toOffset: from)
        let data = try handle.read(upToCount: Int(to - from)) ?? Data()
        var messages: [AgentMessage] = []
        messages.reserveCapacity(end - start)
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            messages.append(try decoder.decode(AgentMessage.self, from: Data(line)))
        }
        return messages
    }

    // MARK: - Index

    private func index(for sessionID: UUID) throws -> Index {
        if let cached = indexes[sessionID] { return cached }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: sessionID)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        var offsets: [UInt64] = []
        var lineStart = 0
        for (position, byte) in data.enumerated() where byte == 0x0A {
            if position > lineStart { offsets.append(UInt64(lineStart)) }
            lineStart = position + 1
        }
        // A torn trailing line (no newline) is dropped by the index and
        // overwritten by the next append only if the file is truncated to it.
        var fileSize = UInt64(data.count)
        if lineStart < data.count {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(lineStart))
            try handle.close()
            fileSize = UInt64(lineStart)
        }
        let index = Index(lineOffsets: offsets, fileSize: fileSize)
        indexes[sessionID] = index
        return index
    }

    private func fileURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent(
            sessionID.uuidString.lowercased() + ".messages.jsonl",
            isDirectory: false
        )
    }
}
