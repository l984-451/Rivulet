//
//  PlexRelay.swift
//  Rivulet
//
//  Plex relay-connection detection.
//
//  A server reached through Plex's relay (its only route when the owner
//  has no working remote access) sits behind a bandwidth-capped
//  single-tunnel proxy (roughly 1-2 Mbps). It refuses raw part fetches
//  above the server's remote-bitrate policy: the same /library/parts
//  request that a directly reachable server answers with 206 Partial
//  Content comes back as HTTP 500 through the relay, so direct play
//  fails at open, and original-bitrate streams that do serve cannot be
//  sustained through the tunnel. ContentRouter routes relay servers
//  straight to the HLS path, and buildHLSDirectPlayURL caps that
//  session at 1.5 Mbps 480p, which is the same shape stock Plex uses
//  (it shows "Convert to 480p" on every relay item).
//

import Foundation

enum PlexRelay {
    /// Plex relay endpoints are always `<ip-dashes>.<hash>.plex.direct:8443`;
    /// direct plex.direct connections embed the server's real port instead.
    static func isRelayURL(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return host.hasSuffix(".plex.direct") && url.port == 8443
    }

    static func isRelayURL(_ serverURL: String) -> Bool {
        guard let url = URL(string: serverURL) else { return false }
        return isRelayURL(url)
    }
}
