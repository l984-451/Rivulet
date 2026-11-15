// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

extension PlexProvider {
    func searchHits(_ query: String, inLibraries libraryIDs: [String]?) async throws -> SearchHits {
        try await plexCall {
            try await PlexHubSearch.search(
                query, serverURL: serverURL, token: authToken, providerID: id,
                visibleSections: libraryIDs.map { Set($0.compactMap(Int.init)) }, network: networkManager
            ).hits
        }
    }

    /// Actor and director tag ids are server-wide (the same id in every library), so
    /// `/library/all?type=&actor=` lists every library in one call per kind.
    func filmography(of person: MediaPerson) async throws -> [FilmographyEntry] {
        let filter = person.originFilter
        // A tag id is this server's own. A person with no server is the selected server's cast.
        var tagID = person.providerID == id || person.providerID == nil ? person.originActorId : nil
        if tagID == nil {
            tagID = await PlexHubSearch.personTagID(named: person.name, filter: filter, serverURL: serverURL,
                                                    token: authToken, network: networkManager)
        }
        guard let tagID else { return [] }
        async let movies = credits(type: 1, filter: filter, tagID: tagID)
        async let shows = credits(type: 2, filter: filter, tagID: tagID)
        return try await movies + shows
    }

    private func credits(type: Int, filter: String, tagID: String) async throws -> [FilmographyEntry] {
        guard var components = URLComponents(string: "\(serverURL)/library/all") else { return [] }
        components.queryItems = [URLQueryItem(name: "type", value: String(type)),
                                 URLQueryItem(name: filter, value: tagID),
                                 URLQueryItem(name: "includeGuids", value: "1")]
        guard let url = components.url else { return [] }
        let container: PlexMediaContainerWrapper = try await plexCall {
            try await networkManager.request(url, headers: networkManager.plexHeaders(authToken: authToken))
        }
        return (container.MediaContainer.Metadata ?? []).map { meta in
            FilmographyEntry(item: PlexMediaMapper.item(meta, providerID: id, serverURL: serverURL, authToken: authToken),
                             isOnServer: true, guid: meta.guid, tmdbId: meta.tmdbId)
        }
    }
}
