// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveChannelsPaneScope.swift
//  Rivulet
//
//  Which channels the player's Channels pane lists. The pane builds a card per
//  channel, which a tuner's lineup (a hundred or so) affords and an IPTV
//  lineup (tens of thousands) does not: building them all held the main
//  thread for minutes. A large lineup lists the playing channel's own group,
//  and at most `limit` channels around it.
//

import Foundation

nonisolated enum LiveChannelsPaneScope {
    static let limit = 300

    static func channels(_ lineup: [UnifiedChannel], playing: UnifiedChannel) -> [UnifiedChannel] {
        guard lineup.count > limit else { return lineup }
        let group = LiveGroupOrder.trimmed(playing.groupTitle)
        let sameGroup = group.map { group in
            lineup.filter { $0.sourceId == playing.sourceId && LiveGroupOrder.trimmed($0.groupTitle) == group }
        } ?? []
        let scope = sameGroup.isEmpty ? lineup : sameGroup
        guard scope.count > limit else { return scope }
        let index = scope.firstIndex { $0.id == playing.id } ?? 0
        let start = min(max(index - limit / 2, 0), scope.count - limit)
        return Array(scope[start..<(start + limit)])
    }
}
