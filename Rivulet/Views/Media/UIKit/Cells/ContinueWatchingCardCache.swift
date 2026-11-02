// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContinueWatchingCardCache.swift
//  Rivulet
//
//  Fetches, builds and keeps the compositor's layers and each still's analysis,
//  in memory and on disk.
//

import ImageIO
import UIKit
import UniformTypeIdentifiers
import os

nonisolated extension ContinueWatchingCardCompositor {

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 << 20
        return cache
    }()

    /// What to build from a source image.
    enum Layer: String {
        case card, title, titleStrong
    }

    private static func cacheKey(_ layer: Layer, _ url: URL, _ geometry: Geometry, _ scale: CGFloat) -> NSString {
        "\(layer.rawValue)#\(Int(geometry.card.width * scale))#\(url.absoluteString)" as NSString
    }

    /// An already-built layer, so a reused cell can show it with no placeholder frame.
    static func cached(_ layer: Layer, for url: URL, geometry: Geometry, scale: CGFloat) -> UIImage? {
        cache.object(forKey: cacheKey(layer, url, geometry, scale))
    }

    /// The layer for a source URL: fetched and decoded by the image cache, built
    /// off the main thread, then kept by URL and pixel size.
    static func image(_ layer: Layer, for url: URL, geometry: Geometry, scale: CGFloat) async -> UIImage? {
        let key = cacheKey(layer, url, geometry, scale)
        if let cached = cache.object(forKey: key) { return cached }
        let diskKey = key as String
        var rendered = storedImage(diskKey)
        if rendered == nil {
            guard let source = await ImageCacheManager.shared.image(for: url)?.cgImage else { return nil }
            rendered = await offPool {
                let built: CGImage? = switch layer {
                case .card: render(still: source, geometry: geometry, scale: scale)
                case .title: renderTitle(logo: source, geometry: geometry, scale: scale)
                case .titleStrong: renderTitle(logo: source, geometry: geometry, scale: scale, strongShadow: true)
                }
                if let built { store(built, diskKey) }
                return built
            }
        }
        guard let rendered else { return nil }
        let image = UIImage(cgImage: rendered, scale: scale, orientation: .up)
        cache.setObject(image, forKey: key, cost: rendered.bytesPerRow * rendered.height)
        return image
    }

    /// One serial queue for Vision and drawing. Run on Swift's cooperative pool,
    /// a few cards' analysis held every thread on a 3-core Apple TV and stalled
    /// all other async work (image loads, Plex requests) behind it.
    private static let workQueue = DispatchQueue(label: "rivulet.artwork-analysis", qos: .utility)

    private static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            workQueue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Signals

    private final class SignalsBox {
        let signals: Signals
        init(_ signals: Signals) { self.signals = signals }
    }

    private static let signalsCache = NSCache<NSString, SignalsBox>()
    private static let analysing = OSAllocatedUnfairLock(initialState: [URL: Task<Signals, Never>]())

    /// A still's analysis, run once per URL off the main thread and kept. It is
    /// in unit image coordinates, so one result serves every geometry and scale.
    static func signals(for url: URL) async -> Signals {
        let key = url.absoluteString as NSString
        if let box = signalsCache.object(forKey: key) { return box.signals }
        let task = analysing.withLock { running in
            if let task = running[url] { return task }
            let task = Task.detached(priority: .userInitiated) { () -> Signals in
                defer { analysing.withLock { $0[url] = nil } }
                let diskKey = "signals#\(url.absoluteString)"
                if let stored = storedSignals(diskKey) {
                    signalsCache.setObject(SignalsBox(stored), forKey: url.absoluteString as NSString)
                    return stored
                }
                // A failed fetch is not kept: the next display tries again.
                guard let source = await ImageCacheManager.shared.image(for: url)?.cgImage else { return .none }
                let signals = await offPool { analyse(source) }
                signalsCache.setObject(SignalsBox(signals), forKey: url.absoluteString as NSString)
                // Disk keeps only a full read; a failed face pass gets another try next launch.
                if signals.faces != nil { store(signals, diskKey) }
                return signals
            }
            running[url] = task
            return task
        }
        return await task.value
    }

    // MARK: - Title check

    /// A finished `ArtworkTitleCheck`, from memory or disk; nil when it has not run.
    static func knownTitleCheck(still: URL, title: String) -> Bool? {
        ArtworkTitleCheck.known(ArtworkTitleCheck.key(still: still, title: title))
    }

    static func titleCheck(still: URL, logo: URL?, title: String) async -> Bool {
        await ArtworkTitleCheck.answer(ArtworkTitleCheck.key(still: still, title: title), title: title) {
            guard let source = await ImageCacheManager.shared.image(for: still)?.cgImage else { return nil }
            guard let logo else { return (source, nil) }
            guard let image = await ImageCacheManager.shared.image(for: logo)?.cgImage else { return nil }
            return (source, image)
        }
    }

    // MARK: - Disk

    /// Bump when `render`, `renderTitle` or `analyse` changes, so old files are not shown.
    private static let diskVersion = 1

    // ponytail: pruned by age (30 days since built) at first use, add LRU if the folder grows large.
    private static let diskDirectory: URL? = {
        let files = FileManager.default
        guard let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("ContinueWatchingCards", isDirectory: true)
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        let cutoff = Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)
        let listed = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        for file in listed ?? [] {
            let built = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (built ?? .distantPast) < cutoff { try? files.removeItem(at: file) }
        }
        return directory
    }()

    /// Empties the folder (Settings, Clear All Cache).
    static func clearDisk() {
        guard let directory = diskDirectory else { return }
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func diskURL(_ key: String) -> URL? {
        diskDirectory?.appendingPathComponent("\(diskVersion)#\(key)".sha256Hash())
    }

    private static func storedImage(_ key: String) -> CGImage? {
        guard let url = diskURL(key), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Decoded here, not on the main thread at first draw.
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private static func store(_ image: CGImage, _ key: String) {
        let data = NSMutableData()
        guard let url = diskURL(key),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        try? (data as Data).write(to: url, options: .atomic)
    }

    private static func storedSignals(_ key: String) -> Signals? {
        guard let url = diskURL(key), let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(Signals.self, from: data)
    }

    private static func store(_ signals: Signals, _ key: String) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let url = diskURL(key), let data = try? encoder.encode(signals) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
