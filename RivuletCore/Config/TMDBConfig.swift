// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBConfig.swift
//  Rivulet
//
//  Centralized configuration for TMDB access.
//

import Foundation

nonisolated enum TMDBConfig {
    /// Proxy base URL (Cloudflare Worker) that forwards TMDB requests with caching.
    /// The custom domain, not workers.dev: only this host has the per-IP rate limit.
    static let proxyBaseURL = URL(string: "https://tmdb.gurleystudios.com")!

    /// TMDB's own v3 API, used instead of the proxy by a self-build with its own key (`TMDBCredential`).
    static let apiBaseURL = URL(string: "https://api.themoviedb.org/3")!

    /// Cache TTL for TMDB responses when stored locally (in seconds).
    static let localCacheTTL: TimeInterval = 60 * 60 * 24 * 30  // 30 days
}
