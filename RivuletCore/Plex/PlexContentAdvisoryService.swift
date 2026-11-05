// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexContentAdvisoryService.swift
//  Rivulet
//
//  Fetches the FULL Common Sense Media advisory from Plex Discover
//  (metadata.provider.plex.tv). The local `/library/metadata/{key}` response
//  carries only a partial CSM object (age rating + one-liner); the rich data
//  (parentsNeedToKnow + per-topic breakdown) lives at the per-item sub-endpoint
//  `/library/metadata/{discoverRatingKey}/commonSenseMedia`, reached by resolving
//  the item's external guid → a Discover ratingKey. Requires the account token
//  (Plex Pass for the full data). Mirrors the PlexWatchlistAPI cloud-call pattern.
//

import Foundation

struct PlexContentAdvisoryService: Sendable {
    private let metadataHost = "https://metadata.provider.plex.tv"

    /// Resolve the item's external `guid` (e.g. "tmdb://157336") to its Discover
    /// ratingKey, then fetch the full advisory. Returns nil if unmatched / no
    /// Plex Pass / no advisory.
    func advisory(forGuid guid: String, isMovie: Bool, accountToken: String) async -> ContentAdvisory? {
        guard let rk = await discoverRatingKey(guid: guid, isMovie: isMovie, token: accountToken) else { return nil }
        return await fullAdvisory(discoverRatingKey: rk, token: accountToken)
    }

    private func discoverRatingKey(guid: String, isMovie: Bool, token: String) async -> String? {
        // Try the likely Plex type first (1 = movie, 2 = show), then the other.
        for type in (isMovie ? ["1", "2"] : ["2", "1"]) {
            guard let enc = guid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "\(metadataHost)/library/metadata/matches?type=\(type)&guid=\(enc)&X-Plex-Token=\(token)"),
                  let data = try? await get(url, token: token),
                  let wrapper = try? JSONDecoder().decode(MatchWrapper.self, from: data),
                  let rk = wrapper.MediaContainer.Metadata?.first?.ratingKey else { continue }
            return rk
        }
        return nil
    }

    private func fullAdvisory(discoverRatingKey rk: String, token: String) async -> ContentAdvisory? {
        guard let url = URL(string: "\(metadataHost)/library/metadata/\(rk)/commonSenseMedia?X-Plex-Token=\(token)"),
              let data = try? await get(url, token: token),
              let wrapper = try? JSONDecoder().decode(PlexCSMContainerWrapper.self, from: data),
              let csm = wrapper.MediaContainer.CommonSenseMedia?.first else { return nil }
        let advisory = PlexMediaMapper.contentAdvisory(from: csm)
        return advisory.hasAny ? advisory : nil
    }

    private func get(_ url: URL, token: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        req.setValue(PlexAPI.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        req.setValue(PlexAPI.productName, forHTTPHeaderField: "X-Plex-Product")
        req.setValue(PlexAPI.platform, forHTTPHeaderField: "X-Plex-Platform")
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    private struct MatchWrapper: Decodable {
        let MediaContainer: Inner
        struct Inner: Decodable { let Metadata: [Raw]? }
        struct Raw: Decodable { let ratingKey: String? }
    }
}
