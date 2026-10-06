// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Network

/// Where a playback server sits relative to this device, judged from its URL alone.
nonisolated enum ServerLocation: Equatable, Sendable {
    case local
    case remote
    case relay

    static func classify(_ url: URL) -> ServerLocation {
        if PlexRelay.isRelayURL(url) { return .relay }
        guard let host = url.host?.lowercased() else { return .remote }
        if host == "localhost" || host.hasSuffix(".local") { return .local }
        return isPrivateAddress(plexDirectAddress(host) ?? host) ? .local : .remote
    }

    static func classify(_ serverURL: String) -> ServerLocation {
        URL(string: serverURL).map(classify) ?? .remote
    }

    /// `192-168-1-140.<hash>.plex.direct` embeds the server's address with dashes.
    static func plexDirectAddress(_ host: String) -> String? {
        guard host.hasSuffix(".plex.direct"), let label = host.split(separator: ".").first else { return nil }
        let v4 = label.replacingOccurrences(of: "-", with: ".")
        if IPv4Address(v4) != nil { return v4 }
        let v6 = label.replacingOccurrences(of: "-", with: ":")
        return IPv6Address(v6) != nil ? v6 : nil
    }

    /// RFC 1918, CGNAT, link-local, loopback, and IPv6 ULA / link-local / loopback.
    static func isPrivateAddress(_ host: String) -> Bool {
        let literal = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let v4 = IPv4Address(literal) {
            let b = [UInt8](v4.rawValue)
            switch (b[0], b[1]) {
            case (10, _), (127, _), (192, 168), (169, 254), (172, 16...31), (100, 64...127): return true
            default: return false
            }
        }
        if let v6 = IPv6Address(literal) {
            let b = [UInt8](v6.rawValue)
            return v6 == .loopback || (b[0] & 0xFE) == 0xFC || (b[0] == 0xFE && (b[1] & 0xC0) == 0x80)
        }
        return false
    }
}
