// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  Scoreboard.swift
//  Rivulet
//
//  A league's games as the insights-api scores route serves them (ESPN,
//  trimmed). See Docs/superpowers/specs/2026-10-15-live-scores-design.md.
//

import Foundation

enum League: String, CaseIterable, Codable, Sendable {
    case nfl
    case collegeFootball = "college-football"
    case nba, mlb, nhl

    var title: String {
        switch self {
        case .nfl: "NFL"
        case .collegeFootball: String(localized: "College Football")
        case .nba: "NBA"
        case .mlb: "MLB"
        case .nhl: "NHL"
        }
    }

    /// Lowercased words a guide uses for the league, in a category, title or group.
    var guideWords: [String] {
        switch self {
        case .nfl: ["nfl"]
        case .collegeFootball: ["college football", "ncaaf", "ncaa football", "cfb"]
        case .nba: ["nba"]
        case .mlb: ["mlb", "baseball"]
        case .nhl: ["nhl", "hockey"]
        }
    }
}

struct ScoreTeam: Codable, Hashable, Sendable {
    let abbr: String
    /// "Chicago Bears".
    let name: String
    /// "Bears" for a pro team, the school ("East Carolina") in college.
    let short: String
    let nickname: String
    let location: String
    let score: Int?
    let logo: URL?
}

struct ScoreGame: Codable, Hashable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case pre, `in`, post }

    let id: String
    let state: State
    let start: Date
    /// ESPN's short status: "Q3 4:12", "Final", "10/18 - 1:00 PM EDT".
    let detail: String
    let network: String?
    let away: ScoreTeam
    let home: ScoreTeam
}

struct Scoreboard: Codable, Equatable, Sendable {
    let league: League
    let fetchedAt: Date
    /// The worker's last good copy, served while ESPN fails.
    let stale: Bool
    /// Seconds the worker wants between polls.
    let poll: Int
    let games: [ScoreGame]

    var hasLiveGame: Bool { games.contains { $0.state == .in } }

    static func decode(_ data: Data) throws -> Scoreboard {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Bad date \(text)"))
            }
            return date
        }
        return try decoder.decode(Scoreboard.self, from: data)
    }
}
