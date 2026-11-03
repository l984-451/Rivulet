// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A Plex external subtitle's URL. The engine and the content filter read text as UTF-8 only, so a
/// Windows-1255 SRT yields nothing (#513). `encoding=utf-8` has PMS convert it (measured, PMS 1.43.5).
nonisolated enum PlexSidecarURL {
    static let textCodecs: Set<String> = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt"]

    static func url(serverURL: String, key: String, token: String, codec: String?) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)\(key)") else { return nil }
        var items = components.queryItems ?? []
        if let codec, textCodecs.contains(codec.lowercased()),
           !items.contains(where: { $0.name == "encoding" }) {
            items.append(URLQueryItem(name: "encoding", value: "utf-8"))
        }
        items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        components.queryItems = items
        return components.url
    }
}
