// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Testing
import UIKit
@testable import Rivulet

@MainActor
struct ShelfRowGeometryTests {
    @Test(arguments: [false, true], [false, true])
    func preparesViewportWithoutLateWidthRepair(initiallySized: Bool, hasHeader: Bool) throws {
        let height = MediaRowMetrics.posterHeight + MediaRowMetrics.focusGrowthPadding
            + (hasHeader ? ShelfRowCell.headerHeight : 0)
        let row = ShelfRowCell(frame: CGRect(x: 0, y: 0, width: initiallySized ? 1920 : 0, height: height))
        row.headerTitle = hasHeader ? "Related" : nil
        let inner = try #require(row.rowCollectionView)
        var requests: [Int] = []
        row.cellProvider = { collection, path in
            requests.append(path.item)
            return collection.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: path)
        }
        row.configure(kind: .poster, realCount: 20, hasSkeleton: false,
                      contentToken: 1, initialOffset: 0, panelOvershoot: (left: hasHeader ? 30 : 0, right: 0))
        #expect(abs(inner.bounds.width - row.contentView.bounds.width) < 0.01)
        let initiallyPrepared = requests
        row.bounds.size.width = 1920
        row.setNeedsLayout()
        row.layoutIfNeeded()
        #expect(abs(inner.bounds.width - row.contentView.bounds.width) < 0.01)
        if initiallySized {
            #expect(requests == initiallyPrepared)
        }
        let prepared = requests
        row.layoutIfNeeded()
        inner.layoutIfNeeded()
        #expect(requests == prepared)
        #expect(inner.indexPathsForVisibleItems.count > 1)
        #expect(abs(inner.frame.minY - (hasHeader ? ShelfRowCell.headerHeight : 0)) < 0.01)

        row.prepareForReuse()
        row.configure(kind: .poster, realCount: 20, hasSkeleton: false,
                      contentToken: 2, initialOffset: 600,
                      panelOvershoot: (left: hasHeader ? 30 : 0, right: 0))
        #expect(inner.contentOffset.x == 600)
        row.bounds.size.width = 1280
        row.setNeedsLayout()
        row.layoutIfNeeded()
        #expect(abs(inner.bounds.width - row.contentView.bounds.width) < 0.01)
        #expect(inner.contentOffset.x == 600)
    }
}
