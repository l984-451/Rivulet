// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

//
//  Subtitle search on Emby (4.10, measured). `RemoteSearch/Subtitles/{language}` answers 200 with an
//  empty list while the Open Subtitles provider has no account set up, so an empty result is not an
//  error. Non-admin users carry `EnableSubtitleDownloading` (on by default).
//

import Foundation

extension EmbyProvider {
    /// Users with subtitle downloading, and only where a subtitle provider is listed.
    func canSearchSubtitles() async -> Bool {
        let options: EmbyLibraryAvailableOptions? = try? await client.get("Libraries/AvailableOptions")
        return Self.allowsSubtitleSearch(policy: await currentPolicy(), fetchers: options?.subtitleFetchers)
    }

    func searchSubtitles(for ref: MediaItemRef, language: String) async throws -> [SubtitleSearchResult] {
        let found: [EmbyRemoteSubtitle] = try await client.get(
            "Items/\(ref.itemID)/RemoteSearch/Subtitles/\(SubtitleSearchLanguage.alpha3(language))")
        return found.compactMap(Self.subtitleResult)
    }

    func downloadSubtitle(_ result: SubtitleSearchResult, for ref: MediaItemRef) async throws {
        try await client.post("Items/\(ref.itemID)/RemoteSearch/Subtitles/\(result.id)")
    }

    /// nil fetchers (unknown) count as present; an unset right counts as allowed.
    static func allowsSubtitleSearch(policy: EmbySession.Policy, fetchers: [EmbyLibraryAvailableOptions.Fetcher]?) -> Bool {
        guard policy.isAdministrator || policy.enableSubtitleDownloading != false else { return false }
        return fetchers.map { !$0.isEmpty } ?? true
    }

    static func subtitleResult(_ dto: EmbyRemoteSubtitle) -> SubtitleSearchResult? {
        guard let id = dto.id, !id.isEmpty else { return nil }
        return SubtitleSearchResult(
            id: id, title: dto.name, language: dto.threeLetterISOLanguageName.map(TrackLanguage.displayName),
            format: dto.format, isHearingImpaired: dto.isHearingImpaired == true, isForced: dto.isForced == true)
    }
}
