// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

extension PlexProvider {
    private func subtitleSearch(_ ref: MediaItemRef) -> PlexSubtitleSearch {
        PlexSubtitleSearch(serverURL: serverURL, token: authToken, ratingKey: ref.itemID, network: networkManager)
    }

    func canSearchSubtitles() async -> Bool {
        await subtitleSearch(MediaItemRef(providerID: id, itemID: "")).isAvailable()
    }

    func searchSubtitles(for ref: MediaItemRef, language: String) async throws -> [SubtitleSearchResult] {
        try await subtitleSearch(ref).search(language: language)
    }

    func downloadSubtitle(_ result: SubtitleSearchResult, for ref: MediaItemRef) async throws {
        try await subtitleSearch(ref).download(result)
    }
}
