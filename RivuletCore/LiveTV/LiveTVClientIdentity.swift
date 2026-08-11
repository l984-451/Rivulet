// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTVClientIdentity.swift
//  Rivulet
//
//  The HTTP identity Rivulet presents when it pulls a Live TV stream.
//

import Foundation

/// How Rivulet identifies itself to an IPTV server on a Live TV stream request.
///
/// Dispatcharr's `stream_ts` view is `@permission_classes([AllowAny])` and only
/// resolves a named user from a Django session cookie. A DRF
/// `Authorization: Token` header authenticates API calls but does NOT name the
/// client on a stream, so Dispatcharr falls back to hashing the client IP and
/// User-Agent and the connection shows up as anonymous. Sending a stable,
/// distinctive User-Agent does not produce a username, but it makes Rivulet
/// recognisable in the stats and connections views and keeps that hash stable
/// across reconnects. Only Xtream-style credentials in the URL would supply a
/// real username, and that is deliberately not implemented here.
///
/// See GitHub issue #246.
enum LiveTVClientIdentity {

    /// The User-Agent header value, for example `Rivulet/1.0.3`.
    ///
    /// Read from the bundle rather than hardcoded so it tracks releases without
    /// anyone remembering to update it. Contains no user, device, or token data,
    /// so it is safe to send to any server and safe to log.
    static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Rivulet/\(version)"
    }()

    /// Headers attached to every Live TV stream load. Kept as a single value so
    /// the player call sites cannot drift apart from one another.
    static let streamHeaders: [String: String] = ["User-Agent": userAgent]
}
