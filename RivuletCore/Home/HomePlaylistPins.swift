// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
//
//  Playlists shown on Home: as a row (Settings > Home > Rows) or in the hero
//  (Settings > Home > Hero), two lists stored apart. Any server with playlists,
//  keyed by provider id. JSON per Plex Home profile (`HomeSettingsScope`).
//

import Foundation

nonisolated enum HomePlaylistPins {

    struct Pin: Codable, Hashable, Sendable {
        let providerID: String
        let playlistID: String
        /// The title at pin time; Home prefers the server's current one.
        var title: String

        var id: String { "\(providerID)/\(playlistID)" }
    }

    enum Destination: Sendable, CaseIterable { case home, hero }

    /// Posted after any change to either list.
    static let changedNotification = Notification.Name("homePlaylistPinsChanged")

    private static var defaults: UserDefaults { .standard }

    private static func storageKey(for destination: Destination) -> String {
        HomeSettingsScope.key(destination == .home ? "homePlaylistPins" : "heroPlaylistPins")
    }

    /// Every row pin for the current profile, in the order they were switched on.
    static var pins: [Pin] { pins(in: .home) }

    static func pins(in destination: Destination) -> [Pin] {
        guard let data = defaults.data(forKey: storageKey(for: destination)) else { return [] }
        return (try? JSONDecoder().decode([Pin].self, from: data)) ?? []
    }

    static func isPinned(_ ref: MediaItemRef, in destination: Destination = .home) -> Bool {
        pins(in: destination).contains { $0.providerID == ref.providerID && $0.playlistID == ref.itemID }
    }

    static func pin(_ pin: Pin, in destination: Destination = .home) {
        let current = pins(in: destination)
        guard !current.contains(where: { $0.id == pin.id }) else { return }
        write(current + [pin], to: destination)
    }

    /// No-op, and no notification, when the pin is already gone.
    static func unpin(_ ref: MediaItemRef, in destination: Destination = .home) {
        let current = pins(in: destination)
        let kept = current.filter { !($0.providerID == ref.providerID && $0.playlistID == ref.itemID) }
        guard kept.count != current.count else { return }
        write(kept, to: destination)
    }

    /// A deleted playlist leaves both lists.
    static func unpinEverywhere(_ ref: MediaItemRef) {
        Destination.allCases.forEach { unpin(ref, in: $0) }
    }

    static func removeAll(in destination: Destination = .home) {
        guard !pins(in: destination).isEmpty else { return }
        write([], to: destination)
    }

    private static func write(_ pins: [Pin], to destination: Destination) {
        guard let data = try? JSONEncoder().encode(pins) else { return }
        defaults.set(data, forKey: storageKey(for: destination))
        NotificationCenter.default.post(name: changedNotification, object: nil)
        if destination == .hero { NotificationCenter.default.post(name: HeroSources.changedNotification, object: nil) }
    }
}
