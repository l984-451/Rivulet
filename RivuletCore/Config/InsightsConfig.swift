// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsConfig.swift
//  Rivulet
//
//  Configuration for the Insights trivia read API (Cloudflare Worker + R2).
//

import Foundation

enum InsightsConfig {
    /// Base URL of the insights-api Worker that serves trivia JSON from R2.
    static let apiBaseURL = URL(string: "https://insights-api.baingurley.workers.dev")!

    /// In-memory cache TTL for a fetched title's trivia within a session.
    /// Trivia is immutable per generatedAt, so a session-length cache is safe.
    static let sessionCacheTTL: TimeInterval = 60 * 30
}
