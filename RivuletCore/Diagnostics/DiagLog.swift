// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The app's lines for Settings > About > Send Diagnostics, which reads them back from OSLog.
// Logged public at notice so a release build keeps them, and scrubbed of credentials on the way in.
// Still pass no titles, user or server names, or addresses: describe a server with `describe(url:)`.

import Foundation
import OSLog
import Sentry

nonisolated enum DiagLog {
    static let subsystem = "com.rivulet.app"

    enum Category: String, CaseIterable, Sendable {
        case launch, auth, connection, profile, home, network, playback, servers, crumb, http, attest
        case topShelf = "top_shelf"
        case deepLink = "deep_link"
        case liveTV = "live_tv"
    }

    private static let loggers: [Category: Logger] = Dictionary(
        uniqueKeysWithValues: Category.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) })

    static func notice(_ category: Category, _ message: String) {
        let line = SensitiveDataRedactor.redact(message)
        loggers[category]?.notice("\(line, privacy: .public)")
    }

    static func error(_ category: Category, _ message: String) {
        let line = SensitiveDataRedactor.redact(message)
        loggers[category]?.error("\(line, privacy: .public)")
    }

    /// A server address without the address: "https plex.direct :32400 /path".
    static func describe(url: String?) -> String {
        guard let url, let parsed = URL(string: url), let host = parsed.host else { return "no url" }
        let port = parsed.port.map { " :\($0)" } ?? ""
        return "\(parsed.scheme ?? "?") \(hostKind(host))\(port)"
    }

    /// Our own services by name; a media server only by the kind of address.
    private static func hostKind(_ host: String) -> String {
        if host.hasSuffix(".plex.direct") { return "plex.direct" }
        if host.hasSuffix("plex.tv") || host.hasSuffix("workers.dev") || host.hasSuffix("sentry.io")
            || host.hasSuffix("themoviedb.org") { return host }
        if host == "localhost" || host == "127.0.0.1" { return "loopback" }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return isPrivateIPv4(host) ? "lan ipv4" : "ipv4" }
        return host.contains(":") ? "ipv6" : "hostname"
    }

    /// Domain and code, plus a short description. Never the userInfo, which carries failing URLs.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (\(underlying.domain) \(underlying.code))"
        }
        if ns.domain != NSURLErrorDomain {
            text += ": \(String(String(describing: error).prefix(160)))"
        }
        return text
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
    }

    // MARK: - Sentry breadcrumbs

    /// Mirrors a breadcrumb into the log, so the report holds the whole session rather than
    /// the last 100 crumbs Sentry keeps. Debug crumbs (one per remote press) are skipped.
    static func mirror(_ crumb: Breadcrumb) {
        guard crumb.level.rawValue >= SentryLevel.info.rawValue else { return }
        let data = crumb.data ?? [:]
        if crumb.category == "http" {
            notice(.http, httpLine(data, level: crumb.level))
            return
        }
        if crumb.category == "ui.lifecycle" {
            if let screen = data["screen"] as? String { notice(.crumb, "[screen] \(screen.prefix(80))") }
            return
        }
        let fields = data.keys.sorted().compactMap { key -> String? in
            guard !["url", "server_host", "url_host", "channel_name", "title"].contains(key) else { return nil }
            return "\(key)=\(String(describing: data[key]!).prefix(80))"
        }
        let line = "[\(crumb.category)] \(crumb.message ?? "")" + (fields.isEmpty ? "" : " " + fields.joined(separator: " "))
        crumb.level.rawValue >= SentryLevel.warning.rawValue ? error(.crumb, line) : notice(.crumb, line)
    }

    /// "GET 200 plex.direct /hubs/continueWatching 6.7KB" from Sentry's network breadcrumb.
    private static func httpLine(_ data: [String: Any], level: SentryLevel) -> String {
        let method = data["method"] as? String ?? "?"
        let status = (data["status_code"] as? NSNumber).map { "\($0)" } ?? "-"
        var target = "?"
        if let raw = data["url"] as? String, let url = URL(string: raw) {
            target = "\(hostKind(url.host ?? "")) \(url.path.prefix(120))"
        }
        let size = (data["response_body_size"] as? NSNumber).map { " \(ByteCountFormatter.string(fromByteCount: $0.int64Value, countStyle: .file))" } ?? ""
        let reason = (data["reason"] as? String).flatMap { $0 == "no error" ? nil : " \($0.prefix(60))" } ?? ""
        return "\(method) \(status) \(target)\(size)\(reason)"
    }
}
