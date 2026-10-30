// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated struct SiloPlaybackCapabilities: Decodable, Sendable {
    let state: String
    let allowed: Bool
    let installationId: String?
    let protocolVersions: [Int]
    let features: [String]
    let deliveries: [String]
}

nonisolated struct SiloPlaybackStart: Encodable, Sendable {
    let installationId: String
    let protocolVersion = 3
    var clientFeatures = ["playback_plan_v3", "sequenced_progress_v1", "plan_source_duration_v1", "embedded_subtitles_v1"]
    let fileId: String
    let profileId: String
    let playbackAttemptId: String
    var qualityPreference: String = "auto"
    var qualityIntent: MediaQualityPreference {
        qualityPreference == "auto" ? .automatic : .offered(id: qualityPreference)
    }
        let subtitleFidelityPreference = "compatible"
    let clientCapabilities: SiloCodecCapabilities
    var clientPlaybackContext: SiloPlaybackContext
    let allowAlternateVersions: Bool
    let startPosition: Double
    var bandwidthCapKbps: Int?
    var bandwidthEstimateKbps: Int?
    var bandwidthEstimateSource: String?
    var observedThroughputKbps: Int?
    var learnedLimit: String?
    let audioTrackId: String?
    let audioTrackIndex: Int?
    let subtitleTrackId: String?
    let subtitleTrackIndex: Int?
    let progressPersistence = "server"
    init(installationId: String, fileId: String, profileId: String, playbackAttemptId: String,
         clientCapabilities: SiloCodecCapabilities, clientPlaybackContext: SiloPlaybackContext,
         allowAlternateVersions: Bool, startPosition: Double, bandwidthCapKbps: Int?,
         audioTrackId: String?, audioTrackIndex: Int?, subtitleTrackId: String?, subtitleTrackIndex: Int?,
         qualityPreference: MediaQualityPreference = .automatic) {
        self.installationId = installationId
        self.fileId = fileId
        self.profileId = profileId
        self.playbackAttemptId = playbackAttemptId
        self.qualityPreference = qualityPreference.serverValue
        self.clientCapabilities = clientCapabilities
        self.clientPlaybackContext = clientPlaybackContext
        self.allowAlternateVersions = allowAlternateVersions
        self.startPosition = startPosition
        self.bandwidthCapKbps = bandwidthCapKbps
        self.audioTrackId = audioTrackId
        self.audioTrackIndex = audioTrackIndex
        self.subtitleTrackId = subtitleTrackId
        self.subtitleTrackIndex = subtitleTrackIndex
    }

}

nonisolated struct SiloCodecCapabilities: Encodable, Sendable {
    // FFmpeg/Aether decode-family declarations, not platform-attested native
    // decoders or HDMI passthrough. Strict video tiers require video_decode.
    let videoEvidence = "declared"
    let audioEvidence = "declared"
    let codecsVideo: [String]
    let codecsVideoHardware: [String]
    let codecsAudio: [String]
    let containers: [String]
    let hdr: Bool
    let hdrDetails: SiloHDRCapabilities
    let maxResolution = "2160p"
}

nonisolated struct SiloHDRCapabilities: Encodable, Sendable {
    let hdr10: Bool
    let hdr10Plus: Bool
    let hlg: Bool
    let dolbyVisionProfiles: [Int]
}

nonisolated struct SiloPlaybackContext: Encodable, Sendable {
    let protocolVersion = 3
    let formFactor = "tv"
    let appVersion: String
    let appBuild: String
    let device: SiloDeviceContext
    let output: SiloOutputContext
    let deliveries: [String: SiloDeliveryCapabilities]
}

nonisolated struct SiloDeviceContext: Encodable, Sendable {
    let manufacturer = "Apple"
    let model: String
    let osVersion: String
    let platform = "tvos"
}

nonisolated struct SiloOutputContext: Encodable, Sendable {
    let hdrDetails: SiloHDRCapabilities
}

nonisolated struct SiloDeliveryCapabilities: Encodable, Sendable {
    let enabled = true
    let supportedOnDevice = true
    let containers: [String]
    let videoCodecs: [String]
    let audioDecodeCodecs: [String]
    let audioPassthroughCodecs: [String] = []
    let subtitles: SiloSubtitleCapabilities
    var features: [String] = []
    let authHeaderRefresh = false
    var validatedClaims: [String] = []
    let transformations: [String] = []
    let hdrDetails: SiloHDRCapabilities
    let maxChannels = 8
}

nonisolated struct SiloSubtitleCapabilities: Encodable, Sendable {
    let embeddedText: Bool
    let sidecarText: Bool
    let assStyling: Bool
    let embeddedBitmap: Bool
    let sidecarBitmap = false
    let fontAttachments: Bool
    var nativeEmbedded: [SiloNativeEmbeddedSubtitleCapabilities] = []
}

