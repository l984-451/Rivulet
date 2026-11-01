// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// #413: a Plex edition is named on its poster so two editions sharing artwork tell apart.
@MainActor
final class PosterCellEditionBadgeTests: XCTestCase {
    private func movie(edition: String?) -> PlexMetadata {
        var meta = PlexMetadata()
        meta.type = "movie"
        meta.title = "The Return of the King"
        meta.editionTitle = edition
        return meta
    }

    func test_edition_showsAndClearsOnReuse() {
        let cell = PosterCell(frame: CGRect(x: 0, y: 0, width: 220, height: 400))
        cell.configure(item: movie(edition: "Extended Edition"))
        XCTAssertEqual(cell.editionBadgeText, "Extended Edition")
        cell.prepareForReuse()
        XCTAssertNil(cell.editionBadgeText)
        cell.configure(item: movie(edition: nil))
        XCTAssertNil(cell.editionBadgeText)
        cell.configure(item: movie(edition: ""))
        XCTAssertNil(cell.editionBadgeText, "an empty edition is no edition")
    }
}
