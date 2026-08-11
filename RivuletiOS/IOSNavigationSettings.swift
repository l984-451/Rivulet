// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import Foundation
import SwiftUI

@MainActor
final class IOSNavigationSettings: ObservableObject {
    struct Item: Identifiable, Hashable {
        enum Kind: Hashable { case home, library, recordings, liveTV, settings, search }

        let id: String
        let title: String
        let icon: String
        let kind: Kind
        let library: PlexLibrary?
    }

    @Published var selectedTabIDs: [String] = [] { didSet { persist() } }

    private let selectionKey = "iosSelectedBottomTabs"

    init() {
        selectedTabIDs = UserDefaults.standard.stringArray(forKey: selectionKey) ?? []
    }

    func availableItems(for libraries: [PlexLibrary]) -> [Item] {
        var result = [Item(id: "home", title: "Home", icon: "house.fill", kind: .home, library: nil)]
        result.append(contentsOf: orderedLibraries(libraries).map {
            Item(id: "library:\($0.key)", title: $0.title, icon: $0.icon, kind: .library, library: $0)
        })
        result.append(Item(id: "recordings", title: "Recordings", icon: "rectangle.stack.badge.play", kind: .recordings, library: nil))
        result.append(Item(id: "live-tv", title: "Live TV", icon: "play.tv.fill", kind: .liveTV, library: nil))
        result.append(Item(id: "settings", title: "Settings", icon: "gearshape.fill", kind: .settings, library: nil))
        result.append(Item(id: "search", title: "Search", icon: "magnifyingglass", kind: .search, library: nil))
        return result
    }

    func visibleItems(for libraries: [PlexLibrary]) -> [Item] {
        let available = availableItems(for: libraries)
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        let saved = selectedTabIDs.compactMap { byID[$0] }
        if !saved.isEmpty { return Array(saved.prefix(5)) }
        return defaultItems(from: available, libraries: libraries)
    }

    func isSelected(_ item: Item, libraries: [PlexLibrary]) -> Bool {
        visibleItems(for: libraries).contains(where: { $0.id == item.id })
    }

    func canSelectMore(libraries: [PlexLibrary]) -> Bool {
        visibleItems(for: libraries).count < 5
    }

    func setSelected(_ item: Item, selected: Bool, libraries: [PlexLibrary]) {
        var ids = visibleItems(for: libraries).map(\.id)
        if selected {
            guard !ids.contains(item.id), ids.count < 5 else { return }
            ids.append(item.id)
        } else {
            guard ids.count > 1 else { return }
            ids.removeAll { $0 == item.id }
        }
        selectedTabIDs = ids
    }

    func moveSelected(from offsets: IndexSet, to destination: Int, libraries: [PlexLibrary]) {
        var ids = visibleItems(for: libraries).map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        selectedTabIDs = ids
    }

    private func orderedLibraries(_ libraries: [PlexLibrary]) -> [PlexLibrary] {
        libraries.sorted { lhs, rhs in
            let left = lhs.type == "movie" ? 0 : (lhs.type == "show" ? 1 : 2)
            let right = rhs.type == "movie" ? 0 : (rhs.type == "show" ? 1 : 2)
            return left == right
                ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                : left < right
        }
    }

    private func defaultItems(from available: [Item], libraries: [PlexLibrary]) -> [Item] {
        let movie = available.first { $0.library?.type == "movie" }
        let show = available.first { $0.library?.type == "show" }
        let preferredIDs = ["home", movie?.id, show?.id, "live-tv", "search"].compactMap { $0 }
        var result = preferredIDs.compactMap { id in available.first { $0.id == id } }
        for item in available where result.count < 5 && !result.contains(where: { $0.id == item.id }) {
            result.append(item)
        }
        return Array(result.prefix(5))
    }

    private func persist() {
        UserDefaults.standard.set(selectedTabIDs, forKey: selectionKey)
    }
}