nonisolated struct SiloNativeEmbeddedSubtitleCapabilities: Encodable, Sendable {
    let container: String
    let codecs: [String]
    let trackIdentity = "ffmpeg_stream_index"
    let assStyling = true
    let fontAttachments = true
}

nonisolated struct SiloPlaybackDecision: Decodable, Sendable {
    let protocolVersion: Int
    let outcome: String
    let sessionId: String?
    let playbackPlan: SiloPlaybackPlan?
    let terminal: SiloPlaybackTerminal?
    let serverFeatures: [String]?
}

nonisolated struct SiloPlaybackTerminal: Decodable, Sendable {
    let reason: String
    let message: String
    let retryable: Bool
}

nonisolated struct SiloPlaybackPlan: Decodable, Sendable {
    let protocolVersion: Int
    let planId: String
    let planAttemptKey: String
    let sessionId: String?
    let delivery: String
    let expiresAt: String?
    let stream: SiloPlanStream
    let timeline: SiloPlanTimeline
    let effectiveMediaFileId: String
    let selectedTracks: SiloSelectedTracks
    let subtitle: SiloPlanSubtitle
    let source: SiloPlanSource
    let availableQualities: [SiloAvailableQuality]?
    let activeQuality: String?
    let effectiveRecipe: SiloEffectiveRecipe?
    let decisionReason: String?
    let degradationWarnings: [SiloDegradationWarning]?
    let bandwidthLimit: SiloBandwidthLimit?

    var negotiatedStatus: MediaNegotiatedStatus {
        let transport: MediaDelivery = switch delivery {
        case "original_http": .original
        case "server_remux_progressive": .progressiveRemux
        case "server_remux_hls": .hlsRemux
        case "server_transcode_hls": .hlsTranscode
        default: .other(delivery)
        }
        let recipe = effectiveRecipe.map {
            MediaEffectiveRecipe(videoCodec: $0.videoCodec, videoSampleEntry: $0.videoSampleEntry,
                                 segmentContainer: $0.segmentContainer, audioCodec: $0.audioCodec,
                                 width: $0.width, height: $0.height, frameRate: $0.frameRate,
                                 bitrateKbps: $0.bitrateKbps, dynamicRange: $0.dynamicRange,
                                 audioChannels: $0.audioChannels, audioLayout: $0.audioLayout)
        }
        let limit = bandwidthLimit.map {
            MediaBandwidthLimit(kbps: $0.kbps, source: $0.source,
                                expiresAt: ISO8601DateFormatter().date(from: $0.expiresAt))
        }
        return MediaNegotiatedStatus(
            delivery: transport,
            availableQualities: (availableQualities ?? []).map {
                MediaQuality(id: $0.label, displayName: $0.displayName, height: $0.height,
                             bitrateKbps: $0.bitrateKbps, preservesSource: $0.preservesSource)
            },
            activeQualityID: activeQuality,
            effectiveRecipe: recipe,
            decisionReason: decisionReason,
            degradationWarnings: (degradationWarnings ?? []).map { MediaDegradation(code: $0.code, message: $0.message) },
            bandwidthLimit: limit,
            headerRefreshURL: stream.headerRefreshUrl.flatMap(URL.init(string:))
        )
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion, planId, planAttemptKey, sessionId, delivery, expiresAt, stream, timeline
        case effectiveMediaFileId, selectedTracks, subtitle, source, availableQualities, activeQuality
        case effectiveRecipe, decisionReason, degradationWarnings, bandwidthLimit
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        planId = try values.decode(String.self, forKey: .planId)
        planAttemptKey = try values.decode(String.self, forKey: .planAttemptKey)
        sessionId = try values.decodeIfPresent(String.self, forKey: .sessionId)
        delivery = try values.decode(String.self, forKey: .delivery)
        expiresAt = try values.decodeIfPresent(String.self, forKey: .expiresAt)
        stream = try values.decode(SiloPlanStream.self, forKey: .stream)
        timeline = try values.decode(SiloPlanTimeline.self, forKey: .timeline)
        effectiveMediaFileId = try values.decode(SiloNativeFileID.self, forKey: .effectiveMediaFileId).value
        selectedTracks = try values.decode(SiloSelectedTracks.self, forKey: .selectedTracks)
        subtitle = try values.decode(SiloPlanSubtitle.self, forKey: .subtitle)
        source = try values.decode(SiloPlanSource.self, forKey: .source)
        availableQualities = try values.decodeIfPresent([SiloAvailableQuality].self, forKey: .availableQualities)
        activeQuality = try values.decodeIfPresent(String.self, forKey: .activeQuality)
        effectiveRecipe = try values.decodeIfPresent(SiloEffectiveRecipe.self, forKey: .effectiveRecipe)
        decisionReason = try values.decodeIfPresent(String.self, forKey: .decisionReason)
        degradationWarnings = try values.decodeIfPresent([SiloDegradationWarning].self, forKey: .degradationWarnings)
        bandwidthLimit = try values.decodeIfPresent(SiloBandwidthLimit.self, forKey: .bandwidthLimit)
    }
}

