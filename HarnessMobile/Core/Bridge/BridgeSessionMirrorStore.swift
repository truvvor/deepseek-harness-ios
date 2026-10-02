import Foundation

/// Durable `localUUID ↔ bridgeSessionId` map for sessions mirrored from the
/// desktop bridge.
///
/// This is *not* a second copy of session content: content lives only in the
/// canonical append-only trajectory and the `SessionStore` snapshot. This store
/// holds the identity correspondence plus the desktop-side follow position, so
/// the map itself stays tiny and can always be rebuilt by re-importing.
actor BridgeSessionMirrorStore {
    static let currentVersion = 1

    private struct Snapshot: Codable {
        var version: Int
        var mappings: [BridgeSessionMapping]
        var updatedAt: Date

        static var empty: Snapshot {
            Snapshot(version: BridgeSessionMirrorStore.currentVersion, mappings: [], updatedAt: .now)
        }
    }

    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = BridgeSessionMirrorStore.applicationSupportURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// `…/Application Support/HarnessMobile/Bridge/bridge-sessions.json`.
    static func applicationSupportURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("HarnessMobile", isDirectory: true)
            .appendingPathComponent("Bridge", isDirectory: true)
            .appendingPathComponent("bridge-sessions.json")
    }

    func mapping(bridgeSessionID: String) throws -> BridgeSessionMapping? {
        try load().mappings.first { $0.bridgeSessionID == bridgeSessionID }
    }

    func mapping(localSessionID: UUID) throws -> BridgeSessionMapping? {
        try load().mappings.first { $0.localSessionID == localSessionID }
    }

    func allMappings() throws -> [BridgeSessionMapping] {
        try load().mappings.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Inserts or refreshes one correspondence. A desktop id always wins over a
    /// stale local row so a re-import cannot create a second local session for
    /// the same desktop session.
    func record(_ mapping: BridgeSessionMapping) throws {
        var snapshot = try load()
        if let index = snapshot.mappings.firstIndex(where: {
            $0.bridgeSessionID == mapping.bridgeSessionID
        }) {
            snapshot.mappings[index] = mapping
        } else {
            snapshot.mappings.append(mapping)
        }
        snapshot.updatedAt = .now
        try save(snapshot)
    }

    func updateFollowPosition(
        bridgeSessionID: String,
        importedThroughBridgeSeq: Int64,
        importedEventCount: Int
    ) throws {
        var snapshot = try load()
        guard let index = snapshot.mappings.firstIndex(where: {
            $0.bridgeSessionID == bridgeSessionID
        }) else { return }
        snapshot.mappings[index].importedThroughBridgeSeq = importedThroughBridgeSeq
        snapshot.mappings[index].importedEventCount = importedEventCount
        snapshot.mappings[index].updatedAt = .now
        snapshot.updatedAt = .now
        try save(snapshot)
    }

    /// Forgets the correspondence only. The caller decides separately whether the
    /// local mirror session and its trajectory should be deleted.
    func forget(bridgeSessionID: String) throws {
        var snapshot = try load()
        snapshot.mappings.removeAll { $0.bridgeSessionID == bridgeSessionID }
        snapshot.updatedAt = .now
        try save(snapshot)
    }

    func reset() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func load() throws -> Snapshot {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: fileURL))
            guard snapshot.version == Self.currentVersion else {
                throw BridgeSessionMappingError.unsupportedVersion(snapshot.version)
            }
            return snapshot
        } catch let error as BridgeSessionMappingError {
            throw error
        } catch {
            throw BridgeSessionMappingError.unreadableStore
        }
    }

    private func save(_ snapshot: Snapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: fileURL.path
        )
#endif
    }
}
