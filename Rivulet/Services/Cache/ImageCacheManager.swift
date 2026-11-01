// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ImageCacheManager.swift
//  Rivulet
//
//  Persistent image cache with weeks-long TTL and SSL support for Plex servers
//

import UIKit
import Foundation
import ImageIO

/// Decode size for a cached image; the disk keeps the original bytes. tvOS renders at 1080p
/// and upscales to 4K, so 3840 px (2x the screen width) is the ceiling; `thumb` is 2x a ~444 pt poster.
enum ImageQuality: Sendable {
    /// Small UI: poster rows, continue-watching, cast, episode stills, logos, blurred backdrops.
    case thumb
    /// Large surfaces that fill much of the screen: home hero, carousel, detail backdrops.
    case full
    /// Channel logos drawn at under 128 pt. A 900 px decode of each was about 1 MB per logo.
    case logo

    nonisolated var maxPixelSize: CGFloat {
        switch self {
        case .thumb: return 900
        case .full:  return 3840
        case .logo:  return 256
        }
    }

    nonisolated fileprivate var keySuffix: String {
        switch self {
        case .thumb: return "t"
        case .full:  return "f"
        case .logo:  return "l"
        }
    }
}

/// Cache entry metadata for tracking access times and TTL
struct ImageCacheEntry: Codable {
    let url: String
    let cachedAt: Date
    var lastAccessedAt: Date
    let fileSize: Int64
}

