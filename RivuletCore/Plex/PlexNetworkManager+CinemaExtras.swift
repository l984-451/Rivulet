// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

extension PlexNetworkManager {
    /// The clips Plex plays before a movie, in order. A play queue with `extrasPrefixCount` lists
    /// them ahead of the movie: trailers, then pre-rolls (measured, PMS 1.43.5). A slow server
    /// must not hold up the movie, so the wait is short.
    func cinemaExtras(serverURL: String, authToken: String, ratingKey: String, count: Int) async throws -> [PlexMetadata] {
        let machineIdentifier = try await getMachineIdentifier(serverURL: serverURL, authToken: authToken)
        guard var components = URLComponents(string: "\(serverURL)/playQueues") else { throw PlexAPIError.invalidURL }
        components.queryItems = [
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "uri", value: Self.libraryURI(machineIdentifier: machineIdentifier, ratingKeys: [ratingKey])),
            URLQueryItem(name: "extrasPrefixCount", value: "\(count)"),
            URLQueryItem(name: "repeat", value: "0")
        ]
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        let container: PlexMediaContainerWrapper = try await request(
            url, method: "POST", headers: plexHeaders(authToken: authToken), timeout: 5)
        return Self.cinemaClips(in: container.MediaContainer.Metadata ?? [])
    }

    nonisolated static func cinemaClips(in queue: [PlexMetadata]) -> [PlexMetadata] {
        queue.filter { $0.type == "clip" }
    }
}
