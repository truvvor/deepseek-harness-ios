import Foundation

/// User-visible configuration for the read-only DeepSeek Harness desktop
/// bridge.
///
/// Scope is deliberately narrow: the app may *read* sessions that the desktop
/// DSH host already produced (`/sessions`, `/sessions/{id}/export`,
/// `/sessions/{id}/stream`). It never sends prompts, tools or its own agent loop
/// to the bridge, and it never accepts a remote execution request. See
/// `DECISIONS.md` D-012.
///
/// The bearer token is deliberately **not** part of this value: it lives only in
/// the Keychain (`CredentialStore.bridgeTokenAccount`) so this struct stays safe
/// to persist in `UserDefaults` and to log.
struct BridgeSettings: Codable, Sendable, Equatable {
    /// Path suffix every bridge route hangs off. The desktop bridge exposes
    /// `/bridge/v1/...` on the DSH host origin.
    static let versionPath = "bridge/v1"

    /// Request timeout for the non-streaming bridge calls.
    static let defaultRequestTimeoutSeconds: TimeInterval = 20
    /// Idle timeout applied between SSE frames of `/stream`, so a half-dead
    /// socket is recovered instead of hanging the mirror forever.
    static let defaultStreamIdleTimeoutSeconds: TimeInterval = 120
    /// Upper bound on the number of messages one `/messages` page may ask for.
    static let maximumMessagePageSize = 500

    var baseURL: URL?
    var isEnabled: Bool
    var includesArchivedSessions: Bool
    var followsSelectedMirrorAutomatically: Bool
    var requestTimeoutSeconds: TimeInterval
    var streamIdleTimeoutSeconds: TimeInterval

    init(
        baseURL: URL? = nil,
        isEnabled: Bool = false,
        includesArchivedSessions: Bool = false,
        followsSelectedMirrorAutomatically: Bool = false,
        requestTimeoutSeconds: TimeInterval = Self.defaultRequestTimeoutSeconds,
        streamIdleTimeoutSeconds: TimeInterval = Self.defaultStreamIdleTimeoutSeconds
    ) {
        self.baseURL = baseURL
        self.isEnabled = isEnabled
        self.includesArchivedSessions = includesArchivedSessions
        self.followsSelectedMirrorAutomatically = followsSelectedMirrorAutomatically
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.streamIdleTimeoutSeconds = streamIdleTimeoutSeconds
    }

    /// Settings persisted before the follow preference existed decode with the
    /// mirror switched on and following off, so an existing install never starts
    /// background network work just because a field was added.
    private enum CodingKeys: String, CodingKey {
        case baseURL
        case isEnabled
        case includesArchivedSessions
        case followsSelectedMirrorAutomatically
        case requestTimeoutSeconds
        case streamIdleTimeoutSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(URL.self, forKey: .baseURL)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        includesArchivedSessions = try container
            .decodeIfPresent(Bool.self, forKey: .includesArchivedSessions) ?? false
        followsSelectedMirrorAutomatically = try container
            .decodeIfPresent(Bool.self, forKey: .followsSelectedMirrorAutomatically) ?? false
        requestTimeoutSeconds = try container
            .decodeIfPresent(TimeInterval.self, forKey: .requestTimeoutSeconds)
            ?? Self.defaultRequestTimeoutSeconds
        streamIdleTimeoutSeconds = try container
            .decodeIfPresent(TimeInterval.self, forKey: .streamIdleTimeoutSeconds)
            ?? Self.defaultStreamIdleTimeoutSeconds
    }

    /// The bridge base URL is only reachable when the mirror is enabled and the
    /// address survives `validated()`.
    var activeBaseURL: URL? {
        guard isEnabled, let baseURL, let validated = try? Self.validatedBaseURL(baseURL) else {
            return nil
        }
        return validated
    }

    func validated() throws -> Self {
        var validated = self
        if let baseURL {
            validated.baseURL = try Self.validatedBaseURL(baseURL)
        } else {
            validated.baseURL = nil
        }
        validated.requestTimeoutSeconds = Self.clampedTimeout(
            requestTimeoutSeconds,
            fallback: Self.defaultRequestTimeoutSeconds
        )
        validated.streamIdleTimeoutSeconds = Self.clampedTimeout(
            streamIdleTimeoutSeconds,
            fallback: Self.defaultStreamIdleTimeoutSeconds
        )
        return validated
    }

    /// Normalizes a user-entered bridge address.
    ///
    /// Plain HTTP is accepted here on purpose, to any host including a bare
    /// public IP: the desktop bridge has no TLS of its own. This is the one
    /// documented exception to the HTTPS-only model-provider rule, which is
    /// enforced in code (`AgentConfiguration`, `CredentialStore`) rather than by
    /// ATS; `Info.plist` sets `NSAllowsArbitraryLoads` for it (DECISIONS D-013).
    static func validatedBaseURL(_ url: URL) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw BridgeSettingsError.invalidBaseURL
        }

        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }

        var normalized = URLComponents()
        normalized.scheme = scheme
        normalized.host = host
        normalized.port = components.port ?? (scheme == "https" ? 443 : 80)
        if path.isEmpty {
            normalized.path = "/" + versionPath
        } else if path.lowercased().hasSuffix("/" + versionPath) {
            normalized.path = path
        } else {
            normalized.path = path + "/" + versionPath
        }
        guard let value = normalized.url else {
            throw BridgeSettingsError.invalidBaseURL
        }
        return value
    }

    /// Host shown in the UI without the bearer token or the bridge path.
    var displayHost: String? {
        guard let baseURL,
              let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host else { return nil }
        guard let port = components.port else { return host }
        return "\(host):\(port)"
    }

    private static func clampedTimeout(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        guard value.isFinite, value >= 5, value <= 600 else { return fallback }
        return value
    }
}

enum BridgeSettingsError: Error, LocalizedError, Sendable, Equatable {
    case invalidBaseURL
    case disabled
    case missingToken
    case sessionNotMapped(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Enter an http(s) address with a host and no query or credentials, for example http://192.0.2.10:19387."
        case .disabled:
            return "The desktop bridge is turned off. Enable it in Settings before reading desktop sessions."
        case .missingToken:
            return "The desktop bridge bearer token is missing. Save the token from the DSH api-bridge.token file."
        case let .sessionNotMapped(bridgeSessionID):
            return "Desktop session \(bridgeSessionID) has not been imported into this app yet."
        }
    }
}
