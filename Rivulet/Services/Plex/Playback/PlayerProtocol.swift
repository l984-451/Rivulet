// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerProtocol.swift
//  Rivulet
//
//  Shared playback contract used by RivuletPlayer and its view model integration.
//

import Foundation
import Combine

// MARK: - Playback State

enum UniversalPlaybackState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case buffering
    case ended
    case failed(PlayerError)

    var isActive: Bool {
        switch self {
        case .playing, .paused, .buffering:
            return true
        default:
            return false
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Stable short label for the Sentry App Hang `playback_state` tag
    /// (RIVULET-41). No associated values so it stays low-cardinality.
    var appHangLabel: String {
        switch self {
        case .idle: return "idle"
        case .loading: return "loading"
        case .ready: return "ready"
        case .playing: return "playing"
        case .paused: return "paused"
        case .buffering: return "buffering"
        case .ended: return "ended"
        case .failed: return "failed"
        }
    }
}

// MARK: - Player Error

enum PlayerError: Error, Equatable, Sendable {
    case invalidURL
    case loadFailed(String)
    case networkError(String)
    case codecUnsupported(String)
    case unknown(String)
    /// A failure AetherEngine classified for us (`PlaybackErrorInfo`).
    ///
    /// `kind` is the engine's `PlaybackErrorKind.rawValue`, which upstream
    /// documents as API and stable across releases, so it is safe to switch on
    /// and safe to ship straight into a Sentry tag. It is carried as a String
    /// rather than mirrored into a host enum because the engine's set is open
    /// by design: it grows on minor releases, and an unlisted kind has to ride
    /// through to telemetry intact rather than collapse to "unknown" the way
    /// the substring rules below do. Only the kinds that change what the user
    /// should do are named anywhere in this file.
    ///
    /// `message` is the same text `PlaybackState.error` carries. On the native
    /// paths it is `AVPlayerItem.error.localizedDescription`, so it is in the
    /// device's language and cannot be pattern-matched: that is precisely why
    /// `kind` exists.
    case engineFailure(kind: String, message: String)

    /// Technical description for logging and Sentry - includes internal details
    var technicalDescription: String {
        switch self {
        case .invalidURL:
            return "Invalid media URL"
        case .loadFailed(let message):
            return "Failed to load media: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .codecUnsupported(let codec):
            return "Unsupported codec: \(codec)"
        case .unknown(let message):
            return "Playback error: \(message)"
        case .engineFailure(let kind, let message):
            return "Playback error [\(kind)]: \(message)"
        }
    }

    /// User-friendly description shown in the UI
    var userFacingDescription: String {
        switch self {
        case .invalidURL:
            return "This video couldn't be played. The link may be invalid."
        case .loadFailed(let message):
            if message.contains("HLS transcode session failed") {
                return "Your Plex server is taking too long to prepare the video. Please try again."
            } else if message.contains("transcode") {
                return "Your server couldn't prepare this video for playback. It may be busy with other streams."
            } else if message.contains("CoreMediaErrorDomain") || message.contains("-16172") {
                return "The stream from your server couldn't be played. The server may still be preparing the video."
            } else if message.contains("loading failed") {
                return "The stream couldn't be loaded. Check that your server is running and reachable."
            }
            return "This video couldn't be loaded. Please check your connection and try again."
        case .networkError:
            return "Couldn't connect to the server. Please check your network connection."
        case .codecUnsupported:
            return "This video format isn't supported on this device."
        case .unknown(let message):
            if message.contains("CoreMediaErrorDomain") || message.contains("-16172") {
                return "The stream from your server couldn't be played. The server may still be preparing the video."
            }
            return "Something went wrong during playback. Please try again."
        case .engineFailure(let kind, _):
            // Only the kinds that change what the user should DO get their own
            // sentence. Everything else reads the same as any other playback
            // failure, because to the viewer it is one.
            switch kind {
            case EngineFailureKind.sourceRateLimited:
                return "Your server is refusing new streams right now. Wait a moment and try again."
            case EngineFailureKind.sourceRefused:
                return "Your server refused this video. It may have moved, or your access to it may have changed."
            case EngineFailureKind.dolbyVisionRequiresHardware:
                return "This Dolby Vision file has no fallback layer this Apple TV can decode."
            default:
                return "This video couldn't be played. Please try again."
            }
        }
    }

    /// AetherEngine's own classification of this failure, when it has one.
    /// Nil for every error the host authored, which is what keeps it honest as
    /// a Sentry tag: present means the engine said so.
    var engineKind: String? {
        if case .engineFailure(let kind, _) = self { return kind }
        return nil
    }

    /// Whether the user should be offered a retry option
    var isRetryable: Bool {
        switch self {
        case .loadFailed, .networkError, .unknown:
            return true
        case .invalidURL, .codecUnsupported:
            return false
        case .engineFailure(let kind, _):
            // A hardware decode limit is the one class retrying cannot move.
            // Rate limiting is retryable on purpose: the engine's own note on
            // that kind is that the same request is expected to work later.
            return kind != EngineFailureKind.dolbyVisionRequiresHardware
        }
    }

    /// For Error protocol conformance - uses technical description
    var localizedDescription: String {
        technicalDescription
    }
}

// MARK: - Engine failure kinds

/// The `PlaybackErrorKind` raw values Rivulet actually branches on.
///
/// AetherEngine publishes ~20 of these and adds more on minor releases. Naming
/// the full set here would be a mirror that goes stale silently; naming only
/// the ones we react to keeps the staleness visible, because an unlisted kind
/// simply takes a default arm rather than disappearing.
///
/// These strings are AetherEngine's API surface. Do not "tidy" the spelling.
enum EngineFailureKind {
    /// Origin answered 429/503/509. The source is not gone and the same
    /// request is expected to work later, so this must not be treated as a
    /// dead source.
    static let sourceRateLimited = "sourceRateLimited"
    /// Origin answered an HTTP status instead of media (401/403/404/5xx).
    /// `underlyingCode` carries that status. Before AetherEngine 6.29.0 this
    /// and a genuinely corrupt file both arrived as `sourceOpenFailed` with
    /// FFmpeg's "Invalid data found when processing input", which is the whole
    /// reason RIVULET-19 could not be split.
    static let sourceRefused = "sourceRefused"
    /// The source could not be opened, probed or routed. Post-6.29.0 this is
    /// the genuinely-unreadable half of what RIVULET-19 used to be.
    static let sourceOpenFailed = "sourceOpenFailed"
    /// Dolby Vision with no base layer the software path can decode.
    static let dolbyVisionRequiresHardware = "dolbyVisionRequiresHardware"
    /// A live probe that burned its whole reconnect budget without opening.
    static let liveSourceUnavailable = "liveSourceUnavailable"
    /// `AVPlayerItem` reached `.failed`; domain/code classify it, not the text.
    static let nativeItemFailed = "nativeItemFailed"
    /// The audio bridge produced no encoded audio, so the first segment cut
    /// failed. Upstream's note: a host with a fallback ladder should DEMOTE on
    /// this one rather than end the ladder, which is what our HLS fallback
    /// already does.
    static let audioBridgeProducedNoOutput = "audioBridgeProducedNoOutput"
    /// The software decode pipeline failed.
    static let softwarePipelineFailed = "softwarePipelineFailed"
}

// MARK: - Player Protocol

/// Shared playback interface for the app's video pipeline.
@MainActor
protocol PlayerProtocol: AnyObject {
    // MARK: - Playback State
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var bufferedTime: TimeInterval { get }
    var playbackRate: Float { get set }

    // MARK: - State Publishers
    var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> { get }
    var timePublisher: AnyPublisher<TimeInterval, Never> { get }
    var errorPublisher: AnyPublisher<PlayerError, Never> { get }

    // MARK: - Playback Controls
    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?) async throws
    func play()
    func pause()
    func stop()
    func seek(to time: TimeInterval) async
    func seekRelative(by seconds: TimeInterval) async

    // MARK: - Track Management
    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    var currentAudioTrackId: Int? { get }
    var currentSubtitleTrackId: Int? { get }
    func selectAudioTrack(id: Int)
    func selectSubtitleTrack(id: Int?)
    func disableSubtitles()

    // MARK: - Lifecycle
    func prepareForReuse()
}

// MARK: - Default Implementations

extension PlayerProtocol {
    func seekRelative(by seconds: TimeInterval) async {
        let newTime = max(0, min(currentTime + seconds, duration))
        await seek(to: newTime)
    }

    func disableSubtitles() {
        selectSubtitleTrack(id: nil)
    }

    func load(url: URL, startTime: TimeInterval?) async throws {
        try await load(url: url, headers: nil, startTime: startTime)
    }
}
