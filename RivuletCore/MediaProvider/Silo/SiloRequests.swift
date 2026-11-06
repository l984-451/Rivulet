import Foundation

/// A profile-bound Requests client. Create and cancel are never retried after a lost answer.
actor SiloRequests {
    private let provider: SiloProvider
    private let ownerIsCurrent: @Sendable () async -> Bool

    init(provider: SiloProvider, ownerIsCurrent: (@Sendable () async -> Bool)? = nil) {
        self.provider = provider
        self.ownerIsCurrent = ownerIsCurrent ?? {
            let current = await MainActor.run { SiloSession.storedProvider() }
            return current?.id == provider.id && current?.authorityRevision == provider.authorityRevision
        }
    }

    private func checkOwner() async throws {
        guard await ownerIsCurrent() else { throw SiloRequestsError.staleAuthority }
    }

    func status() async throws -> SiloRequestsCapability {
        try await checkOwner()
        let value: SiloRequestsCapability = try await provider.client.get("requests/status")
        try await checkOwner()
        return value
    }

    private func requireAvailable() async throws -> SiloRequestsCapability {
        let value = try await status()
        guard value.isAvailable else { throw SiloRequestsError.unavailable }
        return value
    }

    func search(_ query: String, type: SiloRequestMediaType = .all, page: Int = 1) async throws -> SiloRequestSearchPage {
        _ = try await requireAvailable()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SiloRequestsError.invalidSearch }
        let result: SiloRequestSearchPage = try await provider.client.get("requests/search", [
            URLQueryItem(name: "q", value: trimmed), URLQueryItem(name: "media_type", value: type.rawValue),
            URLQueryItem(name: "page", value: String(max(page, 1)))
        ])
        try await checkOwner()
        return result
    }

    func mine() async throws -> [SiloRequestRecord] {
        _ = try await requireAvailable()
        var records: [SiloRequestRecord] = []
        var cursor: String?
        var seen = Set<String>()
        for _ in 0..<100 {
            var query = [URLQueryItem(name: "limit", value: "50")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: SiloRequestPage = try await provider.client.get("requests/mine", query)
            try await checkOwner()
            records.append(contentsOf: page.items)
            guard page.page?.hasMore == true else { return records }
            guard let next = page.page?.nextCursor, !next.isEmpty, seen.insert(next).inserted else {
                throw SiloRequestsError.incompleteList
            }
            cursor = next
        }
        throw SiloRequestsError.incompleteList
    }

    func create(_ result: SiloRequestSearchResult) async throws -> SiloRequestRecord {
        _ = try await requireAvailable()
        guard result.mediaType != .all, result.availability == .missing, result.request.requestable else {
            throw SiloRequestsError.notPermitted
        }
        let response: SiloRequestRecord
        do { response = try await provider.client.post("requests", body: SiloCreateRequest(result: result)) }
        catch { throw SiloRequestsError.uncertainMutation }
        do { try await checkOwner() } catch { throw SiloRequestsError.uncertainMutation }
        return response
    }

    func cancel(_ record: SiloRequestRecord) async throws -> SiloRequestRecord {
        _ = try await requireAvailable()
        guard record.canCancel else { throw SiloRequestsError.notPermitted }
        let response: SiloRequestRecord
        do { response = try await provider.client.post("requests/\(SiloProvider.pathComponent(record.id))/cancel", body: SiloCancelRequest(reason: nil)) }
        catch { throw SiloRequestsError.uncertainMutation }
        do { try await checkOwner() } catch { throw SiloRequestsError.uncertainMutation }
        return response
    }

    func follow(_ result: SiloRequestSearchResult) async throws -> SiloRequestState {
        let status = try await requireAvailable()
        guard status.canFollow, result.request.canFollow, result.mediaType != .all else { throw SiloRequestsError.notPermitted }
        let value: SiloRequestState = try await provider.client.put("requests/follows/\(result.mediaType.rawValue)/\(result.tmdbId)")
        try await checkOwner()
        return value
    }

    func unfollow(_ result: SiloRequestSearchResult) async throws {
        let status = try await requireAvailable()
        guard status.canFollow, result.request.canUnfollow, result.mediaType != .all else { throw SiloRequestsError.notPermitted }
        try await provider.client.delete("requests/follows/\(result.mediaType.rawValue)/\(result.tmdbId)")
        try await checkOwner()
    }
}
