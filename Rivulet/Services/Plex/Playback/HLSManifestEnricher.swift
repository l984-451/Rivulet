// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HLSManifestEnricher.swift
//  Rivulet
//
//  AVAssetResourceLoaderDelegate that intercepts the HLS master playlist
//  and injects #EXT-X-MEDIA tags for audio/subtitle tracks using Plex metadata.
//
//  Only the master playlist is intercepted. All relative URLs in the patched
//  manifest are rewritten to absolute HTTP URLs so AVPlayer fetches sub-playlists
//  and segments directly from the Plex server (no proxy needed).
//

import AVFoundation

/// Enriches an HLS master playlist with audio/subtitle track metadata from Plex.
final class HLSManifestEnricher: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

    static let customScheme = "rivulet-hls"

    private let metadata: PlexMetadata
    private let headers: [String: String]
    private let originalScheme: String
    /// Base URL for resolving relative paths (e.g., "http://server:32400/video/:/transcode/universal/")
    private let baseURL: String
    /// Auth token appended to absolute URLs so AVPlayer can fetch sub-playlists directly
    private let authToken: String?

    /// Why the resource loader refused or failed a request, if it did.
    ///
    /// A custom-scheme asset has no loader of last resort: if this delegate
    /// returns false or finishes a request with an error, AVFoundation cannot
    /// load `rivulet-hls://` by itself and fails the item with
    /// NSURLErrorUnsupportedURL (-1002). That is RIVULET-55, and it arrived in
    /// Sentry with no indication of which of the two paths produced it, because
    /// neither recorded anything. The player reads this when it retries without
    /// enrichment so the next occurrence names its own cause.
    var lastFailure: String? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return _lastFailure
    }

    private let failureLock = NSLock()
    private var _lastFailure: String?

    private func recordFailure(_ reason: String) {
        failureLock.lock()
        _lastFailure = reason
        failureLock.unlock()
        playerDebugLog("[HLSEnricher] \(reason)")
    }

    init(metadata: PlexMetadata, headers: [String: String], originalURL: URL) {
        self.metadata = metadata
        self.headers = headers
        self.originalScheme = originalURL.scheme ?? "http"

        // Base URL = scheme + host + path (without last component, without query)
        // e.g., "http://server:32400/video/:/transcode/universal/start.m3u8?foo=bar"
        //      → "http://server:32400/video/:/transcode/universal/"
        var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)!
        components.query = nil
        components.fragment = nil
        let cleanURL = components.url!
        var base = cleanURL.deletingLastPathComponent().absoluteString
        if !base.hasSuffix("/") { base += "/" }
        self.baseURL = base
        self.authToken = headers["X-Plex-Token"]

        super.init()
    }

    /// Convert an HLS URL to use the custom scheme so the resource loader intercepts it.
    func enrichedURL(from originalURL: URL) -> URL? {
        guard var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = Self.customScheme
        return components.url
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url else {
            recordFailure("refused: loading request carried no URL")
            return false
        }
        guard url.scheme == Self.customScheme else {
            // Sub-playlists and segments are rewritten to absolute HTTP by
            // `patchMasterPlaylist`, so they never reach here. Anything else
            // that does is a request only AVFoundation could satisfy, and it
            // cannot, so say which scheme asked.
            recordFailure("refused: unexpected scheme \(url.scheme ?? "none")")
            return false
        }

        // Intercept the master playlist, fetch + patch + return
        Task {
            await handleMasterPlaylist(loadingRequest: loadingRequest, url: url)
        }
        return true
    }

    // MARK: - Master Playlist Patching

    private func handleMasterPlaylist(loadingRequest: AVAssetResourceLoadingRequest, url: URL) async {
        let originalURL = restoreOriginalScheme(url)

        var request = URLRequest(url: originalURL)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                recordFailure("master playlist HTTP \(http.statusCode)")
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                return
            }
            guard let manifest = String(data: data, encoding: .utf8) else {
                recordFailure("master playlist was not UTF-8 (\(data.count) bytes)")
                loadingRequest.finishLoading(with: URLError(.cannotDecodeContentData))
                return
            }

            let patched = patchMasterPlaylist(manifest)
            playerDebugLog("[HLSEnricher] Patched master playlist:")
            for line in patched.components(separatedBy: "\n") where !line.isEmpty {
                playerDebugLog("[HLSEnricher]   \(line)")
            }

            let patchedData = patched.data(using: .utf8)!
            loadingRequest.dataRequest?.respond(with: patchedData)
            if let httpResponse = response as? HTTPURLResponse,
               let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                loadingRequest.contentInformationRequest?.contentType = contentType
            }
            loadingRequest.contentInformationRequest?.contentLength = Int64(patchedData.count)
            loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
            loadingRequest.finishLoading()
        } catch {
            recordFailure("master playlist fetch failed: \(error.localizedDescription)")
            loadingRequest.finishLoading(with: error)
        }
    }

    /// Internal for test: `HLSManifestEnricherTests` pins this against a real
    /// PMS 1.43.4 master playlist, because every sub-URL AVPlayer fetches comes
    /// out of here and a silent regression costs the whole session.
    func patchMasterPlaylist(_ manifest: String) -> String {
        var lines = manifest.components(separatedBy: "\n")

        // 1. Inject audio track metadata
        let audioTag = buildAudioTag()
        if let audioTag {
            // Insert after #EXTM3U
            lines.insert(audioTag, at: 1)

            // Add AUDIO group reference to #EXT-X-STREAM-INF
            for i in 0..<lines.count {
                if lines[i].hasPrefix("#EXT-X-STREAM-INF:") && !lines[i].contains("AUDIO=") {
                    lines[i] += ",AUDIO=\"audio\""
                }
            }
        }

        // 2. Rewrite relative URLs to absolute HTTP so AVPlayer fetches them
        //    directly from Plex (bypasses our resource loader for everything after master).
        //    Append auth token since AVPlayer won't have our custom headers for these.
        for i in 0..<lines.count {
            let line = lines[i]
            if line.hasPrefix("#") || line.isEmpty || line.contains("://") { continue }
            lines[i] = makeAbsoluteURL(relativePath: line)
        }

        // 3. Also fix URI attributes in tags (e.g., EXT-X-I-FRAME-STREAM-INF URI="...")
        for i in 0..<lines.count {
            if let range = lines[i].range(of: "URI=\""),
               let endQuote = lines[i][range.upperBound...].firstIndex(of: "\"") {
                let uri = String(lines[i][range.upperBound..<endQuote])
                if !uri.contains("://") {
                    let absoluteURI = makeAbsoluteURL(relativePath: uri)
                    lines[i] = lines[i].replacingOccurrences(of: "URI=\"\(uri)\"", with: "URI=\"\(absoluteURI)\"")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Build the #EXT-X-MEDIA audio tag from Plex metadata.
    /// Uses stream-level info if available, falls back to media-level.
    private func buildAudioTag() -> String? {
        let streams = metadata.Media?.first?.Part?.first?.Stream ?? []
        let audioStream = streams.first { $0.isAudio }

        // Get audio info from stream-level or media-level
        let name: String
        let lang: String
        let channels: Int

        if let stream = audioStream {
            name = stream.displayTitle ?? buildAudioLabel(
                codec: stream.codec,
                channels: stream.channels
            )
            lang = stream.languageTag ?? stream.languageCode ?? "en"
            channels = stream.channels ?? 2
        } else if let media = metadata.Media?.first, let codec = media.audioCodec {
            // Fall back to media-level info (common for hub items without stream details)
            name = buildAudioLabel(codec: codec, channels: media.audioChannels)
            lang = "en"
            channels = media.audioChannels ?? 2
        } else {
            return nil
        }

        var tag = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\""
        tag += ",NAME=\"\(name)\""
        tag += ",LANGUAGE=\"\(lang)\""
        tag += ",CHANNELS=\"\(channels)\""
        tag += ",DEFAULT=YES,AUTOSELECT=YES"
        return tag
    }

    /// Build a human-readable audio label (codec + channels only; language is in the LANGUAGE attribute).
    private func buildAudioLabel(codec: String?, channels: Int?) -> String {
        let codecUpper = codec?.uppercased() ?? ""
        let ch = channels ?? 0

        let codecName: String
        switch codecUpper {
        case "EAC3", "EC-3": codecName = "Dolby Digital+"
        case "AC3": codecName = "Dolby Digital"
        case "AAC": codecName = "AAC"
        case "DTS": codecName = "DTS"
        case "DTS-HD", "DTSHD": codecName = "DTS-HD MA"
        case "TRUEHD", "MLP": codecName = "Dolby TrueHD"
        case "FLAC": codecName = "FLAC"
        default: codecName = codecUpper
        }

        let channelDesc: String
        switch ch {
        case 8: channelDesc = "7.1"
        case 6: channelDesc = "5.1"
        case 2: channelDesc = String(localized: "Stereo")
        case 1: channelDesc = String(localized: "Mono")
        default: channelDesc = ch > 0 ? "\(ch)ch" : ""
        }

        if codecName.isEmpty && channelDesc.isEmpty { return String(localized: "Audio") }
        if codecName.isEmpty { return channelDesc }
        if channelDesc.isEmpty { return codecName }
        return "\(codecName) \(channelDesc)"
    }

    // MARK: - URL Helpers

    /// Make a relative path into an absolute HTTP URL with auth token.
    private func makeAbsoluteURL(relativePath: String) -> String {
        var absolute = baseURL + relativePath
        if let token = authToken {
            let separator = absolute.contains("?") ? "&" : "?"
            absolute += "\(separator)X-Plex-Token=\(token)"
        }
        return absolute
    }

    private func restoreOriginalScheme(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = originalScheme
        return components.url ?? url
    }
}
