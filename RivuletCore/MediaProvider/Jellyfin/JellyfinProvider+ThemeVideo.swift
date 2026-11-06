// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

extension JellyfinProvider {
    /// One of the title's theme videos (episodes and seasons inherit the series'), direct play only.
    func themeVideoURL(for itemRef: MediaItemRef) async throws -> URL? {
        guard itemRef.providerID == id else { return nil }
        let result: JFQueryResult = try await client.get("Items/\(itemRef.itemID)/ThemeVideos", [
            URLQueryItem(name: "userId", value: userID),
            URLQueryItem(name: "inheritFromParent", value: "true")
        ])
        guard let videoID = ThemeBackdrop.pickClip(from: (result.items ?? []).map(\.id)) else { return nil }
        try Task.checkCancellation()
        let response: JFPlaybackInfoResponse = try await client.post(
            "Items/\(videoID)/PlaybackInfo", body: JFPlaybackInfoRequest.themeVideo(userId: userID)
        )
        guard let source = response.mediaSources?.first(where: { $0.supportsDirectPlay == true }) else { return nil }
        return JellyfinMediaMapper.mediaSource(
            source, itemID: videoID, playSessionID: nil, baseURL: client.baseURL, token: client.token ?? ""
        ).streamURL
    }
}
