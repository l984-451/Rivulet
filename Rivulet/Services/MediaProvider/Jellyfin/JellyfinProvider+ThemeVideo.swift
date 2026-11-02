// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

extension JellyfinProvider {
    func themeVideo(for itemRef: MediaItemRef) async throws -> ThemeVideo? {
        guard itemRef.providerID == id else { return nil }
        let result: JFQueryResult = try await client.get("Items/\(itemRef.itemID)/ThemeVideos", [
            URLQueryItem(name: "userId", value: userID),
            URLQueryItem(name: "inheritFromParent", value: "true")
        ])
        // Pick once per visit, like Jellyfin's web client. Empty libraries do
        // not incur a PlaybackInfo call, and seasons/episodes inherit server-side.
        let ids = (result.items ?? []).compactMap(\.id).filter { !$0.isEmpty }
        guard let videoID = ids.randomElement() else { return nil }
        try Task.checkCancellation()
        let response: JFPlaybackInfoResponse = try await client.post(
            "Items/\(videoID)/PlaybackInfo", body: JFPlaybackInfoRequest.themeVideo(userId: userID)
        )
        guard let source = response.mediaSources?.first(where: {
            $0.supportsDirectPlay == true || $0.transcodingUrl != nil
        }) else { return nil }

        if source.supportsDirectPlay == true {
            let mapped = JellyfinMediaMapper.mediaSource(
                source, itemID: videoID, playSessionID: response.playSessionId,
                baseURL: client.baseURL, token: client.token ?? ""
            )
            return mapped.streamURL.map { ThemeVideo(url: $0) }
        }

        guard let path = source.transcodingUrl,
              let url = themeVideoTranscodeURL(path),
              let sessionID = response.playSessionId else { return nil }
        let client = client
        let deviceID = client.deviceID
        return ThemeVideo(url: url, stop: {
            // Scope cleanup to this backdrop. A movie may already be playing
            // on the same device by the time this request reaches the server.
            try? await client.delete("Videos/ActiveEncodings", query: [
                URLQueryItem(name: "deviceId", value: deviceID),
                URLQueryItem(name: "playSessionId", value: sessionID)
            ])
        })
    }

    /// Jellyfin returns server-relative paths; reverse proxies may include
    /// their base path already. Preserve it exactly once and keep authentication.
    private func themeVideoTranscodeURL(_ path: String) -> URL? {
        let base = client.baseURL
        let basePath = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url: URL?
        if !basePath.isEmpty, path.hasPrefix("/\(basePath)/") {
            url = URL(string: path, relativeTo: base)?.absoluteURL
        } else {
            url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                      + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query = components.queryItems ?? []
        if !query.contains(where: { ["apikey", "api_key"].contains($0.name.lowercased()) }), let token = client.token {
            query.append(URLQueryItem(name: "ApiKey", value: token))
        }
        components.queryItems = query
        return components.url
    }
}
