//
//  MPVPlayerWrapper.swift
//  Rivulet
//
//  MPV-based video player implementing PlayerProtocol
//

import Foundation
import Combine
import UIKit
import Sentry

@MainActor
final class MPVPlayerWrapper: NSObject, PlayerProtocol, MPVPlayerDelegate {

    // MARK: - MPV Components

    private(set) var playerController: MPVMetalViewController?

    // MARK: - State

    private let playbackStateSubject = CurrentValueSubject<UniversalPlaybackState, Never>(.idle)
    private let timeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    private let errorSubject = PassthroughSubject<PlayerError, Never>()
    private let tracksSubject = PassthroughSubject<Void, Never>()

    private var _duration: TimeInterval = 0
    private var _audioTracks: [MediaTrack] = []
    private var _subtitleTracks: [MediaTrack] = []
    private var _currentAudioTrackId: Int?
    private var _currentSubtitleTrackId: Int?

    // MARK: - URL and Headers (for deferred loading)

    private var pendingURL: URL?
    private var pendingHeaders: [String: String]?
    private var pendingStartTime: TimeInterval?

    /// The URL that was actually loaded into MPV (preserved for error reporting)
    private var loadedURL: URL?

    // MARK: - Publishers

    var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> {
        playbackStateSubject.eraseToAnyPublisher()
    }

    var timePublisher: AnyPublisher<TimeInterval, Never> {
        timeSubject.eraseToAnyPublisher()
    }

    var errorPublisher: AnyPublisher<PlayerError, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    /// Fires when track lists are updated (audio/subtitle tracks available)
    var tracksPublisher: AnyPublisher<Void, Never> {
        tracksSubject.eraseToAnyPublisher()
    }

    // MARK: - Playback State

    var isPlaying: Bool {
        playerController?.isPlaying ?? false
    }

    var currentTime: TimeInterval {
        playerController?.currentTime ?? 0
    }

    var duration: TimeInterval {
        _duration
    }

    var bufferedTime: TimeInterval {
        // MPV doesn't expose buffered time easily
        0
    }

    var playbackRate: Float {
        get { playerController?.playbackRate ?? 1.0 }
        set { playerController?.playbackRate = newValue }
    }

    // MARK: - Track State

    var audioTracks: [MediaTrack] { _audioTracks }
    var subtitleTracks: [MediaTrack] { _subtitleTracks }
    var currentAudioTrackId: Int? { _currentAudioTrackId }
    var currentSubtitleTrackId: Int? { _currentSubtitleTrackId }

    // MARK: - Initialization

    override init() {
        super.init()
    }

