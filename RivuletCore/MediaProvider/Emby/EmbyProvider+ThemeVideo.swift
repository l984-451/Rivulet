// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

extension EmbyProvider {
    /// One of the title's theme videos (episodes and seasons inherit the series'), direct play only.
    func themeVideoURL(for itemRef: MediaItemRef) async throws -> URL? {
        guard itemRef.providerID == id else { return nil }
        let result: EmbyQueryResult = try await client.get("Items/\(itemRef.itemID)/ThemeVideos", [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "InheritFromParent", value: "true")
        ])
        guard let videoID = ThemeBackdrop.pickClip(from: (result.items ?? []).map(\.id.value)) else { return nil }
        try Task.checkCancellation()
        let response: EmbyPlaybackInfoResponse = try await client.post(
            "Items/\(videoID)/PlaybackInfo", body: EmbyPlaybackInfoRequest.themeVideo(userId: userID)
        )
        guard let source = response.mediaSources?.first(where: { $0.supportsDirectPlay == true }) else { return nil }
        return EmbyMediaMapper.mediaSource(
            source, itemID: videoID, playSessionID: nil, baseURL: baseURL, token: client.token
        )?.streamURL
    }
}
