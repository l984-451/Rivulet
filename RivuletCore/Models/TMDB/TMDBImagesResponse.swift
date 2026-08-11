// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBImagesResponse.swift
//  Rivulet
//
//  Decoded payload of TMDB's `/{type}/{id}/images` endpoint (proxied as
//  `/tmdb/images/{id}?type={movie|tv}`). Carries the DTO plus a pure
//  helper that picks the best logo according to language preference and
//  TMDB's community vote score.
//

import Foundation

struct TMDBImagesResponse: Decodable, Sendable {
    let logos: [TMDBImageEntry]

    enum CodingKeys: String, CodingKey {
        case logos
    }

    init(logos: [TMDBImageEntry]) {
        self.logos = logos
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        logos = (try? c.decode([TMDBImageEntry].self, forKey: .logos)) ?? []
    }
}

struct TMDBImageEntry: Decodable, Sendable {
    let filePath: String?
    let iso6391: String?
    let voteAverage: Double?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case iso6391 = "iso_639_1"
        case voteAverage = "vote_average"
    }
}

extension TMDBImagesResponse {
    /// Best logo's relative path according to:
    /// 1. Prefer `iso_639_1 == "en"`
    /// 2. Else `iso_639_1 == nil` (language-agnostic mark)
    /// 3. Else any remaining
    /// 4. Within a tier: highest `voteAverage`
    /// Entries with a missing/empty `file_path` are skipped.
    var bestLogoPath: String? {
        let candidates = logos.filter { ($0.filePath?.isEmpty == false) }
        guard !candidates.isEmpty else { return nil }

        func bestByVote(_ entries: [TMDBImageEntry]) -> TMDBImageEntry? {
            entries.max(by: { ($0.voteAverage ?? 0) < ($1.voteAverage ?? 0) })
        }

        let english = candidates.filter { $0.iso6391 == "en" }
        if let pick = bestByVote(english) { return pick.filePath }

        let agnostic = candidates.filter { $0.iso6391 == nil }
        if let pick = bestByVote(agnostic) { return pick.filePath }

        return bestByVote(candidates)?.filePath
    }
}
