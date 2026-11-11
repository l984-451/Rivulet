// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

//
//  SubtitleSearch.swift
//  Rivulet
//
//  Searching a server's subtitle providers (OpenSubtitles) for the playing title and saving a
//  result next to it. The server does both; a downloaded subtitle then shows up as a new
//  external stream on the item.
//

import Foundation

/// One subtitle a server's provider offers. `id` is what the server wants back to download it.
nonisolated struct SubtitleSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let title: String?
    let language: String?
    let format: String?
    let isHearingImpaired: Bool
    let isForced: Bool

    /// "English • SRT • SDH", for a result row.
    var detail: String {
        [language, format?.uppercased(), isHearingImpaired ? "SDH" : nil, isForced ? String(localized: "Forced") : nil]
            .compactMap { $0 }.joined(separator: " • ")
    }

    var displayTitle: String { title ?? String(localized: "Subtitle") }
}

nonisolated enum SubtitleSearchLanguage {
    /// The language to search for as ISO 639-1: the subtitle preference's, else the device's.
    static func alpha2(preferred: String?, device: String) -> String {
        let fallback = Locale.LanguageCode(device).identifier(.alpha2) ?? "en"
        let code = TrackLanguage.normalize(preferred)
        return code.isEmpty ? fallback : Locale.LanguageCode(code).identifier(.alpha2) ?? fallback
    }

    /// ISO 639-2/T for Jellyfin and Emby, whose providers map three-letter codes (Plex wants two).
    static func alpha3(_ alpha2: String) -> String {
        Locale.LanguageCode(alpha2).identifier(.alpha3) ?? alpha2
    }
}

/// One title's subtitle search, whichever server holds it.
nonisolated protocol SubtitleSearching: Sendable {
    /// False hides the menu row: no permission, or no way to search.
    func isAvailable() async -> Bool
    /// `language` is ISO 639-1.
    func search(language: String) async throws -> [SubtitleSearchResult]
    func download(_ result: SubtitleSearchResult) async throws
}

nonisolated struct PlexSubtitleSearch: SubtitleSearching {
    let serverURL: String
    let token: String
    let ratingKey: String
    var network: PlexNetworkManager = .shared

    /// PMS lets any non-restricted user search and download, not just the admin (measured).
    func isAvailable() async -> Bool {
        await MainActor.run { PlexUserProfileManager.shared.selectedUser?.restricted != true }
    }

    func search(language: String) async throws -> [SubtitleSearchResult] {
        try await network.searchSubtitles(serverURL: serverURL, authToken: token, ratingKey: ratingKey, language: language)
            .map(Self.result)
    }

    func download(_ result: SubtitleSearchResult) async throws {
        try await network.downloadSubtitle(serverURL: serverURL, authToken: token, ratingKey: ratingKey, resultKey: result.id)
    }

    static func result(_ stream: PlexStream) -> SubtitleSearchResult {
        SubtitleSearchResult(id: stream.key ?? "", title: stream.title ?? stream.displayTitle, language: stream.language,
                             format: stream.codec, isHearingImpaired: stream.hearingImpaired == true,
                             isForced: stream.forced == true)
    }

    /// The part's metadata once the server lists a subtitle `known` doesn't have. PMS adds the
    /// sidecar about two seconds after the download answers, under a new stream id.
    func metadataWithNewSubtitle(known: Set<Int>, mediaID: Int?) async throws -> (metadata: PlexMetadata, trackID: Int)? {
        for _ in 0..<SubtitleArrival.attempts {
            try await Task.sleep(for: SubtitleArrival.interval)
            let fresh = try await network.getMetadata(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
            let media = (fresh.Media ?? []).first { mediaID != nil && $0.id == mediaID } ?? fresh.Media?.first
            if let added = media?.Part?.first?.Stream?.first(where: { $0.isSubtitle && $0.key != nil && !known.contains($0.id) }) {
                var metadata = fresh
                metadata.Media = media.map { [$0] }
                return (metadata, added.id)
            }
        }
        return nil
    }
}

nonisolated enum SubtitleArrival {
    static let attempts = 10
    static let interval = Duration.milliseconds(1500)
}

/// A Jellyfin or Emby item, through the provider seam.
nonisolated struct ProviderSubtitleSearch: SubtitleSearching {
    let provider: any MediaProvider
    let ref: MediaItemRef

    func isAvailable() async -> Bool { await provider.canSearchSubtitles() }

    func search(language: String) async throws -> [SubtitleSearchResult] {
        try await provider.searchSubtitles(for: ref, language: language)
    }

    func download(_ result: SubtitleSearchResult) async throws {
        try await provider.downloadSubtitle(result, for: ref)
    }

    /// The item's detail once `sourceID` lists a subtitle `known` doesn't have.
    func detailWithNewSubtitle(sourceID: String, known: Set<Int>) async throws -> (detail: MediaItemDetail, trackID: Int)? {
        for _ in 0..<SubtitleArrival.attempts {
            try await Task.sleep(for: SubtitleArrival.interval)
            let detail = try await provider.fullDetail(for: ref)
            let source = detail.mediaSources.first { $0.id == sourceID } ?? detail.mediaSources.first
            if let added = source?.subtitleTracks.lazy.compactMap({ Int($0.id) }).first(where: { !known.contains($0) }) {
                return (detail, added)
            }
        }
        return nil
    }
}

extension PlexPlaybackRequest {
    /// The search for the playing title; nil for a downloaded file.
    var subtitleSearch: (any SubtitleSearching)? {
        if let providerPlayback {
            return ProviderSubtitleSearch(provider: providerPlayback.provider, ref: providerPlayback.item.ref)
        }
        guard !isLocal, !serverURL.isEmpty, let key = item.ratingKey else { return nil }
        return PlexSubtitleSearch(serverURL: serverURL, token: token, ratingKey: key)
    }
}
