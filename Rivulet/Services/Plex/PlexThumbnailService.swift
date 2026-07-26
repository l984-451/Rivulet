// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexThumbnailService.swift
//  Rivulet
//
//  Service for fetching video thumbnails from Plex BIF (Base Index Frames) files
//

import Foundation
import UIKit

/// Service for fetching video preview thumbnails from Plex
@MainActor
final class PlexThumbnailService {
    static let shared = PlexThumbnailService()

    // Cache of loaded BIF data keyed by part ID
    private var bifCache: [Int: BIFData] = [:]
    private var loadingTasks: [Int: Task<BIFData?, Never>] = [:]
    private var unavailableParts: Set<Int> = []  // Parts that returned 404

    private init() {}

    /// Get thumbnail for a specific time in the video
    func getThumbnail(partId: Int, time: TimeInterval, serverURL: String, authToken: String) async -> UIImage? {
        // Skip if we already know this part has no BIF
        if unavailableParts.contains(partId) {
            return nil
        }

        // Try to get from cache first
        if let bifData = bifCache[partId] {
            return bifData.thumbnail(at: time)
        }

        // Check if already loading
        if let task = loadingTasks[partId] {
            let result = await task.value
            return result?.thumbnail(at: time)
        }

        // Start loading
        let task = Task<BIFData?, Never> {
            await loadBIF(partId: partId, serverURL: serverURL, authToken: authToken)
        }
        loadingTasks[partId] = task

        let result = await task.value

        // `clearCache` may have released this part while the load was in
        // flight; it drops the entry from `loadingTasks` to say so. Still hand
        // back the frame we already have, but don't re-populate the cache
        // nobody is left holding.
        guard loadingTasks[partId] == task else {
            return result?.thumbnail(at: time)
        }
        loadingTasks[partId] = nil

        if let data = result {
            bifCache[partId] = data
            return data.thumbnail(at: time)
        } else {
            // Mark as unavailable so we don't keep trying
            unavailableParts.insert(partId)
        }

        return nil
    }

    /// Resolves one BIF frame index per requested time, aligned 1:1 with
    /// `times`.
    ///
    /// `times` may be evenly-spaced samples across the FULL media duration,
    /// but Plex's BIF index can cover a shorter real-time span than the
    /// media itself (generation truncated, or produced against a stale
    /// duration). Naively passing every time through `BIFData.frameIndex(at:)`
    /// doesn't error for times past the BIF's last real frame — it clamps
    /// to `frames.count - 1` — so every tail sample past that point silently
    /// collapses onto the SAME final frame, which would read as several
    /// identical thumbnails for a long tail (e.g. a chapterless episode
    /// whose BIF stops well short of the runtime).
    ///
    /// Times inside BIF coverage resolve normally. Times past coverage are
    /// remapped directly in FRAME-INDEX space (not re-derived as times and
    /// re-rounded — the tail's real-time span can be too narrow relative to
    /// the BIF's own sampling interval for a time-space remap to land on
    /// distinct rounded indices) — spread evenly across whatever indices
    /// remain unused between the last in-range frame and the final frame,
    /// so the tail shows real, distinct frames instead of repeating one.
    nonisolated static func frameIndices(forTimes times: [TimeInterval], bif: BIFData) -> [Int?] {
        guard !bif.frames.isEmpty, !times.isEmpty else { return times.map { _ in nil } }
        let interval = TimeInterval(bif.intervalMs) / 1000.0
        let lastIndex = bif.frames.count - 1
        let coverage = interval > 0 ? TimeInterval(bif.frames[lastIndex].timestamp) * interval : 0

        let inRangeCount = coverage > 0 ? times.filter { $0 <= coverage }.count : times.count
        let overshotCount = times.count - inRangeCount
        guard overshotCount > 0 else { return times.map { bif.frameIndex(at: $0) } }

        // Frame indices strictly after the last in-range sample's own index
        // are "unused" by any in-range request — the tail spreads across
        // those, ending at the true last frame.
        let lastInRangeIndex = inRangeCount > 0 ? (bif.frameIndex(at: times[inRangeCount - 1]) ?? 0) : -1
        let availableStart = min(lastInRangeIndex + 1, lastIndex)
        let availableCount = lastIndex - availableStart + 1

        return times.enumerated().map { position, time in
            guard position >= inRangeCount else { return bif.frameIndex(at: time) }
            let tailPosition = position - inRangeCount
            guard overshotCount > 1, availableCount > 1 else { return lastIndex }
            let fraction = Double(tailPosition) / Double(overshotCount - 1)
            let offset = Int((Double(availableCount - 1) * fraction).rounded())
            return min(availableStart + offset, lastIndex)
        }
    }

