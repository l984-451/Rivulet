import Foundation

nonisolated enum SiloRequestMediaType: String, Codable, Sendable { case movie, series, all }
nonisolated enum SiloRequestAvailability: String, Codable, Sendable { case missing, available, unknown }
nonisolated enum SiloRequestLifecycleStatus: String, Codable, Sendable { case pending, approved, queued, downloading, completed, failed, unknown }
nonisolated enum SiloRequestOutcome: String, Codable, Sendable { case active, declined, cancelled, failed, unknown }

nonisolated struct SiloRequestsCapability: Decodable, Sendable {
    let requestsEnabled: Bool
    let state: String
    let allowed: Bool?
    let followSupported: Bool?
    var isAvailable: Bool { requestsEnabled && state == "available" && allowed == true }
    var canFollow: Bool { isAvailable && followSupported == true }
}

nonisolated struct SiloRequestState: Decodable, Sendable {
    let status: String?
    let state: String?
    let requestable: Bool
    let reason: String?
    let requestId: String?
    let following: Bool?
    let requestedByViewer: Bool?
    var canFollow: Bool { requestId != nil && requestedByViewer == false && following == false }
    var canUnfollow: Bool { requestId != nil && requestedByViewer == false && following == true }
}

nonisolated struct SiloRequestSearchResult: Decodable, Sendable {
    let mediaType: SiloRequestMediaType
    let tmdbId: Int
    let title: String
    let year: Int?
    let overview: String?
    let posterPath: String?
    let availability: SiloRequestAvailability
    let request: SiloRequestState
    var id: String { "\(mediaType.rawValue):\(tmdbId)" }
}

nonisolated struct SiloRequestSearchPage: Decodable, Sendable {
    let page: Int
    let totalPages: Int
    let totalResults: Int
    let results: [SiloRequestSearchResult]
}

nonisolated struct SiloRequestTarget: Decodable, Sendable {
    let quality: String?
    let status: SiloRequestLifecycleStatus
    let lastError: String?
}

nonisolated struct SiloRequestRecord: Decodable, Sendable {
    let id: String
    let mediaType: SiloRequestMediaType
    let tmdbId: Int
    let title: String
    let year: Int?
    let status: SiloRequestLifecycleStatus
    let outcome: SiloRequestOutcome
    let state: String?
    let targets: [SiloRequestTarget]?
    let libraryContentId: String?
    let lastError: String?
    let createdAt: String
    let updatedAt: String
    let completedAt: String?
    var canCancel: Bool {
        guard outcome == .active else { return false }
        return status == .pending || (status == .approved && (targets?.isEmpty == true))
    }
    var progress: String { state?.replacingOccurrences(of: "_", with: " ").capitalized ?? status.rawValue.capitalized }
}

nonisolated struct SiloRequestPage: Decodable, Sendable {
    let items: [SiloRequestRecord]
    let page: SiloPageInfo?
}

nonisolated struct SiloCreateRequest: Encodable, Sendable {
    let mediaType: SiloRequestMediaType
    let tmdbId: Int
    let tvdbId: Int?
    let imdbId: String?
    let title: String
    let year: Int?
    let overview: String?
    let posterPath: String?
    init(result: SiloRequestSearchResult) {
        mediaType = result.mediaType; tmdbId = result.tmdbId; tvdbId = nil; imdbId = nil
        title = result.title; year = result.year; overview = result.overview; posterPath = result.posterPath
    }
}

nonisolated struct SiloCancelRequest: Encodable, Sendable { let reason: String? }

nonisolated enum SiloRequestsError: LocalizedError, Sendable {
    case unavailable, notPermitted, staleAuthority, incompleteList, uncertainMutation, invalidSearch
    var errorDescription: String? {
        switch self {
        case .unavailable: "Requests are unavailable for this profile."
        case .notPermitted: "This action is not available for this title."
        case .staleAuthority: "The active profile changed."
        case .incompleteList: "The request list could not be fully loaded."
        case .uncertainMutation: "The server may have received the change. Refresh to check its status."
        case .invalidSearch: "Enter a title to search for."
        }
    }
}
