//
//  ContentRouter.swift
//  Rivulet
//
//  Decides the playback path for VOD content. Aether is the only engine:
//  whenever a direct-play URL exists the plan is Aether primary with a
//  Plex HLS transcode fallback; otherwise HLS is primary. The router also
//  owns the codec knowledge the HLS URL builder needs (which video codecs
//  must be server-transcoded rather than remuxed).
//

import Foundation

/// The ingestion path for a piece of content.
enum PlaybackRoute: Sendable, CustomStringConvertible {
    /// HLS via server-side remux/transcode — no direct-play URL, or
    /// fallback after an Aether startup failure.
    case hls(url: URL, headers: [String: String]?)

    /// AetherEngine — FFmpeg demux + HLS-fMP4 remux + AVPlayer with
    /// HDR10+ / HLG / EAC3+JOC Atmos stream-copy, and software decode
    /// for codecs Apple TV has no hardware decoder for (AV1 / VP9 /
    /// MPEG-2 / VC-1 / MPEG-4 Part 2). The only VOD engine; routed
    /// whenever a direct-play URL is available.
    case aether(url: URL, headers: [String: String]?)

    var description: String {
        switch self {
        case .hls: return "HLS"
        case .aether: return "Aether"
        }
    }
}

/// Playback policy for routed startup and fallback behavior.
enum PlaybackPolicy: String, Sendable {
    case directPlayFirst

    static let `default`: PlaybackPolicy = .directPlayFirst
}

/// Classification of direct-play failures used for fallback decisions and diagnostics.
enum DirectPlayFailureKind: String, Sendable {
    case unsupportedCodec
    case demuxInit
    case decodeInit
    case runtimeFatal
    case network
    case unknown
}

/// Playback startup plan with primary route, fallback routes, and routing reasons.
struct PlaybackPlan: Sendable, CustomStringConvertible {
    let policy: PlaybackPolicy
    let primary: PlaybackRoute
    let fallbacks: [PlaybackRoute]
    let reasoning: [String]

    var description: String {
        let fallbackSummary = fallbacks.map(\.description).joined(separator: ",")
        return "policy=\(policy.rawValue) primary=\(primary.description) fallbacks=[\(fallbackSummary)]"
    }
}

/// Content routing configuration
struct ContentRoutingContext: Sendable {
    let metadata: PlexMetadata
    let serverURL: URL
    let authToken: String

    /// Preferred playback policy. Defaults to direct-play-first for VOD.
    var playbackPolicy: PlaybackPolicy = .default
}

/// Analyzes media metadata to choose the playback pipeline.
struct ContentRouter {

    // MARK: - Video Codec Compatibility

    /// Video codecs Apple TV cannot decode natively at any tvOS version.
    /// Aether software-decodes these on its sample-buffer backend, so they
    /// still route to Aether — but the HLS fallback must force a video
    /// TRANSCODE (not just a remux) or the fallback would hand AVPlayer
    /// the same undecodable stream.
    ///
    /// Stored normalized (lowercased, hyphens/underscores stripped); the
    /// `requiresTranscode(videoCodec:)` helper applies the same normalization
    /// before lookup.
    static let videoCodecsRequiringTranscode: Set<String> = [
        "mpeg2", "mpeg2video", "mp2v",          // MPEG-2 (broadcast captures, classic-TV rips)
        "vc1", "wmv3",                          // VC-1 (older WMV-derived encodes)
        "vp9",                                  // VP9 (no Apple TV hardware decoder)
        "av1",                                  // AV1 (no Apple TV hardware decoder through A15 / 3rd-gen)
        "mpeg4", "mp4v",                        // MPEG-4 Part 2 / DivX / Xvid (no Apple TV decoder)
        "msmpeg4v1", "msmpeg4v2", "msmpeg4v3",  // Microsoft MPEG-4 v1/v2/v3 (.avi/.wmv rips)
    ]

    // MARK: - Route Decision

