// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  YouTubeTrailer.swift
//  Rivulet
//
//  The internet trailers Jellyfin and Emby list beside a title (`RemoteTrailers`,
//  from TMDB) are YouTube links. YouTube cannot play in the app's own player,
//  so a trailer opens in the YouTube app.
//

import Foundation

enum YouTubeTrailer {
    /// The video id of a YouTube watch, short or embed link; nil for any other URL.
    nonisolated static func videoID(from url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let candidate: String?
        if host == "youtu.be" {
            candidate = url.pathComponents.dropFirst().first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            let parts = url.pathComponents
            if parts.count >= 3, ["embed", "shorts", "v"].contains(parts[1]) {
                candidate = parts[2]
            } else {
                candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "v" }?.value
            }
        } else {
            candidate = nil
        }
        guard let id = candidate, isVideoID(id) else { return nil }
        return id
    }

    /// The first YouTube link among a server's remote trailer URLs.
    nonisolated static func firstLink(_ urls: [String?]) -> URL? {
        urls.lazy.compactMap { $0.flatMap(URL.init(string:)) }.first { videoID(from: $0) != nil }
    }

    /// The link that opens the video in the YouTube app.
    nonisolated static func appURL(videoID: String) -> URL? {
        URL(string: "youtube://watch/\(videoID)")
    }

    /// The same video on the web, for when the app is missing.
    nonisolated static func webURL(videoID: String) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)")
    }

    /// YouTube ids are 11 characters of letters, digits, "-" and "_".
    nonisolated private static func isVideoID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
