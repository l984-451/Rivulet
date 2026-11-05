// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ServerLabels.swift
//  Rivulet
//
//  Names a row's, library's or result's server once more than one is signed in, the way tvOS
//  `PlexHomeViewController.serverName(providerID:kind:)` does.
//

import Foundation

nonisolated struct ServerLabels: Sendable, Equatable {
    private let names: [String: String]
    private let kinds: [String: MediaProviderKind]

    init(_ servers: [(id: String, name: String, kind: MediaProviderKind)]) {
        names = Dictionary(servers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        kinds = Dictionary(servers.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
    }

    init(providers: [any MediaProvider]) {
        self.init(providers.map { (id: $0.id, name: $0.displayName, kind: $0.kind) })
    }

    var isMulti: Bool { names.count > 1 }

    /// The server's name for a badge; nil with one server (nothing to tell apart). Two servers
    /// with one name also say their type. An id no longer registered names its kind.
    func badge(providerID: String) -> String? {
        guard isMulti else { return nil }
        guard let name = names[providerID] else { return MediaProviderKind(providerID: providerID)?.displayName }
        let twins = names.values.filter { $0 == name }.count
        return twins > 1 ? "\(name) (\(kinds[providerID]?.displayName ?? ""))" : name
    }

    /// A title as lists show it: with its server's name once more than one is in play.
    func title(_ title: String, providerID: String) -> String {
        badge(providerID: providerID).map { "\(title) (\($0))" } ?? title
    }
}
