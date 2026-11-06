// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SidebarArrangement.swift
//  Rivulet
//
//  The sidebar's arrangeable rows as string keys, stored in the per-profile
//  library order. Library keys are Plex section keys ("12") or
//  "<providerID>/<id>"; every other row's key starts with "#".
//

import Foundation

enum SidebarArrangement {
    static let discover = "#discover"
    static let watchlist = "#watchlist"
    /// Favorite movies and shows from every server.
    static let favorites = "#favorites"
    /// Live TV with its sources combined.
    static let liveTV = "#livetv"
    /// Where libraries go while the order holds none (a fresh install). Never shown.
    static let librariesAnchor = "#libraries"
    /// In the hidden set: every Playlists row, from the retired Show Playlists toggle.
    static let allPlaylistsHidden = "#playlists/*"

    static func liveTV(source: String) -> String { "#livetv/" + source }
    /// `server` is the library keys' server: "" for the selected Plex server, else its provider id.
    static func playlists(server: String) -> String { playlistsPrefix + server }

    private static let playlistsPrefix = "#playlists/"

    /// Any row that is not a library.
    static func isAppRow(_ key: String) -> Bool { key.hasPrefix("#") }

    static func isLiveTV(_ key: String) -> Bool { key == liveTV || key.hasPrefix("#livetv/") }

    /// The server a row belongs to: libraries and Playlists rows; nil for the rest.
    static func server(ofKey key: String) -> String? {
        if key.hasPrefix(playlistsPrefix) { return String(key.dropFirst(playlistsPrefix.count)) }
        if isAppRow(key) { return nil }
        return key.contains(":") ? String(key.prefix { $0 != "/" }) : ""
    }

    /// Today's fixed layout as an order, for a profile that has never stored one.
    static func seed(libraryOrder: [String], discoverAbove: Bool, liveTVAbove: Bool) -> [String] {
        (discoverAbove ? [discover] : []) + [watchlist, favorites]
            + (liveTVAbove ? [liveTV] : []) + [librariesAnchor]
            + libraryOrder.filter { !isAppRow($0) }
            + (liveTVAbove ? [] : [liveTV]) + (discoverAbove ? [] : [discover])
    }

    /// Whether `order` was seeded already.
    static func isSeeded(_ order: [String]) -> Bool { order.contains(librariesAnchor) }

    /// `key` placed in `order` next to its kin: after the last row of its server
    /// (a library after its server's last library),
    /// after the last Live TV row, else (a server's first row) after the last
    /// server row or the libraries anchor, else last.
    static func insert(_ key: String, into order: [String]) -> [String] {
        guard !order.contains(key) else { return order }
        var order = order
        let server = server(ofKey: key)
        let kin: Int?
        if let server {
            // A library goes after its server's libraries, before its Playlists row.
            kin = (isAppRow(key) ? nil : order.lastIndex { !isAppRow($0) && self.server(ofKey: $0) == server })
                ?? order.lastIndex { self.server(ofKey: $0) == server }
                ?? order.lastIndex { self.server(ofKey: $0) != nil }
                ?? order.firstIndex(of: librariesAnchor)
        } else if isLiveTV(key) {
            kin = order.lastIndex(where: isLiveTV)
        } else if key == favorites {
            // Beside the watchlist, its account-level sibling, in an order stored before Favorites existed.
            kin = order.firstIndex(of: watchlist) ?? order.firstIndex(of: discover)
                ?? order.firstIndex(of: librariesAnchor).map { $0 - 1 }
        } else {
            kin = nil
        }
        order.insert(key, at: kin.map { $0 + 1 } ?? order.count)
        return order
    }

    /// The rows present, `keys`, in the stored order, new ones placed by `insert`.
    static func arrange(_ keys: [String], order: [String]) -> [String] {
        let full = keys.reduce(order) { insert($1, into: $0) }
        let present = Set(keys)
        return full.filter(present.contains)
    }

    /// `order` with `key` moved one place up or down among `visible` (the rows
    /// shown, in order). Rows not shown keep their places. Off either end: unchanged.
    static func move(_ key: String, up: Bool, visible: [String], order: [String]) -> [String] {
        guard let i = visible.firstIndex(of: key), visible.indices.contains(up ? i - 1 : i + 1) else { return order }
        let neighbour = visible[up ? i - 1 : i + 1]
        var full = visible.reduce(order) { insert($1, into: $0) }
        full.removeAll { $0 == key }
        let j = full.firstIndex(of: neighbour)!
        full.insert(key, at: up ? j : j + 1)
        return full
    }

    /// One group of rows: a server's run (`server` set), or rows with no header.
    struct Section: Equatable {
        let server: String?
        let keys: [String]
    }

    /// `ordered` cut into sections. While each server's rows form one unbroken
    /// run, each run is a section for its header, and the rows between sit
    /// header-less. Once any server's rows are split, by another server's or by
    /// any other row: one section, no header, no gaps.
    static func sections(_ ordered: [String]) -> (sections: [Section], grouped: Bool) {
        guard isGrouped(ordered.map(server(ofKey:))) else { return ([Section(server: nil, keys: ordered)], false) }
        var sections: [Section] = []
        for key in ordered {
            let server = server(ofKey: key)
            if let last = sections.last, last.server == server {
                sections[sections.count - 1] = Section(server: server, keys: last.keys + [key])
            } else {
                sections.append(Section(server: server, keys: [key]))
            }
        }
        return (sections, true)
    }

    /// Whether each server's rows form one run; nil (any other row) ends a run.
    private static func isGrouped(_ servers: [String?]) -> Bool {
        var seen: Set<String> = []
        var current: String?
        for server in servers where server != current {
            current = server
            guard let server else { continue }
            guard seen.insert(server).inserted else { return false }
        }
        return true
    }
}
