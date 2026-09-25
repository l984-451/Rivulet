// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

struct IOSPlaybackHeaders: Hashable, Sendable {
    let userAgent: String
    let authorization: String?
    let referer: String?

    var dictionary: [String: String] {
        var headers = ["User-Agent": userAgent]
        if let authorization, !authorization.isEmpty {
            headers["Authorization"] = authorization
        }
        if let referer, !referer.isEmpty {
            headers["Referer"] = referer
        }
        return headers
    }
}

struct IOSIPTVChannel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let channelNumber: Int?
    let tvgID: String?
    let tvgName: String?
    let groupTitle: String?
    let logoURL: URL?
    let streamURL: URL
    let playbackHeaders: IOSPlaybackHeaders
}

struct IOSEPGProgram: Identifiable, Hashable, Sendable {
    let id: String
    let channelID: String
    let title: String
    let subtitle: String?
    let description: String?
    let category: String?
    let episodeNumber: String?
    let iconURL: URL?
    let posterURL: URL?
    let landscapeURL: URL?
    let start: Date
    let end: Date
    let isNew: Bool

    init(
        id: String,
        channelID: String,
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        category: String? = nil,
        episodeNumber: String? = nil,
        iconURL: URL? = nil,
        posterURL: URL? = nil,
        landscapeURL: URL? = nil,
        start: Date,
        end: Date,
        isNew: Bool = false
    ) {
        self.id = id
        self.channelID = channelID
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.category = category
        self.episodeNumber = episodeNumber
        self.iconURL = iconURL
        self.posterURL = posterURL
        self.landscapeURL = landscapeURL
        self.start = start
        self.end = end
        self.isNew = isNew
    }

    func isAiring(at date: Date) -> Bool {
        start <= date && end > date
    }
}

struct IOSGuideSelection: Identifiable {
    let channel: IOSIPTVChannel
    let program: IOSEPGProgram

    var id: String { program.id }
}

struct IOSPlaybackRequest: Identifiable {
    let channel: IOSIPTVChannel
    let program: IOSEPGProgram?

    var id: String {
        "\(channel.id)|\(program?.id ?? "live")"
    }
}
