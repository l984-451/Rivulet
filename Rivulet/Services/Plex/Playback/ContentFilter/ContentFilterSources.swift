// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContentFilterSources.swift
//  Rivulet
//
//  Where the content filter's data comes from, apart from the subtitles on
//  screen:
//
//    1. An imported MCF/EDL list, fetched per title from the user's list
//       source and cached on disk.
//    2. The title's own external subtitle file, read in full, so language
//       muting works with subtitles turned off and on the hls route (which has
//       no app-side cue source at all).
//
//  Pure and nonisolated. ContentFilterManager decides when these run.
//

import Foundation

/// A stretch of a title's subtitle file whose dialogue contains filterable
/// language. Whether it mutes is decided at playback time against the user's
/// settings, so a settings change never needs the file read again.
nonisolated struct LanguageWindow: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let hits: LanguageHits

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

nonisolated enum ContentFilterSources {

    // MARK: - Imported lists

    nonisolated enum ListOutcome: Sendable {
        /// A usable list.
        case found(ContentFilterList)
        /// The source answered and has nothing usable for this title: no file,
        /// an empty one, or a list timed to another release.
        case absent
        /// The source couldn't be reached. Whatever the cache holds stands.
        case unreachable
    }

    /// The ordered URLs to try for a title, from the user's list source.
    ///
    /// - A template with placeholders gets them filled: `{id}` (Plex rating
    ///   key), `{imdb}`, `{tmdb}`, `{tvdb}`, and `{file}` (media file name
    ///   without extension). A placeholder the title has no value for yields
    ///   no URL at all, rather than a request for the wrong file.
    /// - A template that points straight at a `.mcf`/`.edl` file is used verbatim.
    /// - Anything else is a folder, searched by file name, then IMDb id, then
    ///   rating key, each as `.mcf` then `.edl`. File name first, because that
    ///   is how cleanvid and Kodi name a sidecar EDL; rating key last, because
    ///   it belongs to one server and changes when a library is rebuilt.
    static func listURLs(template rawTemplate: String, item: ContentFilterItem) -> [URL] {
        let template = rawTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { return [] }

        let values: [(placeholder: String, value: String?)] = [
            ("{id}", item.ratingKey),
            ("{imdb}", item.imdbID),
            ("{tmdb}", item.tmdbID),
            ("{tvdb}", item.tvdbID),
            ("{file}", item.fileName)
        ]
        var filled = template
        var usesPlaceholders = false
        for (placeholder, value) in values where template.contains(placeholder) {
            usesPlaceholders = true
            guard let encoded = value.flatMap(encode) else { return [] }
            filled = filled.replacingOccurrences(of: placeholder, with: encoded)
        }
        if usesPlaceholders {
            return URL(string: filled).map { [$0] } ?? []
        }

        let lower = template.lowercased()
        if lower.hasSuffix(".mcf") || lower.hasSuffix(".edl") {
            return URL(string: template).map { [$0] } ?? []
        }

        let base = template.hasSuffix("/") ? template : template + "/"
        var seen = Set<String>()
        return [item.fileName, item.imdbID, item.ratingKey]
            .compactMap { $0.flatMap(encode) }
            .flatMap { name in ["\(base)\(name).mcf", "\(base)\(name).edl"] }
            .filter { seen.insert($0).inserted }
            .compactMap { URL(string: $0) }
    }

    /// Percent-encode a value so it is safe anywhere in a URL, path or query.
    private static func encode(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.addingPercentEncoding(withAllowedCharacters: unreservedCharacters)
    }

    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Try each candidate in order until one holds a usable list.
    static func fetchList(from candidates: [URL], mediaDuration: TimeInterval?) async -> ListOutcome {
        for url in candidates {
            if Task.isCancelled { return .unreachable }
            switch await fetchText(url) {
            case .body(let content):
                // A file that exists but holds nothing usable (empty,
                // unparseable, or timed to another release) is as good as
                // absent: fall through to the next candidate.
                if let list = try? ContentFilterParser.parse(content: content, url: url,
                                                            mediaDuration: mediaDuration),
                   !list.isEmpty {
                    return .found(list)
                }
            case .missing:
                continue
            case .failed:
                return .unreachable
            }
        }
        return .absent
    }

    // MARK: - List cache

    /// Cache identity for a title's list: the URLs it would be fetched from.
    /// Keying on the source rather than the rating key means changing or
    /// clearing the source can never resurrect an old list, and one rating key
    /// on two servers can never share another title's list.
    static func cacheKey(for candidates: [URL]) -> String {
        candidates.map(\.absoluteString).joined(separator: "\n").sha256Hash()
    }

    static func loadCachedList(key: String) -> ContentFilterList? {
        guard let url = cacheURL(key: key),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ContentFilterList.self, from: data)
    }

    static func cacheList(_ list: ContentFilterList, key: String) {
        guard let url = cacheURL(key: key),
              let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func removeCachedList(key: String) {
        guard let url = cacheURL(key: key) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func cacheURL(key: String) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = support.appendingPathComponent("ContentFilters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(key).json")
    }

    // MARK: - Subtitle file

    /// Codecs of text subtitles the filter can read in full.
    static let readableTranscriptCodecs: Set<String> = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt"]

    /// The external subtitle file to read for language muting: a text sidecar
    /// in English (the dictionary's language) that isn't forced-only,
    /// preferring the one Plex has selected, then plain over SDH. Embedded
    /// tracks have no `key` and can't be fetched on their own; those titles
    /// rely on the subtitles on screen.
    static func transcriptStream(in streams: [PlexStream]) -> PlexStream? {
        streams
            .filter { stream in
                stream.isSubtitle
                    && stream.key != nil
                    && !(stream.forced ?? false)
                    && readableTranscriptCodecs.contains((stream.codec ?? "").lowercased())
                    && languageRank(stream) != nil
            }
            .min { transcriptRank($0) < transcriptRank($1) }
    }

    private static func transcriptRank(_ stream: PlexStream) -> Int {
        (languageRank(stream) ?? 2) * 4
            + ((stream.selected ?? false) ? 0 : 2)
            + ((stream.hearingImpaired ?? false) ? 1 : 0)
    }

    /// 0 = English, 1 = unlabeled (worth reading), nil = another language.
    private static func languageRank(_ stream: PlexStream) -> Int? {
        let labels = [stream.languageCode, stream.languageTag, stream.language]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0 != "unknown" && $0 != "und" }
        guard !labels.isEmpty else { return 1 }
        let isEnglish = labels.contains { $0 == "eng" || $0 == "en" || $0.hasPrefix("en-") || $0 == "english" }
        return isEnglish ? 0 : nil
    }

    /// Fetch and scan a title's subtitle file. nil when it can't be read.
    static func loadTranscript(_ source: ContentFilterItem.TranscriptSource) async -> [LanguageWindow]? {
        guard case .body(let content) = await fetchText(source.url) else { return nil }
        // A feature's subtitles run to a thousand-plus cues; parse and scan
        // them off the main actor so playback startup doesn't hitch.
        let format = source.format
        return await Task.detached(priority: .utility) {
            ContentFilterSources.languageWindows(content: content, format: format)
        }.value
    }

    /// Every cue in a subtitle file that contains filterable language.
    static func languageWindows(content: String, format: String) -> [LanguageWindow] {
        guard let track = parseSubtitles(content, format: format) else { return [] }
        return track.cues.compactMap { cue in
            guard cue.endTime > cue.startTime else { return nil }
            let hits = ProfanityDictionary.hits(in: cue.text)
            return hits.isEmpty ? nil : LanguageWindow(start: cue.startTime, end: cue.endTime, hits: hits)
        }
    }

    private static func parseSubtitles(_ content: String, format: String) -> ParsedSubtitleTrack? {
        switch format.lowercased() {
        case "srt", "subrip": return try? SRTParser().parse(content)
        case "ass", "ssa": return try? ASSParser().parse(content)
        case "vtt", "webvtt": return try? VTTParser().parse(content)
        default:
            let head = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if head.hasPrefix("WEBVTT") { return try? VTTParser().parse(content) }
            if head.contains("[Events]") { return try? ASSParser().parse(content) }
            return try? SRTParser().parse(content)
        }
    }

    // MARK: - Fetching

    nonisolated enum FetchResult: Sendable {
        case body(String)
        /// The server answered that this file isn't there (any 4xx: static
        /// hosts such as S3 answer 403 for a missing object).
        case missing
        /// No answer, or a server error.
        case failed
    }

    static func fetchText(_ url: URL) async -> FetchResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return .failed }
        if let http = response as? HTTPURLResponse {
            if (400..<500).contains(http.statusCode) { return .missing }
            guard (200..<300).contains(http.statusCode) else { return .failed }
        }
        guard let text = decodeText(data) else { return .missing }
        return .body(text)
    }

    /// Subtitle and filter files in the wild are UTF-8, UTF-16 or Windows-1252,
    /// often with a byte-order mark.
    static func decodeText(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let isUTF16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        let decoded = isUTF16
            ? String(data: data, encoding: .utf16)
            : String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1)
        guard var text = decoded else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }
}
