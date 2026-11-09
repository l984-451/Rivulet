// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

//
//  Subtitle search on Jellyfin (12.1, measured). `RemoteSearch/Subtitles/{language}` answers 200 with
//  an empty list when no provider plugin is installed, and 403 without the SubtitleManagement right
//  (administrators have it). The provider list (`Libraries/AvailableOptions`) is readable by any user.
//

import Foundation

extension JellyfinProvider {
    /// Administrators and users with subtitle management, and only where a subtitle provider is installed.
    /// A failed read is not "no": the row stays, and the search says what went wrong.
    func canSearchSubtitles() async -> Bool {
        guard let me: JFUserWithPolicy = try? await client.get("Users/Me") else { return true }
        let options: JFLibraryAvailableOptions? = try? await client.get("Libraries/AvailableOptions")
        return Self.allowsSubtitleSearch(policy: me.policy, fetchers: options?.subtitleFetchers)
    }

    func searchSubtitles(for ref: MediaItemRef, language: String) async throws -> [SubtitleSearchResult] {
        let found: [JFRemoteSubtitle] = try await client.get(
            "Items/\(ref.itemID)/RemoteSearch/Subtitles/\(SubtitleSearchLanguage.alpha3(language))")
        return found.compactMap(Self.subtitleResult)
    }

    func downloadSubtitle(_ result: SubtitleSearchResult, for ref: MediaItemRef) async throws {
        try await client.post("Items/\(ref.itemID)/RemoteSearch/Subtitles/\(result.id)")
    }

    /// nil fetchers (unknown) count as present.
    static func allowsSubtitleSearch(policy: JFUserWithPolicy.Policy?, fetchers: [JFLibraryAvailableOptions.Fetcher]?) -> Bool {
        guard policy?.isAdministrator == true || policy?.enableSubtitleManagement == true else { return false }
        return fetchers.map { !$0.isEmpty } ?? true
    }

    static func subtitleResult(_ dto: JFRemoteSubtitle) -> SubtitleSearchResult? {
        guard let id = dto.id, !id.isEmpty else { return nil }
        return SubtitleSearchResult(
            id: id, title: dto.name, language: dto.threeLetterISOLanguageName.map(TrackLanguage.displayName),
            format: dto.format, isHearingImpaired: dto.hearingImpaired == true, isForced: dto.forced == true)
    }
}