/// Actor-based image cache with disk persistence, LRU eviction, and SSL support
actor ImageCacheManager: NSObject {
    static let shared = ImageCacheManager()

    // MARK: - Configuration

    private let cacheDirectoryName = "PlexImageCache"
    private let metadataFileName = "image_cache_metadata.json"
    private let maxMemoryCacheCount = 100
    private let maxKeyCacheCount = 2048
    private let maxDiskCacheSize: Int64 = 5 * 1024 * 1024 * 1024  // 5GB
    private let defaultTTL: TimeInterval = 14 * 24 * 60 * 60  // 2 weeks

    // MARK: - Caches

    // NSCache is thread-safe, which is what lets `cachedImage` be nonisolated.
    nonisolated(unsafe) private let memoryCache = NSCache<NSString, UIImage>()
    nonisolated(unsafe) private let keyCache = NSCache<NSString, NSString>()
    private var cacheMetadata: [String: ImageCacheEntry] = [:]
    private var metadataLoaded = false
    /// Bytes on disk, measured once and then kept up to date, so a download never lists the
    /// directory. Rewriting the metadata and listing the cache per download was O(cache size)
    /// on every image, which stalled every image load during a logo flood.
    private var diskBytes: Int64?
    private var metadataSaveScheduled = false

    // MARK: - URL Session (with SSL handling)

    private var _session: URLSession?
    private var session: URLSession {
        if let existing = _session {
            return existing
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        let newSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _session = newSession
        return newSession
    }

    // MARK: - Active Downloads (prevent duplicate byte fetches)

    /// A shared fetch, cancelled once every caller waiting on it is cancelled,
    /// so tiles scrolled past do not queue ahead of the ones on screen.
    private struct Download {
        let id: UUID
        let task: Task<Data?, Never>
        var waiters: Int
    }
    private var activeDownloads: [URL: Download] = [:]
    /// URLs the server answered 4xx for this session; a dead channel logo otherwise
    /// re-requests every time its cell is configured.
    private var missingURLs: Set<URL> = []

    // MARK: - Cache Directory

    private var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(cacheDirectoryName)
    }

    // MARK: - Initialization

    override private init() {
        super.init()
        memoryCache.countLimit = maxMemoryCacheCount
        // By bytes too: 100 screen-sized bitmaps are several GB.
        memoryCache.totalCostLimit = 400 * 1024 * 1024
        keyCache.countLimit = maxKeyCacheCount
        Task {
            await createCacheDirectoryIfNeeded()
            await loadMetadata()
        }
    }

    private func createCacheDirectoryIfNeeded() {
        guard let cacheDir = cacheDirectory else { return }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Check memory cache only (for instant display without loading state).
    /// Synchronous from any thread.
    nonisolated func cachedImage(for url: URL, quality: ImageQuality = .thumb) -> UIImage? {
        memoryCache.object(forKey: memoryKey(diskKey: cacheKey(for: url), quality: quality))
    }

    /// Disk cache key (per URL). The on-disk file is the original downloaded bytes,
    /// independent of decode size, so the key does not include quality.
    nonisolated private func cacheKey(for url: URL) -> String {
        let urlKey = url.absoluteString as NSString
        if let cachedKey = keyCache.object(forKey: urlKey) {
            return cachedKey as String
        }
        let hashed = url.absoluteString.sha256Hash()
        keyCache.setObject(hashed as NSString, forKey: urlKey)
        return hashed
    }

    /// Memory cache key (per URL *and* decode size). A poster shown as a small card and
    /// the same poster shown full-screen must not evict each other's decoded bitmap.
    nonisolated private func memoryKey(diskKey: String, quality: ImageQuality) -> NSString {
        "\(diskKey)#\(quality.keySuffix)" as NSString
    }

    nonisolated private static func byteCost(_ image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    }

    /// Get an image at the requested `quality`, decoded off the main thread.
    /// Stale-while-revalidate: returns cached immediately, refreshes in background if stale.
    func image(for url: URL, quality: ImageQuality = .thumb, forceRefresh: Bool = false) async -> UIImage? {
        let diskKey = cacheKey(for: url)
        let memKey = memoryKey(diskKey: diskKey, quality: quality)

        // 1. Memory cache (already decoded at this quality)
        if !forceRefresh, let cached = memoryCache.object(forKey: memKey) {
            updateAccessTime(for: diskKey)
            scheduleStaleRefresh(url: url, key: diskKey)
            return cached
        }

        // 2. Disk cache — decode the stored original bytes to the requested size
        if !forceRefresh, let cacheDir = cacheDirectory {
            let maxPx = quality.maxPixelSize
            let decoded = await Task.detached(priority: .userInitiated) { [cacheDir] in
                self.loadFromDiskSync(cacheDir: cacheDir, key: diskKey, maxPixelSize: maxPx)
            }.value

            if let decoded {
                memoryCache.setObject(decoded, forKey: memKey, cost: Self.byteCost(decoded))
                updateAccessTime(for: diskKey)
                scheduleStaleRefresh(url: url, key: diskKey)
                return decoded
            }
        }

        // 3. Download original bytes (coalesced), then decode to the requested size
        guard let data = await fetchOriginalData(url: url, key: diskKey) else { return nil }
        let decoded = await decodeDownsampled(data: data, maxPixelSize: quality.maxPixelSize)
        if let decoded {
            memoryCache.setObject(decoded, forKey: memKey, cost: Self.byteCost(decoded))
        }
        return decoded
    }

    /// Get an image at full resolution for hero/backdrop surfaces.
    /// Thin wrapper over `image(for:quality:)` — kept for call-site clarity.
    func imageFullSize(for url: URL, forceRefresh: Bool = false) async -> UIImage? {
        await image(for: url, quality: .full, forceRefresh: forceRefresh)
    }

    /// Prefetch images in background (limited concurrency).
    /// Defaults to `.thumb`: this warms the on-disk original bytes (the expensive part is
    /// the network), so a later `.full` read decodes straight from disk without re-downloading.
    func prefetch(urls: [URL], quality: ImageQuality = .thumb) {
        Task.detached(priority: .utility) { [weak self] in
            // Limit to 30 URLs, 8 concurrent for faster prefetch
            let urlsToFetch = Array(urls.prefix(30))
            await withTaskGroup(of: Void.self) { group in
                var count = 0
                for url in urlsToFetch {
                    if count >= 8 {
                        await group.next()
                        count -= 1
                    }
                    group.addTask {
                        _ = await self?.image(for: url, quality: quality)
                    }
                    count += 1
                }
            }
        }
    }

    /// Clear all cached images
    func clearAll() async {
        memoryCache.removeAllObjects()
        cacheMetadata.removeAll()
        diskBytes = 0
        missingURLs.removeAll()

        guard let dir = cacheDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saveMetadata()
    }

    /// Get total disk cache size in bytes
    func getCacheSize() -> Int64 {
        guard let dir = cacheDirectory else { return 0 }
        var size: Int64 = 0

        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in files {
                if let fileSize = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    size += Int64(fileSize)
                }
            }
        }
        return size
    }

    /// Get formatted cache size string
    func getFormattedCacheSize() -> String {
        let bytes = getCacheSize()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Get raw image data for a URL (for Vision processing)
    /// Returns cached data or downloads if needed
    func imageData(for url: URL) async -> Data? {
        let key = cacheKey(for: url)

        // Check disk cache first
        if let cacheDir = cacheDirectory {
            let fileURL = cacheDir.appendingPathComponent(key)
            if let data = try? Data(contentsOf: fileURL) {
                return data
            }
        }

        // Download (coalesced) and persist if needed
        return await fetchOriginalData(url: url, key: key)
    }

    /// The image's width in pixels, read from its header without decoding. Fetches and caches the original.
    func pixelWidth(for url: URL) async -> Int? {
        guard let data = await imageData(for: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties[kCGImagePropertyPixelWidth] as? Int
    }

    // MARK: - Private Implementation

    private func scheduleStaleRefresh(url: URL, key: String) {
        Task.detached(priority: .low) { [weak self] in
            await self?.refreshIfStale(url: url, key: key)
        }
    }

    private func updateAccessTime(for key: String) {
        if var entry = cacheMetadata[key] {
            entry.lastAccessedAt = Date()
            cacheMetadata[key] = entry
            // Don't save immediately to avoid excessive I/O, will be saved on next write
        }
    }

    private func refreshIfStale(url: URL, key: String) async {
        await ensureMetadataLoaded()
        guard let entry = cacheMetadata[key] else { return }
        let age = Date().timeIntervalSince(entry.cachedAt)

        // Refresh if older than TTL
        if age > defaultTTL {
            if await fetchOriginalData(url: url, key: key) != nil {
                // Drop decoded tiers so the next read re-decodes the fresh bytes.
                for quality in [ImageQuality.thumb, .full, .logo] {
                    memoryCache.removeObject(forKey: memoryKey(diskKey: key, quality: quality))
                }
            }
        }
    }

    /// Download the original image bytes, validate, persist to disk, and return them.
    /// Coalesced per-URL so concurrent requests share a single network fetch.
    private func fetchOriginalData(url: URL, key: String) async -> Data? {
        guard !missingURLs.contains(url) else { return nil }
        if var existing = activeDownloads[url] {
            existing.waiters += 1
            activeDownloads[url] = existing
            return await wait(for: existing, url: url)
        }

        let id = UUID()
        let task = Task<Data?, Never> { [weak self] in
            guard let self = self else { return nil }

            defer {
                Task { await self.removeActiveDownload(for: url, id: id) }
            }

            // Bounded retry: Plex's image/transcode endpoints transiently 5xx, time
            // out, or return incomplete bytes under load. Retry those a couple of times
            // with backoff so a single blip doesn't strand a poster on the failure icon
            // forever. A 4xx (the art genuinely isn't there) is terminal — no retry.
            let maxAttempts = 3
            let backoff: [UInt64] = [500_000_000, 1_500_000_000] // ns before retries 2 and 3

            for attempt in 0..<maxAttempts {
                let isLastAttempt = attempt == maxAttempts - 1
                do {
                    let (data, response) = try await self.session.data(from: url)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        return nil
                    }

                    let status = httpResponse.statusCode
                    if status == 200 {
                        // Validate image data is complete before caching. Incomplete or
                        // corrupt bytes are treated as a transient failure (retryable).
                        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                              CGImageSourceGetStatus(imageSource) == .statusComplete,
                              CGImageSourceGetCount(imageSource) > 0 else {
                            print("💾 ImageCacheManager: incomplete/corrupt image data from \(url.lastPathComponent) (attempt \(attempt + 1)/\(maxAttempts))")
                            if isLastAttempt { return nil }
                            try? await Task.sleep(nanoseconds: backoff[attempt])
                            continue
                        }

                        await self.saveToDisk(data: data, key: key, url: url)
                        return data
                    }

                    // 5xx is transient (retry); 4xx and other statuses are terminal.
                    if (500...599).contains(status), !isLastAttempt {
                        print("💾 ImageCacheManager: HTTP \(status) for \(url.lastPathComponent), retrying (attempt \(attempt + 1)/\(maxAttempts))")
                        try? await Task.sleep(nanoseconds: backoff[attempt])
                        continue
                    }
                    if (400...499).contains(status), status != 408, status != 429 { await self.markMissing(url) }
                    return nil
                } catch {
                    if Task.isCancelled { return nil }
                    // Network error / timeout — retryable.
                    print("💾 ImageCacheManager: Download failed for \(url.lastPathComponent) (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)")
                    if isLastAttempt { return nil }
                    try? await Task.sleep(nanoseconds: backoff[attempt])
                    continue
                }
            }
            return nil
        }

        let download = Download(id: id, task: task, waiters: 1)
        activeDownloads[url] = download
        return await wait(for: download, url: url)
    }

    private func wait(for download: Download, url: URL) async -> Data? {
        await withTaskCancellationHandler {
            await download.task.value
        } onCancel: {
            Task { await self.dropWaiter(for: url, id: download.id) }
        }
    }

    private func dropWaiter(for url: URL, id: UUID) {
        guard var download = activeDownloads[url], download.id == id else { return }
        download.waiters -= 1
        if download.waiters > 0 {
            activeDownloads[url] = download
        } else {
            activeDownloads[url] = nil
            download.task.cancel()
        }
    }

    private func markMissing(_ url: URL) {
        missingURLs.insert(url)
    }

    private func removeActiveDownload(for url: URL, id: UUID) {
        if activeDownloads[url]?.id == id { activeDownloads[url] = nil }
    }

    // MARK: - Disk Operations

    private func saveToDisk(data: Data, key: String, url: URL) {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(key)
        loadMetadataIfNeeded()

        do {
            try data.write(to: fileURL, options: .atomic)
            diskBytes? += Int64(data.count) - (cacheMetadata[key]?.fileSize ?? 0)

            // Update metadata
            let entry = ImageCacheEntry(
                url: SensitiveDataRedactor.redact(url.absoluteString),  // written to Caches; no token on disk
                cachedAt: Date(),
                lastAccessedAt: Date(),
                fileSize: Int64(data.count)
            )
            cacheMetadata[key] = entry
            scheduleMetadataSave()
            evictIfNeeded()
        } catch {
            print("💾 ImageCacheManager: Failed to save image to disk: \(error.localizedDescription)")
        }
    }

    // MARK: - LRU Eviction

    private func evictIfNeeded() {
        let currentSize = diskBytes ?? measureDiskAndDropOrphans()
        guard currentSize > maxDiskCacheSize else { return }

        // Sort by last accessed time (oldest first)
        let sortedEntries = cacheMetadata.sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }

        var freedSpace: Int64 = 0
        let targetFreeSpace = currentSize - (maxDiskCacheSize * 8 / 10)  // Free up to 80% of max

        guard let cacheDir = cacheDirectory else { return }

        for (key, entry) in sortedEntries {
            if freedSpace >= targetFreeSpace { break }

            let fileURL = cacheDir.appendingPathComponent(key)
            do {
                try FileManager.default.removeItem(at: fileURL)
                freedSpace += entry.fileSize
                diskBytes? -= entry.fileSize
                cacheMetadata.removeValue(forKey: key)
                // Drop any decoded tiers for this key
                for quality in [ImageQuality.thumb, .full, .logo] {
                    memoryCache.removeObject(forKey: memoryKey(diskKey: key, quality: quality))
                }
            } catch {
                // File might already be gone
            }
        }

        scheduleMetadataSave()
    }

    /// Lists the cache once: sums its size and deletes files the metadata doesn't track (a file
    /// written within the save debounce of the app being killed), which LRU eviction can't reach.
    private func measureDiskAndDropOrphans() -> Int64 {
        guard let dir = cacheDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var size: Int64 = 0
        for file in files where file.lastPathComponent != metadataFileName {
            if cacheMetadata[file.lastPathComponent] == nil {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            size += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        diskBytes = size
        return size
    }

    // MARK: - Metadata Persistence

    private func ensureMetadataLoaded() async {
        loadMetadataIfNeeded()
    }

    private func loadMetadataIfNeeded() {
        if !metadataLoaded {
            loadMetadata()
        }
    }

    /// Writes the metadata at most every 5 s instead of once per download.
    private func scheduleMetadataSave() {
        guard !metadataSaveScheduled else { return }
        metadataSaveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(5))
            metadataSaveScheduled = false
            saveMetadata()
        }
    }

    private func loadMetadata() {
        guard !metadataLoaded, let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(metadataFileName)

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: ImageCacheEntry].self, from: data) else {
            metadataLoaded = true
            return
        }

        // Entries saved before this load ran are newer than the file's.
        cacheMetadata = decoded.merging(cacheMetadata) { _, new in new }
        metadataLoaded = true

        // One-time scrub of tokens older builds wrote into the metadata file.
        let tokenized = decoded.filter { $0.value.url.contains("Token=") && !$0.value.url.contains("Token=[redacted]") }
        guard !tokenized.isEmpty else { return }
        for (key, entry) in tokenized {
            cacheMetadata[key] = ImageCacheEntry(url: SensitiveDataRedactor.redact(entry.url), cachedAt: entry.cachedAt,
                                                 lastAccessedAt: entry.lastAccessedAt, fileSize: entry.fileSize)
        }
        saveMetadata()
    }

    private func saveMetadata() {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(metadataFileName)

        guard let data = try? JSONEncoder().encode(cacheMetadata) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Image Decoding

    nonisolated private func decodedImage(_ image: UIImage) -> UIImage {
        if #available(tvOS 15.0, iOS 15.0, *) {
            return image.preparingForDisplay() ?? image
        }
        return image
    }

    /// Decode original bytes to a display-sized bitmap, off the actor (and off the main thread).
    private func decodeDownsampled(data: Data, maxPixelSize: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { [self] in
            self.downsampledImage(from: data, maxPixelSize: maxPixelSize)
        }.value
    }

    /// Load the stored original bytes from disk and decode at `maxPixelSize`.
    /// Runs outside actor isolation for parallel decode.
    nonisolated private func loadFromDiskSync(cacheDir: URL, key: String, maxPixelSize: CGFloat) -> UIImage? {
        let fileURL = cacheDir.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        // Validate image data is complete using CGImageSource
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(imageSource) == .statusComplete,
              CGImageSourceGetCount(imageSource) > 0 else {
            // Data is corrupt or incomplete - delete the cached file
            try? FileManager.default.removeItem(at: fileURL)
            print("💾 ImageCacheManager: Deleted corrupt cached image: \(key)")
            return nil
        }

        // Decode directly at the target size without allocating a full-resolution buffer.
        if let downsampled = downsampledImage(from: data, maxPixelSize: maxPixelSize) {
            return downsampled
        }

        // Fallback to standard decoding if downsampling fails
        guard let image = UIImage(data: data) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return decodedImage(image)
    }

    // MARK: - GPU-Efficient Downsampling

    /// Downsample image data to `maxPixelSize` (longest edge, in pixels) using CGImageSource.
    /// Decodes directly at the target size without allocating a full-resolution buffer, and
    /// will not upscale beyond the source's native resolution.
    nonisolated private func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,  // Decode now (in background)
            kCGImageSourceCreateThumbnailWithTransform: true,  // Apply EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: downsampledImage)
    }
}

// MARK: - URLSessionDelegate (SSL Certificate Handling)

extension ImageCacheManager: URLSessionDelegate {
    /// The Plex server certificate rule (see `PlexCertificateDelegate.trustsServer`).
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        PlexCertificateDelegate.answer(challenge, completionHandler: completionHandler)
    }
}
