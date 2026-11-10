// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// JSON file caching for offline access to Plex metadata.

import Foundation

actor CacheManager {
    static let shared = CacheManager()

    // MARK: - Cache File Names

    private let librariesCacheFile = "libraries_cache.json"
    private let moviesCachePrefix = "movies_"
    private let showsCachePrefix = "shows_"
    private let seasonsCachePrefix = "seasons_"
    private let episodesCachePrefix = "episodes_"
    private let onDeckCacheFile = "ondeck_cache.json"
    private let recentlyAddedPrefix = "recently_added_"
    private let hubsCacheFile = "hubs_cache.json"
    /// Older builds kept a timestamp file nothing read. Still listed so a clear removes it.
    private let cacheInfoFile = "cache_info.json"
    /// UserDefaults: the Home user whose token wrote these files (0 is the account).
    private let cacheOwnerKey = "plexCacheUserID"

    // MARK: - Cache Configuration

    // MARK: - In-Memory Cache

    private let memoryCache = NSCache<NSString, NSData>()

    // MARK: - Cache Directory

    private let cacheDirectory: URL?
    private let defaults: UserDefaults

    // MARK: - Initialization

    /// The arguments exist for tests; the app only uses `shared`.
    init(directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PlexCache"),
         defaults: UserDefaults = .standard) {
        cacheDirectory = directory
        self.defaults = defaults
        memoryCache.countLimit = 64 // Larger limit for tvOS
        Task {
            await createCacheDirectoryIfNeeded()
        }
    }

    private func createCacheDirectoryIfNeeded() {
        guard let cacheDir = cacheDirectory else { return }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Generic Cache Operations

    /// Drops every file written with another Home profile's token, so one
    /// profile's rows are never painted for the next.
    private func purgeIfOwnerChanged() {
        let owner = defaults.integer(forKey: PlexProfileSession.contentUserIDKey)
        guard owner != defaults.integer(forKey: cacheOwnerKey) else { return }
        clearAllCache()
        defaults.set(owner, forKey: cacheOwnerKey)
    }

    private func cacheData<T: Encodable>(_ value: T, fileName: String) {
        purgeIfOwnerChanged()
        guard let cacheDir = cacheDirectory,
              let data = try? JSONEncoder().encode(value) else { return }
        let fileURL = cacheDir.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL, options: .atomic)
            memoryCache.setObject(data as NSData, forKey: fileName as NSString)
        } catch {
            print("CacheManager: Failed to write cache file \(fileName): \(error.localizedDescription)")
        }
    }

    private func decodedCache<T: Decodable>(for fileName: String, as type: T.Type) -> T? {
        purgeIfOwnerChanged()
        // Check memory cache first
        if let rawData = memoryCache.object(forKey: fileName as NSString) {
            let data = rawData as Data
            if let decoded = try? JSONDecoder().decode(T.self, from: data) {
                return decoded
            }
            memoryCache.removeObject(forKey: fileName as NSString)
        }

        // Check disk cache
        guard let cacheDir = cacheDirectory else { return nil }
        let fileURL = cacheDir.appendingPathComponent(fileName)
        let readStart = ProcessInfo.processInfo.systemUptime
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let readMs = Int((ProcessInfo.processInfo.systemUptime - readStart) * 1000)
        memoryCache.setObject(data as NSData, forKey: fileName as NSString)
        // Wall and cpu both: at launch wall time counts descheduling and page faults
        // (1033 ms wall for a 0.4 ms decode). If cpu << wall, the payload is not the problem.
        let decodeStart = ProcessInfo.processInfo.systemUptime
        let cpuStart = Self.threadCPUSeconds()
        let decoded = try? JSONDecoder().decode(T.self, from: data)
        let decodeMs = Int((ProcessInfo.processInfo.systemUptime - decodeStart) * 1000)
        let cpuMs = Int((Self.threadCPUSeconds() - cpuStart) * 1000)
        if readMs > 200 || decodeMs > 200 {
            StartupTimer.mark("  decodedCache(\(fileName)) read=\(readMs)ms decode=\(decodeMs)ms cpu=\(cpuMs)ms bytes=\(data.count)")
        }
        return decoded
    }

    /// CPU time consumed by the CALLING thread, in seconds. Pairs with a wall
    /// clock to separate "this work is expensive" from "this thread was waiting".
    private static func threadCPUSeconds() -> Double {
        var ts = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) == 0 else { return 0 }
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }

    // MARK: - Library Cache

    func cacheLibraries(_ libraries: [PlexLibrary]) {
        cacheData(libraries, fileName: librariesCacheFile)
    }

    func getCachedLibraries() -> [PlexLibrary]? {
        return decodedCache(for: librariesCacheFile, as: [PlexLibrary].self)
    }

    // MARK: - Movies Cache

    func cacheMovies(_ movies: [PlexMetadata], forLibrary libraryKey: String) {
        let fileName = "\(moviesCachePrefix)\(libraryKey).json"
        cacheData(movies, fileName: fileName)
    }

    func getCachedMovies(forLibrary libraryKey: String) -> [PlexMetadata]? {
        let fileName = "\(moviesCachePrefix)\(libraryKey).json"
        let result = decodedCache(for: fileName, as: [PlexMetadata].self)
        return result
    }

    // MARK: - TV Shows Cache

    func cacheShows(_ shows: [PlexMetadata], forLibrary libraryKey: String) {
        let fileName = "\(showsCachePrefix)\(libraryKey).json"
        cacheData(shows, fileName: fileName)
    }

    func getCachedShows(forLibrary libraryKey: String) -> [PlexMetadata]? {
        let fileName = "\(showsCachePrefix)\(libraryKey).json"
        let result = decodedCache(for: fileName, as: [PlexMetadata].self)
        return result
    }

    // MARK: - Seasons Cache

    func cacheSeasons(_ seasons: [PlexMetadata], forShow showKey: String) {
        let fileName = "\(seasonsCachePrefix)\(showKey).json"
        cacheData(seasons, fileName: fileName)
    }

    func getCachedSeasons(forShow showKey: String) -> [PlexMetadata]? {
        let fileName = "\(seasonsCachePrefix)\(showKey).json"
        return decodedCache(for: fileName, as: [PlexMetadata].self)
    }

    // MARK: - Episodes Cache

    func cacheEpisodes(_ episodes: [PlexMetadata], forSeason seasonKey: String) {
        let fileName = "\(episodesCachePrefix)\(seasonKey).json"
        cacheData(episodes, fileName: fileName)
    }

    func getCachedEpisodes(forSeason seasonKey: String) -> [PlexMetadata]? {
        let fileName = "\(episodesCachePrefix)\(seasonKey).json"
        return decodedCache(for: fileName, as: [PlexMetadata].self)
    }

    // MARK: - On Deck Cache

    func cacheOnDeck(_ items: [PlexMetadata]) {
        cacheData(items, fileName: onDeckCacheFile)
    }

    func getCachedOnDeck() -> [PlexMetadata]? {
        return decodedCache(for: onDeckCacheFile, as: [PlexMetadata].self)
    }

    // MARK: - Recently Added Cache

    func cacheRecentlyAdded(_ items: [PlexMetadata], forLibrary libraryKey: String) {
        let fileName = "\(recentlyAddedPrefix)\(libraryKey).json"
        cacheData(items, fileName: fileName)
    }

    func getCachedRecentlyAdded(forLibrary libraryKey: String) -> [PlexMetadata]? {
        let fileName = "\(recentlyAddedPrefix)\(libraryKey).json"
        return decodedCache(for: fileName, as: [PlexMetadata].self)
    }

    // MARK: - Hubs Cache (for home screen)

    func cacheHubs(_ hubs: [PlexHub]) {
        cacheData(hubs, fileName: hubsCacheFile)
    }

    func getCachedHubs() -> [PlexHub]? {
        return decodedCache(for: hubsCacheFile, as: [PlexHub].self)
    }

    // MARK: - Library Hubs Cache (for individual library screens)

    // Bump `_vN` when `PlexHub` gains a field Home reads: older files decode it as nil
    // (v2: `promoted`, which gates each pinned library's Home row).
    private let libraryHubsCacheBase = "library_hubs_"
    private let libraryHubsCachePrefix = "library_hubs_v2_"

    func cacheLibraryHubs(_ hubs: [PlexHub], forLibrary libraryKey: String) {
        let fileName = "\(libraryHubsCachePrefix)\(libraryKey).json"
        cacheData(hubs, fileName: fileName)
    }

    func getCachedLibraryHubs(forLibrary libraryKey: String) -> [PlexHub]? {
        let fileName = "\(libraryHubsCachePrefix)\(libraryKey).json"
        return decodedCache(for: fileName, as: [PlexHub].self)
    }

    // MARK: - Home Items Cache (MediaItem projection)

    // Bump `_vN` when the `MediaItem` schema or the `providerID` baked into each
    // `MediaItemRef` changes, or an old build's rows show stale or blank.
    private let homeItemsCacheFile = "home_items_cache_v3.json"
    private let homeHeroItemsCacheFile = "home_hero_items_cache_v1.json"
    private let libraryItemsCachePrefix = "library_items_v3_"

    func cacheHomeItems(_ rail: CachedHomeRail) {
        cacheData(rail, fileName: homeItemsCacheFile)
    }

    func getCachedHomeItems() -> CachedHomeRail? {
        return decodedCache(for: homeItemsCacheFile, as: CachedHomeRail.self)
    }

    func cacheHomeHeroItems(_ items: [PlexMetadata]) {
        cacheData(items, fileName: homeHeroItemsCacheFile)
    }

    func getCachedHomeHeroItems() -> [PlexMetadata]? {
        return decodedCache(for: homeHeroItemsCacheFile, as: [PlexMetadata].self)
    }

    func cacheLibraryItems(_ rail: CachedHomeRail, forLibrary key: String) {
        let fileName = "\(libraryItemsCachePrefix)\(key).json"
        cacheData(rail, fileName: fileName)
    }

    func getCachedLibraryItems(forLibrary key: String) -> CachedHomeRail? {
        let fileName = "\(libraryItemsCachePrefix)\(key).json"
        return decodedCache(for: fileName, as: CachedHomeRail.self)
    }

    // MARK: - Clear Cache

    func clearAllCache() {
        guard let cacheDir = cacheDirectory else { return }

        let ourPrefixes = [
            moviesCachePrefix,
            showsCachePrefix,
            seasonsCachePrefix,
            episodesCachePrefix,
            recentlyAddedPrefix,
            libraryHubsCachePrefix,
            libraryItemsCachePrefix
        ]

        let ourFiles = [
            librariesCacheFile,
            onDeckCacheFile,
            hubsCacheFile,
            homeItemsCacheFile,
            homeHeroItemsCacheFile,
            cacheInfoFile
        ]

        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for file in files {
                let fileName = file.lastPathComponent

                // Skip system database files
                if fileName.hasPrefix("Cache.db") {
                    continue
                }

                // Delete files matching our cache patterns
                let shouldDelete = ourFiles.contains(fileName) ||
                                 ourPrefixes.contains { fileName.hasPrefix($0) }

                if shouldDelete {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }

        memoryCache.removeAllObjects()
    }

    func clearLibraryCache() {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(librariesCacheFile)
        try? FileManager.default.removeItem(at: fileURL)
        memoryCache.removeObject(forKey: librariesCacheFile as NSString)
    }

    func clearOnDeckCache() {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(onDeckCacheFile)
        try? FileManager.default.removeItem(at: fileURL)
        memoryCache.removeObject(forKey: onDeckCacheFile as NSString)
    }

    func clearHubsCache() {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(hubsCacheFile)
        try? FileManager.default.removeItem(at: fileURL)
        memoryCache.removeObject(forKey: hubsCacheFile as NSString)
    }

    func clearLibraryHubsCache() {
        guard let cacheDir = cacheDirectory else { return }
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for file in files {
                let fileName = file.lastPathComponent
                // Base prefix, not the versioned one, so a force-refresh also
                // sweeps the files older versions left behind.
                if fileName.hasPrefix(libraryHubsCacheBase) {
                    try? FileManager.default.removeItem(at: file)
                    memoryCache.removeObject(forKey: fileName as NSString)
                }
            }
        }
    }

    func clearHomeItemsCache() {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(homeItemsCacheFile)
        try? FileManager.default.removeItem(at: fileURL)
        memoryCache.removeObject(forKey: homeItemsCacheFile as NSString)
    }

    func clearHomeHeroItemsCache() {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(homeHeroItemsCacheFile)
        try? FileManager.default.removeItem(at: fileURL)
        memoryCache.removeObject(forKey: homeHeroItemsCacheFile as NSString)
    }

    func clearLibraryItemsCache() {
        guard let cacheDir = cacheDirectory else { return }
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for file in files {
                let fileName = file.lastPathComponent
                if fileName.hasPrefix(libraryItemsCachePrefix) {
                    try? FileManager.default.removeItem(at: file)
                    memoryCache.removeObject(forKey: fileName as NSString)
                }
            }
        }
    }

    func clearMoviesCache(forLibrary libraryKey: String) {
        guard let cacheDir = cacheDirectory else { return }
        let fileName = "\(moviesCachePrefix)\(libraryKey).json"
        let fileURL = cacheDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
        memoryCache.removeObject(forKey: fileName as NSString)
    }

    func clearShowsCache(forLibrary libraryKey: String) {
        guard let cacheDir = cacheDirectory else { return }
        let fileName = "\(showsCachePrefix)\(libraryKey).json"
        let fileURL = cacheDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
        memoryCache.removeObject(forKey: fileName as NSString)
    }

    // MARK: - Cache Size

    func getCacheSize() -> Int64 {
        guard let cacheDir = cacheDirectory else { return 0 }
        var totalSize: Int64 = 0

        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in files {
                if let fileSize = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        }

        return totalSize
    }

    func getFormattedCacheSize() -> String {
        let bytes = getCacheSize()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
