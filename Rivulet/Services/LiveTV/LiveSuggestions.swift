// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveSuggestions.swift
//  Rivulet
//
//  What's On's For You row: channels whose programme right now is most like
//  what this viewer has watched before, at this time of day. Learned and
//  ranked on the device; nothing leaves the box.
//

import Foundation

/// A channel watched long enough to count (a minute, full screen). Keeps what
/// was on, not the stream.
struct LiveViewing: Codable, Equatable {
    let channelId: String
    let at: Date
    let title: String?
    let labels: [String]
    let genre: String?
}

enum LiveSuggestions {

    /// Candidates ranked by how much their current programme shares with past
    /// viewings: the same show counts most, then the same kind of programme
    /// ("football"), then the same genre, plus a little for the same channel.
    /// Each viewing weighs less as it ages (half after two weeks) and when it
    /// was at a different hour. Channels scoring under one genre match from
    /// today at this hour are left out.
    static func rank(_ candidates: [(channel: UnifiedChannel, program: UnifiedProgram?, genre: LiveGenre?)],
                     history: [LiveViewing], now: Date,
                     calendar: Calendar = .current) -> [UnifiedChannel] {
        guard !history.isEmpty else { return [] }
        let hourNow = hourOfDay(now, calendar)
        let weighted = history.map { viewing -> (viewing: LiveViewing, weight: Double) in
            let ageDays = max(0, now.timeIntervalSince(viewing.at)) / 86_400
            let recency = pow(0.5, ageDays / 14)
            let apart = abs(hourOfDay(viewing.at, calendar) - hourNow)
            let hours = min(apart, 24 - apart)
            return (viewing, recency * max(0.2, 1 - hours / 6))
        }

        let scored = candidates.compactMap { candidate -> (UnifiedChannel, Double)? in
            // A guide gap is filled with a stand-in named after the channel,
            // which would match every past viewing of that channel by title.
            let program = candidate.program.flatMap { $0.id.contains(":placeholder:") ? nil : $0 }
            let title = showKey(program?.title)
            let labels = LiveGenre.specificLabels(of: program)
            let genre = candidate.genre?.rawValue
            var score = 0.0
            for (viewing, weight) in weighted {
                var match = 0.0
                if let title, title == showKey(viewing.title) {
                    match = 3
                } else if !labels.isDisjoint(with: viewing.labels) {
                    match = 2
                } else if let genre, genre == viewing.genre {
                    match = 1
                }
                if viewing.channelId == candidate.channel.id { match += 1 }
                score += match * weight
            }
            return score >= 1 ? (candidate.channel, score) : nil
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1
                : ($0.0.channelNumber ?? .max) < ($1.0.channelNumber ?? .max) }
            .map(\.0)
    }

    /// A title as the same show across airings: some guides prefix the live
    /// airing ("Live: First Take") and not the replay.
    private static func showKey(_ title: String?) -> String? {
        guard let title else { return nil }
        let key = UnifiedProgram.displayTitle(title).lowercased().trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    private static func hourOfDay(_ date: Date, _ calendar: Calendar) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }
}
