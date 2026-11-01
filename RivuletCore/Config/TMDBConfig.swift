// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBConfig.swift
//  Rivulet
//
//  Centralized configuration for TMDB proxy access.
//

import Foundation

enum TMDBConfig {
    /// Proxy base URL (Cloudflare Worker) that forwards TMDB requests with caching.
    /// The custom domain, not workers.dev: only this host has the per-IP rate limit.
    static let proxyBaseURL = URL(string: "https://tmdb.gurleystudios.com")!

    /// Cache TTL for TMDB responses when stored locally (in seconds).
    static let localCacheTTL: TimeInterval = 60 * 60 * 24 * 30  // 30 days
}
