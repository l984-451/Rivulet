// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Native person reads bound to one provider, profile and authority revision.
/// The UI must retain this instance with the provider that created it.
actor SiloPeople {
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
        try Task.checkCancellation()
        guard await ownerIsCurrent() else { throw SiloPeopleError.staleAuthority }
        try Task.checkCancellation()
    }

    func capability() async throws -> SiloPeopleCapability {
        try await checkOwner()
        let result: SiloPeopleCapability = try await provider.client.get("catalog/search/capabilities")
        try await checkOwner()
        return result
    }

    private func requireCapability() async throws -> SiloPeopleCapability {
        let result = try await capability()
        guard result.isAvailable else { throw SiloPeopleError.unavailable }
        return result
    }

    /// `libraryID` is a visible library supplied by the caller. The native
    /// people endpoint has no library selector; scoped results are checked
    /// against a server-filtered credit probe. Its 100-result limit remains
    /// the server's limit before that filtering.
    func search(_ query: String, mediaScope: String? = nil, libraryID: String? = nil, limit: Int = 20) async throws -> [SiloPerson] {
        let capability = try await requireCapability()
        try validate(mediaScope, capability: capability)
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        guard (1...100).contains(limit) else { throw SiloPeopleError.invalidPage }
        var params = [URLQueryItem(name: "q", value: name), URLQueryItem(name: "limit", value: String(limit))]
        if let mediaScope { params.append(URLQueryItem(name: "media_scope", value: mediaScope)) }
        let result: SiloList<SiloPerson> = try await provider.client.get("catalog/people", params)
        try await checkOwner()
        guard let libraryID else { return result.items }
        guard !libraryID.isEmpty else { throw SiloPeopleError.invalidScope }
        var scoped: [SiloPerson] = []
        for person in result.items {
            let probe = try await credits(personID: person.id, mediaScope: mediaScope, libraryID: libraryID, limit: 1)
            if !probe.items.isEmpty { scoped.append(person) }
        }
        return scoped
    }

    func detail(personID: String) async throws -> SiloPerson {
        _ = try await requireCapability()
        guard !personID.isEmpty else { throw SiloPeopleError.invalidScope }
        let result: SiloPerson = try await provider.client.get("catalog/people/\(SiloClient.pathComponent(personID))")
        try await checkOwner()
        return result
    }

    /// One exact native catalog page. `nextCursor` is opaque and must only be
    /// used with the same person, media scope, library and provider authority.
    func credits(personID: String, mediaScope: String? = nil, libraryID: String? = nil,
                 limit: Int = 50, cursor: String? = nil) async throws -> SiloPersonCreditPage {
        let capability = try await requireCapability()
        try validate(mediaScope, capability: capability)
        guard !personID.isEmpty, libraryID != "" else { throw SiloPeopleError.invalidScope }
        guard (1...200).contains(limit), cursor != "" else { throw SiloPeopleError.invalidPage }
        var params = [
            URLQueryItem(name: "source", value: "person"),
            URLQueryItem(name: "person_id", value: personID),
            URLQueryItem(name: "sort", value: "-year"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let mediaScope { params.append(URLQueryItem(name: "type", value: mediaScope)) }
        if let libraryID { params.append(URLQueryItem(name: "library_id", value: libraryID)) }
        if let cursor { params.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page: SiloCatalogPage = try await provider.getArtwork("catalog", params)
        try await checkOwner()
        let next: String?
        if page.page?.hasMore == true {
            guard let value = page.page?.nextCursor, !value.isEmpty, value != cursor else { throw SiloPeopleError.invalidPage }
            next = value
        } else {
            next = nil
        }
        return SiloPersonCreditPage(items: page.items, libraryID: libraryID,
                                    total: page.total, totalExact: page.totalExact, nextCursor: next)
    }

    private func validate(_ scope: String?, capability: SiloPeopleCapability) throws {
        guard let scope else { return }
        let supported = ["video", "movie", "series", "episode", "audiobook", "ebook", "manga"]
        guard supported.contains(scope) || (scope == "video_with_episodes" && capability.videoWithEpisodesScope == true) else {
            throw SiloPeopleError.invalidScope
        }
    }
}
