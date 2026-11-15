// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContinueWatchingTitlePlacer.swift
//  Rivulet
//
//  Where the iOS and Mac Continue Watching cards put the title: the tvOS
//  analysis and scoring, with the still's signals kept in memory.
//

import CoreGraphics
import Foundation
import os

nonisolated enum ContinueWatchingTitlePlacer {
    private final class Box { let signals: ContinueWatchingCardCompositor.Signals
        init(_ signals: ContinueWatchingCardCompositor.Signals) { self.signals = signals } }

    private static let cache = NSCache<NSString, Box>()
    /// One serial queue for Vision; on the cooperative pool it starves other async work.
    private static let queue = DispatchQueue(label: "rivulet.artwork-analysis", qos: .utility)
    private static let inflight = OSAllocatedUnfairLock(initialState: [String: Task<ContinueWatchingCardCompositor.Signals, Never>]())

    /// A still's analysis, run once per key off the main thread. ponytail: memory only, add a disk cache if launches feel slow.
    static func signals(key: String, still: @escaping @Sendable () async -> CGImage?) async -> ContinueWatchingCardCompositor.Signals {
        if let box = cache.object(forKey: key as NSString) { return box.signals }
        let task = inflight.withLock { map in
            if let task = map[key] { return task }
            let task = Task.detached(priority: .userInitiated) { () -> ContinueWatchingCardCompositor.Signals in
                defer { inflight.withLock { $0[key] = nil } }
                guard let image = await still() else { return .none }
                let signals = await withCheckedContinuation { continuation in
                    queue.async { continuation.resume(returning: ContinueWatchingCardCompositor.analyse(image)) }
                }
                if signals.faces != nil { cache.setObject(Box(signals), forKey: key as NSString) }
                return signals
            }
            map[key] = task
            return task
        }
        return await task.value
    }

    /// The title's box on a card of this size: leading on the floor until the signals say otherwise.
    static func titleRect(card: CGSize, signals: ContinueWatchingCardCompositor.Signals,
                          logoSize: CGSize?) -> (rect: CGRect, side: ContinueWatchingCardCompositor.Side) {
        let geometry = ContinueWatchingCardCompositor.Geometry(cardWidth: card.width, cardHeight: card.height)
        let placement = ContinueWatchingCardCompositor.placement(signals: signals, logoSize: logoSize, geometry: geometry)
        let footprint = geometry.titleFootprint(logoSize: logoSize)
        return (geometry.titleRect(footprint, side: placement.side, offset: placement.offset, scale: placement.scale), placement.side)
    }
}