    /// Preload BIF data for a part
    func preloadBIF(partId: Int, serverURL: String, authToken: String) {
        guard bifCache[partId] == nil,
              loadingTasks[partId] == nil,
              !unavailableParts.contains(partId) else { return }

        let task = Task<BIFData?, Never> {
            await loadBIF(partId: partId, serverURL: serverURL, authToken: authToken)
        }
        loadingTasks[partId] = task

        Task {
            let result = await task.value
            // The caller may have released this part before the download
            // finished (short watch, or a skip to the next episode). Writing
            // the result now would re-fill the cache with nobody left to
            // release it, so treat a dropped `loadingTasks` entry as a release.
            guard loadingTasks[partId] == task else { return }
            if let result {
                bifCache[partId] = result
            } else {
                unavailableParts.insert(partId)
            }
            loadingTasks[partId] = nil
        }
    }

    private func loadBIF(partId: Int, serverURL: String, authToken: String) async -> BIFData? {
        // print("🖼️ Loading BIF for part \(partId) from \(serverURL)")

        // Try SD first (smaller, faster to load), fall back to HD
        for quality in ["sd", "hd"] {
            let urlString = "\(serverURL)/library/parts/\(partId)/indexes/\(quality)"
            // print("🖼️ Trying BIF URL: \(urlString)")

            guard var urlComponents = URLComponents(string: urlString) else {
                print("⚠️ Failed to create URL components")
                continue
            }
            urlComponents.queryItems = [
                URLQueryItem(name: "X-Plex-Token", value: authToken)
            ]

            guard let url = urlComponents.url else {
                print("⚠️ Failed to create URL from components")
                continue
            }

            do {
                // Use custom URLSession that accepts self-signed certs
                let session = createTrustingSession()
                var request = URLRequest(url: url)
                request.setValue(authToken, forHTTPHeaderField: "X-Plex-Token")

                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    print("⚠️ Not an HTTP response")
                    continue
                }

                // print("🖼️ BIF response status: \(httpResponse.statusCode), size: \(data.count) bytes")

                guard httpResponse.statusCode == 200 else {
                    print("⚠️ BIF request failed with status \(httpResponse.statusCode)")
                    continue
                }

                if let bifData = BIFData(data: data) {
                    // print("✅ Loaded BIF thumbnails (\(quality)): \(bifData.frameCount) frames, interval: \(bifData.intervalMs)ms")
                    // Debug: Check first 5 frames and a few later ones
                    for i in [0, 1, 2, 3, 4, 10, 50, 100] {
                        if i < bifData.frames.count {
                            let frame = bifData.frames[i]
                            // print("🖼️ Frame[\(i)]: timestamp=\(frame.timestamp)ms, size=\(frame.imageData.count) bytes")
                        }
                    }
                    return bifData
                } else {
                    print("⚠️ Failed to parse BIF data (size: \(data.count) bytes)")
                    // Log first few bytes to debug
                    let prefix = data.prefix(16)
                }
            } catch {
                print("⚠️ Failed to load BIF (\(quality)): \(error.localizedDescription)")
                continue
            }
        }

        // print("❌ No BIF thumbnails available for part \(partId)")
        return nil
    }

    /// Creates a URLSession that trusts self-signed certificates
    private func createTrustingSession() -> URLSession {
        let config = URLSessionConfiguration.default
        let delegate = TrustingSessionDelegate()
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Release the frames held for a part. Also drops any in-flight load, so a
    /// download that finishes after this call doesn't re-fill the cache.
    ///
    /// Deliberately keeps `unavailableParts`: a part with no BIF on the server
    /// still has none after a release, and re-arming it would re-issue both the
    /// sd and hd requests every time the item is replayed.
    func clearCache(partId: Int) {
        loadingTasks[partId]?.cancel()
        loadingTasks[partId] = nil
        bifCache[partId] = nil
    }

    /// Clear all cached data
    func clearAllCache() {
        bifCache.removeAll()
        unavailableParts.removeAll()
    }
}

// MARK: - SSL Trust Delegate

private class TrustingSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - BIF Data Structure

