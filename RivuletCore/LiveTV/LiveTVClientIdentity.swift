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

    /// Parses a raw stream URL string that may contain pipe-delimited headers
    /// (e.g. `http://host/stream.m3u8|User-Agent=CustomUA&Referer=...` or
    /// `%7CUser-Agent=...`) into a sanitized URL and extracted headers dictionary.
    ///
    /// Popular IPTV players (such as TiviMate and Kodi IPTV Simple Client) support
    /// appending HTTP headers to stream URLs after a pipe delimiter `|`.
    static func parseStreamURL(_ rawString: String) -> (url: URL, headers: [String: String])? {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        let components: [String]
        if let pipeRange = trimmed.range(of: "|") {
            components = [String(trimmed[..<pipeRange.lowerBound]), String(trimmed[pipeRange.upperBound...])]
        } else if let encPipeRange = trimmed.range(of: "%7C", options: .caseInsensitive) {
            components = [String(trimmed[..<encPipeRange.lowerBound]), String(trimmed[encPipeRange.upperBound...])]
        } else {
            components = [trimmed]
        }

        guard let cleanURL = URL(string: components[0].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        var headers: [String: String] = [:]

        if components.count > 1 {
            let rawHeaderString = components[1]
            let pairs = rawHeaderString.components(separatedBy: "&")
            for pair in pairs {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let rawKey = parts[0].trimmingCharacters(in: .whitespaces)
                let rawVal = parts[1].trimmingCharacters(in: .whitespaces)
                let val = rawVal.removingPercentEncoding ?? rawVal
                guard !rawKey.isEmpty, !val.isEmpty else { continue }

                if rawKey.caseInsensitiveCompare("User-Agent") == .orderedSame {
                    headers["User-Agent"] = val
                } else if rawKey.caseInsensitiveCompare("Referer") == .orderedSame {
                    headers["Referer"] = val
                } else {
                    headers[rawKey] = val
                }
            }
        }

        return (cleanURL, headers)
    }

    /// Resolves and sanitizes a stream URL by stripping any pipe-delimited headers
    /// and merging any discovered headers (such as `User-Agent`) into the provided stream headers.
    static func resolveStream(url: URL, baseHeaders: [String: String] = streamHeaders) -> (url: URL, headers: [String: String]) {
        guard let parsed = parseStreamURL(url.absoluteString) else {
            return (url, baseHeaders)
        }
        guard !parsed.headers.isEmpty || parsed.url != url else {
            return (url, baseHeaders)
        }
        var merged = baseHeaders
        for (k, v) in parsed.headers {
            merged[k] = v
        }
        return (parsed.url, merged)
    }
}
