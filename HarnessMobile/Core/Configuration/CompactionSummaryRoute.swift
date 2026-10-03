import Foundation

/// Optional model route used only for compaction summaries. A missing value
/// means the compactor inherits the active conversation route, matching the
/// upstream `dsh-compaction-basic` empty provider/model pair.
struct CompactionSummaryRoute: Codable, Sendable, Hashable {
    let profileID: String
    let model: String

    init(profileID: String, model: String) {
        self.profileID = profileID
        self.model = model
    }

    func validated(in directory: ProviderProfileDirectory) throws -> CompactionSummaryRoute {
        guard let profile = directory.profile(id: profileID) else {
            throw CompactionSummaryRouteError.missingProfile(profileID)
        }
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty, normalizedModel.utf8.count <= 256 else {
            throw CompactionSummaryRouteError.invalidModel
        }
        guard profile.models.contains(where: { $0.id == normalizedModel }) else {
            throw CompactionSummaryRouteError.modelUnavailable(
                profileID: profileID,
                model: normalizedModel
            )
        }
        return CompactionSummaryRoute(profileID: profileID, model: normalizedModel)
    }

    func configuration(in directory: ProviderProfileDirectory) throws -> AgentConfiguration {
        let route = try validated(in: directory)
        guard let profile = directory.profile(id: route.profileID) else {
            throw CompactionSummaryRouteError.missingProfile(route.profileID)
        }
        return try profile.configuration(model: route.model).validated()
    }
}

enum CompactionSummaryRouteError: LocalizedError, Sendable, Equatable {
    case missingProfile(String)
    case invalidModel
    case modelUnavailable(profileID: String, model: String)
    case profileBusy

    var errorDescription: String? {
        switch self {
        case let .missingProfile(profileID):
            return "The Provider Profile '\(profileID)' used for compaction summaries no longer exists."
        case .invalidModel:
            return "The compaction summary model ID must be non-empty and at most 256 bytes."
        case let .modelUnavailable(profileID, model):
            return "Provider Profile '\(profileID)' has no compaction summary model '\(model)'."
        case .profileBusy:
            return "A task is still running. Stop it before switching the compaction summary model."
        }
    }
}
