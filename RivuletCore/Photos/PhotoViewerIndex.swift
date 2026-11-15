// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoViewerIndex.swift
//  Rivulet
//

import Foundation

/// Where a step from one photo lands.
nonisolated enum PhotoViewerIndex {
    /// The next index `by` (+1 or -1) from `from` that `skipping` lets through.
    /// Stops at the ends unless `wraps`; nil when there is nowhere to go.
    static func step(from: Int, by: Int, count: Int, wraps: Bool, skipping: (Int) -> Bool = { _ in false }) -> Int? {
        guard count > 0, by != 0 else { return nil }
        var index = from
        for _ in 0..<count {
            index += by.signum()
            if !(0..<count).contains(index) {
                guard wraps else { return nil }
                index = (index + count) % count
            }
            if index == from { return nil }
            if !skipping(index) { return index }
        }
        return nil
    }
}
