// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A list sized by the server's total and filled a page at a time, in any order,
/// so a grid lays out its full length before every page has arrived.
struct PagedSlots<Item> {
    let pageSize: Int
    /// One entry per item; nil until its page arrives. Empty until the first page.
    private(set) var slots: [Item?] = []
    /// Starts of pages fetched or in flight.
    private var claimed = Set<Int>()

    init(pageSize: Int) {
        self.pageSize = pageSize
    }

    var claimedPages: [Int] { claimed.sorted() }

    /// The start of the page holding `index`, when nothing has fetched it yet.
    func unclaimedPage(containing index: Int) -> Int? {
        guard index >= 0 else { return nil }
        let start = index / pageSize * pageSize
        return claimed.contains(start) ? nil : start
    }

    mutating func claim(_ start: Int) {
        claimed.insert(start)
    }

    /// Lets a failed page be fetched again.
    mutating func release(_ start: Int) {
        claimed.remove(start)
    }

    /// Stores a page and resizes to `total`. A short page that falls before the
    /// total means the server's count overstated, so the list ends there.
    mutating func fill(_ items: [Item], at start: Int, total: Int?) {
        var count = total ?? start + items.count
        if items.count < pageSize, start + items.count < count { count = start + items.count }
        if slots.count < count {
            slots.append(contentsOf: [Item?](repeating: nil, count: count - slots.count))
        } else if slots.count > count {
            slots.removeLast(slots.count - count)
        }
        for (offset, item) in items.enumerated() where start + offset < count {
            slots[start + offset] = item
        }
    }
}