    // MARK: - Playback Controls

    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?) async throws {
        playbackStateSubject.send(.loading)

        // Store for when controller is ready
        pendingURL = url
        pendingHeaders = headers
        pendingStartTime = startTime

        // If controller already exists, load directly
        if let controller = playerController {
            loadedURL = url  // Preserve for error reporting
            controller.httpHeaders = headers
            controller.startTime = startTime
            controller.loadFile(url)
        }
        // Otherwise, loading will happen when controller is set via setPlayerController
    }

    /// Called when the view creates the player controller
    func setPlayerController(_ controller: MPVMetalViewController) {
        self.playerController = controller
        controller.delegate = self

        // If we have a pending URL, load it now
        if let url = pendingURL {
            loadedURL = url  // Preserve for error reporting
            controller.httpHeaders = pendingHeaders
            controller.startTime = pendingStartTime
            controller.loadFile(url)
            pendingURL = nil
            pendingHeaders = nil
            pendingStartTime = nil
        }
    }

    func play() {
        playerController?.play()
    }

    func pause() {
        playerController?.pause()
    }

    func stop() {
        // Clear delegate first to prevent callbacks during shutdown
        playerController?.delegate = nil
        playerController?.stop()
        playerController = nil
        playbackStateSubject.send(.idle)
    }

    func seek(to time: TimeInterval) async {
        playerController?.seek(to: time)
        timeSubject.send(time)
    }

    func seekRelative(by seconds: TimeInterval) async {
        playerController?.seekRelative(by: seconds)
    }

    // MARK: - Track Management

    func selectAudioTrack(id: Int) {
        playerController?.selectAudioTrack(id)
        _currentAudioTrackId = id
    }

    func selectSubtitleTrack(id: Int?) {
        playerController?.selectSubtitleTrack(id)
        _currentSubtitleTrackId = id
    }

    func disableSubtitles() {
        playerController?.disableSubtitles()
        _currentSubtitleTrackId = nil
    }

    // MARK: - Audio Control

    var isMuted: Bool {
        playerController?.isMuted ?? false
    }

    func setMuted(_ muted: Bool) {
        playerController?.setMuted(muted)
    }

    // MARK: - Lifecycle

    func prepareForReuse() {
        stop()
        _audioTracks = []
        _subtitleTracks = []
        _currentAudioTrackId = nil
        _currentSubtitleTrackId = nil
        _duration = 0
        loadedURL = nil
        playbackStateSubject.send(.idle)
        timeSubject.send(0)
    }

    // MARK: - MPVPlayerDelegate

    func mpvPlayerDidChangeState(_ state: MPVPlayerState) {
        let universalState: UniversalPlaybackState
        switch state {
        case .idle:
            universalState = .idle
        case .loading:
            universalState = .loading
        case .playing:
            universalState = .playing
        case .paused:
            universalState = .paused
        case .buffering:
            universalState = .buffering
        case .ended:
            universalState = .ended
        case .error(let message):
            universalState = .failed(.unknown(message))
        }
        playbackStateSubject.send(universalState)
    }

    func mpvPlayerTimeDidChange(current: Double, duration: Double) {
        timeSubject.send(current)
        if duration > 0 {
            _duration = duration
        }
    }

    func mpvPlayerDidUpdateTracks(audio: [MPVTrack], subtitles: [MPVTrack]) {
        _audioTracks = audio.map { track in
            MediaTrack(
                id: track.id,
                name: track.displayName,
                language: track.language,
                languageCode: track.language,
                codec: track.codec,
                isDefault: track.isDefault,
                isForced: track.isForced,
                channels: track.channels
            )
        }

        _subtitleTracks = subtitles.map { track in
            MediaTrack(
                id: track.id,
                name: track.displayName,
                language: track.language,
                languageCode: track.language,
                codec: track.codec,
                isDefault: track.isDefault,
                isForced: track.isForced
            )
        }

        // Update selected track IDs
        _currentAudioTrackId = audio.first(where: { $0.isSelected })?.id
        _currentSubtitleTrackId = subtitles.first(where: { $0.isSelected })?.id

        // Notify subscribers that tracks are available
       // print("🎬 [MPV] Tracks updated: \(audio.count) audio, \(subtitles.count) subtitles")
        tracksSubject.send()
    }

    func mpvPlayerDidEncounterError(_ message: String) {
        errorSubject.send(.unknown(message))

        // Capture playback error to Sentry with context
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "MPV Playback Error: \(message)")
        event.extra = [
            "error_message": message,
            "stream_url": loadedURL?.absoluteString ?? "none",
            "stream_host": loadedURL?.host ?? "unknown",
            "stream_path": loadedURL?.path ?? "unknown",
            "has_controller": playerController != nil,
            "duration": _duration,
            "current_time": playerController?.currentTime ?? 0
        ]
        event.tags = [
            "component": "mpv_player",
            "stream_host": loadedURL?.host ?? "unknown"
        ]

        // Fingerprint by error type so different MPV errors create separate issues
        let errorCategory = categorizeMPVError(message)
        event.fingerprint = ["mpv", errorCategory]

        SentrySDK.capture(event: event)
    }

    /// Categorizes MPV error messages for Sentry fingerprinting
    private func categorizeMPVError(_ message: String) -> String {
        let lowercased = message.lowercased()

        if lowercased.contains("loading failed") {
            return "loading-failed"
        } else if lowercased.contains("unrecognized file format") || lowercased.contains("unknown format") {
            return "unrecognized-format"
        } else if lowercased.contains("network") || lowercased.contains("connection") {
            return "network-error"
        } else if lowercased.contains("demuxer") {
            return "demuxer-error"
        } else if lowercased.contains("codec") || lowercased.contains("decode") {
            return "codec-error"
        } else if lowercased.contains("audio") {
            return "audio-error"
        } else if lowercased.contains("video") {
            return "video-error"
        } else {
            return "unknown"
        }
    }
}
