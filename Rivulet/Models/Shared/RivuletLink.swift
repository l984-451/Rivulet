// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  RivuletLink.swift
//  Rivulet
//
//  The one definition of a `rivulet://` deep link. Compiled into the app AND
//  the Top Shelf extension, so the builder and the parser cannot drift.
//

import Foundation

struct RivuletLink: Equatable, Sendable {
    enum Action: String, Sendable {
        case play      // start playback at the resume point
        case detail    // open the item's detail
    }

    static let scheme = "rivulet"

    let action: Action
    let ratingKey: String
    /// The server the item was cached from. Informational: the app resolves
    /// against the selected server.
    var server: String?

    init(_ action: Action, ratingKey: String, server: String? = nil) {
        self.action = action
        self.ratingKey = ratingKey
        self.server = server
    }

    /// Parses `rivulet://<action>?ratingKey=<key>` and `rivulet://<action>/<key>`.
    /// The path form exists for senders that drop the query string (the Apple TV
    /// Companion channel). A query ratingKey wins when both are present.
    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let action = url.host.flatMap(Action.init(rawValue:)),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true)
        let fromPath = segments.count == 1 ? String(segments[0]).removingPercentEncoding : nil
        let fromQuery = items.first(where: { $0.name == "ratingKey" })?.value
        guard let ratingKey = [fromQuery, fromPath].compactMap({ $0 }).first(where: { !$0.isEmpty })
        else { return nil }
        self.init(action, ratingKey: ratingKey,
                  server: items.first(where: { $0.name == "server" })?.value)
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = action.rawValue
        components.queryItems = [URLQueryItem(name: "ratingKey", value: ratingKey)]
        if let server { components.queryItems?.append(URLQueryItem(name: "server", value: server)) }
        return components.url
    }
}