/// Parsed BIF (Base Index Frames) file data
nonisolated struct BIFData: Sendable {
    let intervalMs: UInt32
    let frames: [BIFFrame]

    /// `false` if the parser dropped one or more malformed frame entries
    /// (see the extract loop in `init?(data:)`), meaning `frames[i]` is no
    /// longer guaranteed to carry timestamp multiplier `i`. `frameIndex(at:)`
    /// falls back to a binary search on real timestamp when this is false.
    let timestampsAreContiguous: Bool

    var frameCount: Int { frames.count }

    struct BIFFrame: Sendable {
        let timestamp: UInt32  // Milliseconds
        let imageData: Data
    }

    init?(data: Data) {
        // BIF format:
        // Bytes 0-7: Magic number (0x89 "BIF" 0x0D 0x0A 0x1A 0x0A)
        // Bytes 8-11: Version (little-endian UInt32)
        // Bytes 12-15: Frame count (little-endian UInt32)
        // Bytes 16-19: Interval in ms (little-endian UInt32, typically 10000 for 10s)
        // Bytes 20-63: Reserved
        // Bytes 64+: Frame index table (8 bytes per frame: 4 bytes timestamp, 4 bytes offset)
        // After index table: Frame data (JPEG images)

        guard data.count >= 64 else { return nil }

        // Check magic number
        let magic = data.prefix(8)
        let expectedMagic = Data([0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A])
        guard magic == expectedMagic else { return nil }

        // Read header
        let frameCount = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(fromByteOffset: 12, as: UInt32.self).littleEndian
        }

        var interval = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(fromByteOffset: 16, as: UInt32.self).littleEndian
        }

        // BIF spec: timestamp multiplier of 0 means use default of 1000ms
        if interval == 0 {
            interval = 1000
        }

        self.intervalMs = interval

        // Read frame index
        let indexStart = 64
        let indexEnd = indexStart + Int(frameCount + 1) * 8  // +1 for end marker

        guard data.count >= indexEnd else { return nil }

        var frameInfos: [(timestamp: UInt32, offset: UInt32)] = []
        for i in 0..<Int(frameCount) {
            let entryOffset = indexStart + i * 8
            let timestamp = data.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(fromByteOffset: entryOffset, as: UInt32.self).littleEndian
            }
            let offset = data.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(fromByteOffset: entryOffset + 4, as: UInt32.self).littleEndian
            }
            frameInfos.append((timestamp, offset))
        }

        // Read end marker for last frame size
        let endOffset = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(fromByteOffset: indexStart + Int(frameCount) * 8 + 4, as: UInt32.self).littleEndian
        }

        // Extract frame data
        var frames: [BIFFrame] = []
        var anyFrameDropped = false
        for i in 0..<frameInfos.count {
            let info = frameInfos[i]
            let nextOffset = (i + 1 < frameInfos.count) ? frameInfos[i + 1].offset : endOffset

            let start = Int(info.offset)
            let end = Int(nextOffset)

            guard start < data.count, end <= data.count, start < end else {
                anyFrameDropped = true
                continue
            }

            let frameData = data.subdata(in: start..<end)
            frames.append(BIFFrame(timestamp: info.timestamp, imageData: frameData))
        }

        self.frames = frames
        self.timestampsAreContiguous = !anyFrameDropped
    }

    /// Nearest frame index for a playback time.
    ///
    /// Fast path (O(1)): valid ONLY when timestamps are dense frame numbers
    /// (`frames[i].timestamp == i`, so `frames.last.timestamp == count - 1`).
    /// Then the index is `time / interval` directly.
    ///
    /// Fallback path (O(log n)): Plex also ships BIFs whose timestamps are
    /// STRIDED — e.g. `0, 2, 4, … , 1416` for 709 frames (each frame's real
    /// time is `timestamp * interval`, spaced ~2s even though intervalMs=1000).
    /// There `time / interval` runs out of frames at ~half the runtime and
    /// clamps every later scrub onto the final (credits) frame. The same
    /// happens when the parser drops a malformed frame and array position
    /// desyncs from timestamp. In both cases binary-search `frames` (which
    /// stays timestamp-sorted by construction) by real time so each thumbnail
    /// re-times to its true position and the whole timeline is covered.
    func frameIndex(at time: TimeInterval) -> Int? {
        guard !frames.isEmpty else { return nil }
        let interval = TimeInterval(intervalMs) / 1000.0
        guard interval > 0 else { return 0 }

        // Dense only when the last timestamp equals the last array index.
        let timestampsAreDense = Int(frames[frames.count - 1].timestamp) == frames.count - 1
        if timestampsAreContiguous && timestampsAreDense {
            let idx = Int((time / interval).rounded())
            return min(max(idx, 0), frames.count - 1)
        }

        return nearestFrameIndexByBinarySearch(realTime: time, interval: interval)
    }

    /// Binary search over `frames` (timestamp-sorted) for the entry whose
    /// real time (`timestamp * interval`) is nearest to `realTime`.
    private func nearestFrameIndexByBinarySearch(realTime: TimeInterval, interval: TimeInterval) -> Int {
        var low = 0
        var high = frames.count - 1
        while low < high {
            let mid = (low + high) / 2
            let midTime = TimeInterval(frames[mid].timestamp) * interval
            if midTime < realTime {
                low = mid + 1
            } else {
                high = mid
            }
        }
        // `low` is the first frame whose real time is >= realTime (or the
        // last frame if none qualify). Compare against its predecessor to
        // find the true nearest neighbor.
        if low > 0 {
            let lowTime = TimeInterval(frames[low].timestamp) * interval
            let prevTime = TimeInterval(frames[low - 1].timestamp) * interval
            if abs(prevTime - realTime) <= abs(lowTime - realTime) {
                return low - 1
            }
        }
        return low
    }

    /// Get thumbnail for a specific time
    func thumbnail(at time: TimeInterval) -> UIImage? {
        guard let index = frameIndex(at: time) else { return nil }
        return UIImage(data: frames[index].imageData)
    }
}