    /// Determine the playback startup/fallback plan for the given content.
    ///
    /// Two paths:
    /// 1. **Aether** — whenever a direct-play URL exists (all containers
    ///    and codecs; DV P7 plays as HDR10 base). Plex HLS as fallback.
    /// 2. **Plex HLS** — no direct-play URL.
    static func plan(for context: ContentRoutingContext) -> PlaybackPlan {
        let container = context.metadata.Media?.first?.container ?? "unknown"
        var reasoning: [String] = []
        let hls = buildHLSRoute(context: context)

        // A relay-tunneled server cannot serve raw parts for direct play
        // (HTTP 500 above its remote-bitrate policy), so Aether has nothing
        // it can ingest. Route straight to the capped HLS transcode, which
        // is how stock Plex plays over relay. The 1.5 Mbps 480p cap itself
        // is applied by buildHLSDirectPlayURL.
        if PlexRelay.isRelayURL(context.serverURL) {
            reasoning.append("relay_server_hls_transcode_only")
            playerDebugLog("[ContentRouter] \(container) → HLS (relay server, capped transcode)")
            return PlaybackPlan(
                policy: context.playbackPolicy,
                primary: hls,
                fallbacks: [],
                reasoning: reasoning
            )
        }

        if let aetherRoute = buildAetherRoute(context: context) {
            reasoning.append("aether,all-content")
            playerDebugLog("[ContentRouter] \(container) → Aether")
            return PlaybackPlan(
                policy: context.playbackPolicy,
                primary: aetherRoute,
                fallbacks: [hls],
                reasoning: reasoning
            )
        }

        // No direct-play URL (missing Media/Part metadata).
        reasoning.append("no_direct_play_url_fallback_to_hls")
        playerDebugLog("[ContentRouter] \(container) → HLS (no direct-play URL)")
        return PlaybackPlan(
            policy: context.playbackPolicy,
            primary: hls,
            fallbacks: [],
            reasoning: reasoning
        )
    }

    /// Check if a specific video codec requires server-side transcode on
    /// the HLS (AVPlayer) path.
    static func requiresTranscode(videoCodec: String) -> Bool {
        let normalized = videoCodec.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return videoCodecsRequiringTranscode.contains(normalized)
    }

    /// Convenience: does this metadata's video stream require a
    /// server-side transcode when played over the HLS fallback?
    static func requiresVideoTranscode(metadata: PlexMetadata) -> Bool {
        if let codec = primaryVideoCodec(from: metadata), !codec.isEmpty,
           requiresTranscode(videoCodec: codec) {
            return true
        }
        return false
    }

    /// Extract the primary video codec from PlexMetadata. Used by the
    /// HLS URL builder's forceVideoTranscode plumbing.
    static func primaryVideoCodec(from metadata: PlexMetadata) -> String? {
        if let media = metadata.Media?.first, let codec = media.videoCodec {
            return codec
        }
        if let part = metadata.Media?.first?.Part?.first,
           let videoStream = part.Stream?.first(where: { $0.isVideo }) {
            return videoStream.codec
        }
        return nil
    }

    // MARK: - Private: Route Building

    /// Build the direct Plex URL for raw file access.
    private static func buildDirectPlayURL(context: ContentRoutingContext) -> (url: URL, headers: [String: String])? {
        guard let media = context.metadata.Media?.first,
              let part = media.Part?.first else {
            return nil
        }

        var components = URLComponents(url: context.serverURL, resolvingAgainstBaseURL: false)!
        components.path = part.key

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: context.authToken))
        components.queryItems = queryItems

        guard let url = components.url else { return nil }

        let headers = ["X-Plex-Token": context.authToken]
        return (url, headers)
    }

    /// Build Aether route — Aether demuxes the source itself and remuxes
    /// to HLS-fMP4 over loopback for AVPlayer.
    private static func buildAetherRoute(context: ContentRoutingContext) -> PlaybackRoute? {
        guard let (url, headers) = buildDirectPlayURL(context: context) else { return nil }
        return .aether(url: url, headers: headers)
    }

    private static func buildHLSRoute(context: ContentRoutingContext) -> PlaybackRoute {
        // HLS URL building is handled by PlexNetworkManager.
        // This signals that the HLS path should be used.
        return .hls(url: context.serverURL, headers: ["X-Plex-Token": context.authToken])
    }

}
