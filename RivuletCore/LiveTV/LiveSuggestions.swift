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
    typealias Candidate = (channel: UnifiedChannel, program: UnifiedProgram?, genre: LiveGenre?)

    /// A score at or above this is a suggestion: one genre match from today at
    /// the same hour.
    static let threshold = 1.0

    /// Candidates whose current programme scores a suggestion, best first.
    static func rank(_ candidates: [Candidate], history: [LiveViewing], now: Date,
                     calendar: Calendar = .current) -> [UnifiedChannel] {
        let scored = scores(candidates.map { ($0, now) }, history: history, now: now, calendar: calendar)
        return zip(candidates.map(\.channel), scored)
            .filter { $0.1 >= threshold }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1
                : ($0.0.channelNumber ?? .max) < ($1.0.channelNumber ?? .max) }
            .map(\.0)
    }

    /// How much each candidate's programme shares with past viewings, judged
    /// at its own time `at` (when it starts, for one not on yet): the same show
    /// counts most, then the same kind of programme ("football"), then the
    /// same genre, plus a little for the same channel. A viewing weighs less as
    /// it ages (half after two weeks), the further its hour is from `at`'s, and
    /// on another day: 0.7 for the same kind of day (weekend or weekday), 0.5
    /// otherwise, so Saturday noon learns from Saturday noons first.
    static func scores(_ candidates: [(candidate: Candidate, at: Date)], history: [LiveViewing], now: Date,
                       calendar: Calendar = .current) -> [Double] {
        guard !history.isEmpty else { return candidates.map { _ in 0 } }
        // Once per viewing, not per candidate: a title key is a regex pass.
        let past = history.map { viewing in
            (viewing: viewing, title: showKey(viewing.title),
             recency: pow(0.5, max(0, now.timeIntervalSince(viewing.at)) / 86_400 / 14),
             hour: hourOfDay(viewing.at, calendar), weekday: calendar.component(.weekday, from: viewing.at),
             weekend: calendar.isDateInWeekend(viewing.at))
        }
        return candidates.map { candidate, at in
            // A guide gap is filled with a stand-in named after the channel,
            // which would match every past viewing of that channel by title.
            let program = candidate.program.flatMap { $0.id.contains(":placeholder:") ? nil : $0 }
            let title = showKey(program?.title)
            let labels = LiveGenre.specificLabels(of: program)
            let genre = candidate.genre?.rawValue
            let hour = hourOfDay(at, calendar)
            let weekday = calendar.component(.weekday, from: at)
            let weekend = calendar.isDateInWeekend(at)
            var score = 0.0
            for seen in past {
                var match = 0.0
                if let title, title == seen.title {
                    match = 3
                } else if !labels.isDisjoint(with: seen.viewing.labels) {
                    match = 2
                } else if let genre, genre == seen.viewing.genre {
                    match = 1
                }
                if seen.viewing.channelId == candidate.channel.id { match += 1 }
                guard match > 0 else { continue }
                let apart = abs(seen.hour - hour)
                let day = seen.weekday == weekday ? 1 : seen.weekend == weekend ? 0.7 : 0.5
                score += match * seen.recency * max(0.2, 1 - min(apart, 24 - apart) / 6) * day
            }
            return score
        }
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