/// Native plans use integer file IDs; catalog versions use string identities.
/// Retain the historical string wire form for existing session fixtures.
private nonisolated struct SiloNativeFileID: Decodable, Sendable {
    let value: String

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let id = try? value.decode(Int.self), id > 0 {
            self.value = String(id)
        } else if let id = try? value.decode(String.self), !id.isEmpty,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.value = id
        } else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid native media file ID")
        }
    }
}

nonisolated struct SiloAvailableQuality: Decodable, Sendable {
    let label: String
    let displayName: String?
    let height: Int?
    let bitrateKbps: Int?
    let preservesSource: Bool
}

nonisolated struct SiloEffectiveRecipe: Decodable, Sendable {
    let videoCodec: String?
    let videoSampleEntry: String?
    let segmentContainer: String?
    let audioCodec: String?
    let width: Int?
    let height: Int?
    let frameRate: Double?
    let bitrateKbps: Int?
    let dynamicRange: String?
    let audioChannels: Int?
    let audioLayout: String?
}

nonisolated struct SiloDegradationWarning: Decodable, Sendable {
    let code: String
    let message: String
}

nonisolated struct SiloBandwidthLimit: Decodable, Sendable {
    let kbps: Int
    let source: String
    let expiresAt: String
}

nonisolated struct SiloPlanStream: Decodable, Sendable {
    let url: String
    let `protocol`: String
    let headers: [String: String]
    let headerRefresh: String
    let container: String?
    let headerRefreshUrl: String?
}

nonisolated struct SiloPlanTimeline: Decodable, Sendable {
    let sourceStartSeconds: Double
    let streamOriginSeconds: Double
    let playerStartSeconds: Double
    let timelineOffsetSeconds: Double
    let canSeekAnywhere: Bool
    let seekRestoration: String
}

nonisolated struct SiloSelectedTracks: Codable, Sendable {
    let audio: SiloTrackIdentity?
    let subtitle: SiloTrackIdentity?
}

nonisolated struct SiloTrackIdentity: Codable, Sendable, Equatable {
    let id: String
    let index: Int?
}

nonisolated struct SiloPlanSubtitle: Decodable, Sendable {
    let mode: String
    let trackId: String?
    let artifact: SiloSubtitleArtifact?
    let embedded: SiloEmbeddedSubtitle?
    let hlsRendition: SiloHLSSubtitleRendition?
    let inventory: [SiloPlanSubtitleTrack]
}

nonisolated struct SiloSubtitleArtifact: Decodable, Sendable {
    let url: String
    let mimeType: String
    let format: String
    let timingOriginSeconds: Double
}

nonisolated struct SiloEmbeddedSubtitle: Decodable, Sendable {
    let streamIndex: Int
    let containerTrackId: String?
}

nonisolated struct SiloHLSSubtitleRendition: Decodable, Sendable {
    let groupId: String
    let name: String
    let format: String
    let mimeType: String
}

nonisolated struct SiloPlanSubtitleTrack: Decodable, Sendable {
    let trackId: String
    let combinedIndex: Int
    let source: String
    let codec: String?
    let language: String?
    let label: String?
    let forced: Bool
    let `default`: Bool
    let hearingImpaired: Bool
    let delivery: String
    let url: String?
    let syncKey: String?

    /// Only the inventory may name a syncable target; embedded tracks are never syncable.
    func syncTarget(fileID: String) -> SiloSubtitleSyncTarget? {
        guard source == "external" || source == "downloaded",
              let syncKey, !syncKey.isEmpty else { return nil }
        return SiloSubtitleSyncTarget(fileID: fileID, key: syncKey)
    }

    /// This explicit server pin is a stored-row identity, not a sidecar sync key.
    var storedSubtitleID: String? {
        guard source == "downloaded", let url,
              let query = URLComponents(string: url)?.queryItems else { return nil }
        let pins = query.filter { $0.name == "downloaded_subtitle_id" }
        guard pins.count == 1, let id = pins[0].value, !id.isEmpty else { return nil }
        return id
    }
}

