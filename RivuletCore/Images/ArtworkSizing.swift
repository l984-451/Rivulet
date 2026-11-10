// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

/// Asks a media server for artwork already sized for a tile. A stored poster is often
/// 2000x3000 and a backdrop 3840x2160; a tile decodes at most 900 px of either.
nonisolated enum ArtworkSizing {
    /// JPEG quality asked of the server. Measured on PMS 1.43: 95 stays within about 3 dB of
    /// decoding the original, at a quarter of its bytes.
    static let quality = 95

    /// `url` rewritten to return a copy fitted inside `maxPixel` square, never upscaled.
    /// Anything that is not a Plex, Jellyfin or Emby poster, still or backdrop comes back unchanged.
    static func fitted(_ url: URL, maxPixel: Int) -> URL {
        let path = url.path
        if path.contains("/library/metadata/") { return plex(url, path: path, maxPixel: maxPixel) ?? url }
        if path.contains("/Images/") { return jellyfinOrEmby(url, path: path, maxPixel: maxPixel) ?? url }
        return url
    }

    /// `/library/metadata/<key>/thumb|art[/<stamp>]` becomes a photo transcoder request on the
    /// same server. Logos keep their own path: the transcoder saves nothing on them.
    private static func plex(_ url: URL, path: String, maxPixel: Int) -> URL? {
        guard let range = path.range(of: "/library/metadata/"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = path[range.upperBound...].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, parts[1] == "thumb" || parts[1] == "art",
              parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        // Only the token may ride along: a path with its own query is not plain artwork.
        let query = components.queryItems ?? []
        guard query.count == 1, query[0].name == "X-Plex-Token", let token = query[0].value else { return nil }

        components.path = String(path[..<range.lowerBound]) + "/photo/:/transcode"
        components.queryItems = [
            URLQueryItem(name: "url", value: String(path[range.lowerBound...])),
            URLQueryItem(name: "width", value: "\(maxPixel)"),
            URLQueryItem(name: "height", value: "\(maxPixel)"),
            URLQueryItem(name: "quality", value: "\(quality)"),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]
        return components.url
    }

    /// `/Items/<id>/Images/Primary|Backdrop|Thumb[/<index>]` gains a size box. Both servers read
    /// these names in either case.
    private static func jellyfinOrEmby(_ url: URL, path: String, maxPixel: Int) -> URL? {
        guard let range = path.range(of: "/Images/"), path[..<range.lowerBound].contains("/Items/"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = path[range.upperBound...].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2, ["Primary", "Backdrop", "Thumb"].contains(String(parts[0])) else {
            return nil
        }
        let sizing: Set<String> = ["fillwidth", "fillheight", "maxwidth", "maxheight", "width", "height", "quality"]
        let query = components.queryItems ?? []
        // Already sized by its caller: leave it.
        guard !query.contains(where: { sizing.contains($0.name.lowercased()) }) else { return nil }
        components.queryItems = query + [
            URLQueryItem(name: "MaxWidth", value: "\(maxPixel)"),
            URLQueryItem(name: "MaxHeight", value: "\(maxPixel)"),
            URLQueryItem(name: "Quality", value: "\(quality)")
        ]
        return components.url
    }
}
