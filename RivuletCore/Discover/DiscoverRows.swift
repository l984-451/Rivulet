// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation
import Observation

/// TMDB's curated rows for a Discover page: every `CuratedSection` in its own order,
/// less any that failed or came back empty.
@Observable @MainActor
final class DiscoverRows {
    struct Row: Identifiable {
        let section: CuratedSection
        let items: [MediaItem]
        var id: CuratedSection { section }
    }

    private(set) var rows: [Row] = []
    /// The last load found no row to show. No rows and not failed means still loading.
    private(set) var failed = false

    private let source: (any MetadataSource)?

    init(source: (any MetadataSource)?) {
        self.source = source
    }

    convenience init() {
        self.init(source: MetadataSourceRegistry.shared.source(for: TMDBMediaMapper.providerID))
    }

    /// Asks for every section at once. The rows shown stay up until the new ones arrive.
    func load() async {
        failed = false
        let found = await withTaskGroup(of: (CuratedSection, [MediaItem]).self) { [source] group in
            for section in CuratedSection.allCases {
                group.addTask { (section, (try? await source?.curatedSection(section)) ?? []) }
            }
            var found: [CuratedSection: [MediaItem]] = [:]
            for await (section, items) in group { found[section] = items }
            return found
        }
        guard !Task.isCancelled else { return }
        rows = CuratedSection.allCases.compactMap { section in
            guard let items = found[section], !items.isEmpty else { return nil }
            return Row(section: section, items: items)
        }
        failed = rows.isEmpty
    }

    /// Retry and pull to refresh: a list that just failed is asked for again at once.
    func reload() async {
        await TMDBDiscoverService.shared.forgetListFailures()
        await load()
    }
}