nonisolated struct SiloPlanSource: Decodable, Sendable {
    let mediaFileId: String
    let durationSeconds: Double?

    enum CodingKeys: String, CodingKey { case mediaFileId, durationSeconds }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mediaFileId = try values.decode(SiloNativeFileID.self, forKey: .mediaFileId).value
        durationSeconds = try values.decodeIfPresent(Double.self, forKey: .durationSeconds)
    }
}

nonisolated struct SiloPlaybackSession: Sendable {
    let installationID: String
    let sessionID: String
    let fileID: String
    let timelineOffset: Double
    let ref: MediaItemRef
    let request: SiloPlaybackStart
    let plan: SiloPlaybackPlan
    let lifetime: SiloPlaybackLifetime
    let relay: SiloMediaRelay
    var serverFeatures: [String] = []
    var isReplanning = false
}

nonisolated struct SiloPlaybackReplan: Encodable, Sendable {
    let installationId: String
    let protocolVersion = 3
    let playbackAttemptId: String
    let replanRequestId: String
    let failedPlanId: String
    let planAttemptId: String
    let planAttemptKey: String
    let attemptedPlanKeys: [String] = []
    let attemptCount = 1
    var qualityPreference: String = "auto"
    let positionSeconds: Double
    let selectedTracks: SiloSelectedTracks
    let clientCapabilities: SiloCodecCapabilities
    let clientPlaybackContext: SiloPlaybackContext
    var clientFeatures = ["playback_plan_v3", "sequenced_progress_v1", "plan_source_duration_v1", "embedded_subtitles_v1"]
    let bandwidthCapKbps: Int?
    var bandwidthEstimateKbps: Int?
    var bandwidthEstimateSource: String?
    var observedThroughputKbps: Int?
    var learnedLimit: String?
    let operation: String
    init(installationId: String, playbackAttemptId: String, replanRequestId: String,
         failedPlanId: String, planAttemptId: String, planAttemptKey: String,
         positionSeconds: Double, selectedTracks: SiloSelectedTracks,
         clientCapabilities: SiloCodecCapabilities, clientPlaybackContext: SiloPlaybackContext,
         bandwidthCapKbps: Int?, operation: String,
         qualityPreference: MediaQualityPreference = .automatic) {
        self.installationId = installationId
        self.playbackAttemptId = playbackAttemptId
        self.replanRequestId = replanRequestId
        self.failedPlanId = failedPlanId
        self.planAttemptId = planAttemptId
        self.planAttemptKey = planAttemptKey
        self.qualityPreference = qualityPreference.serverValue
        self.positionSeconds = positionSeconds
        self.selectedTracks = selectedTracks
        self.clientCapabilities = clientCapabilities
        self.clientPlaybackContext = clientPlaybackContext
        self.bandwidthCapKbps = bandwidthCapKbps
        self.operation = operation
    }

}

nonisolated struct SiloPlaybackMutation: Decodable, Sendable {
    let outcome: String
}

nonisolated struct SiloPlaybackProgress: Encodable, Sendable {
    let installationId: String
    let sequence: Int
    let position: Double
    let isPaused: Bool
}

nonisolated struct SiloPlaybackStop: Encodable, Sendable {
    let installationId: String
    let stopId: String
    let sequence: Int
    let position: Double
    let isPaused: Bool
}

/// Retires an unplayed plan without writing a fictitious zero resume sample.
nonisolated struct SiloPlaybackDiscard: Encodable, Sendable {
    let installationId: String
    let stopId: String
}

nonisolated struct SiloAudioPreference: Encodable, Sendable {
    let audioTrackIndex: Int
    let audioLanguage: String?
    let trackSignature: SiloAudioSignature
}

nonisolated struct SiloAudioSignature: Encodable, Sendable {
    let language: String?
    let codec: String?
    let channels: Int?
    let layout: String?
    let title: String?
    let embeddedTitle: String?
    let `default`: Bool
}

nonisolated struct SiloSubtitlePreference: Encodable, Sendable {
    let subtitleTrackIndex: Int
    let subtitleLanguage: String?
    let subtitleMode: String
    let externalSubtitlePath: String?
    let trackSignature: SiloSubtitleSignature?
}

nonisolated struct SiloProgressSyncBody: Encodable, Sendable {
    let items: [SiloProgressSyncItem]
}

nonisolated struct SiloProgressSyncItem: Encodable, Sendable {
    let mediaItemId: String
    let positionMs: Int64
    let durationMs: Int64
    let forceOverwrite = true
}

nonisolated struct SiloProgressSyncResult: Decodable, Sendable {
    let items: [SiloProgressSyncOutcome]
}

nonisolated struct SiloProgressSyncOutcome: Decodable, Sendable {
    let status: String
    let failure: SiloProgressSyncError?
}

nonisolated struct SiloProgressSyncError: Decodable, Sendable {
    let type: String
    let detail: String?
}
