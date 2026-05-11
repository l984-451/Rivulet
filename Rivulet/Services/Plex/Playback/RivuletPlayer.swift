//
//  RivuletPlayer.swift
//  Rivulet
//
//  Unified custom video player built on AVSampleBufferDisplayLayer + VideoToolbox.
//  Handles all content types through two internal pipelines:
//
//    - DirectPlayPipeline: FFmpeg demuxes containers (MKV/MP4), VideoToolbox decodes
//    - HLSPipeline: For DTS/TrueHD (server transcodes audio) and live TV
//
//  Conforms to PlayerProtocol for seamless integration with UniversalPlayerViewModel.
//

#if !RIVULET_FFMPEG
import Foundation
import AVFoundation
import Combine
// Stub so code compiles on simulator. Never used for actual playback.
@MainActor final class RivuletPlayer: ObservableObject, PlayerProtocol {
    let renderer = SampleBufferRenderer()
    var isPlaying: Bool { false }
    var currentTime: TimeInterval { 0 }
    var duration: TimeInterval { 0 }
    var bufferedTime: TimeInterval { 0 }
    var playbackRate: Float = 1.0
    var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> { Just(.idle).eraseToAnyPublisher() }
    var timePublisher: AnyPublisher<TimeInterval, Never> { Just(0).eraseToAnyPublisher() }
    var errorPublisher: AnyPublisher<PlayerError, Never> { Empty().eraseToAnyPublisher() }
    var audioTracks: [MediaTrack] { [] }
    var subtitleTracks: [MediaTrack] { [] }
    var currentAudioTrackId: Int? { nil }
    var currentSubtitleTrackId: Int? { nil }
    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?) async throws {}
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to time: TimeInterval) async {}
    func seekRelative(by seconds: TimeInterval) async {}
    func selectAudioTrack(id: Int) {}
    func selectSubtitleTrack(id: Int?) {}
    func disableSubtitles() {}
    func setMuted(_ muted: Bool) {}
    func prepareForReuse() {}
    func load(route: PlaybackRoute, startTime: TimeInterval?) async throws {}
    enum ActivePipeline { case directPlay, hls }
    var activePipeline: ActivePipeline? { nil }
    var displayLayer: AVSampleBufferDisplayLayer { renderer.displayLayer }
    var onSubtitleCue: ((String, TimeInterval, TimeInterval) -> Void)?
    var onBitmapSubtitleCue: ((BitmapSubtitleCue) -> Void)?
    func loadHLSWithConversion(url: URL, headers: [String: String]?, startTime: TimeInterval?, requiresProfileConversion: Bool) async throws {}
    func selectAudioTrack(plexTrackId: Int, plexAudioTracks: [MediaTrack]) {}
    func selectEmbeddedSubtitle(streamIndex: Int32) {}
    func selectEmbeddedSubtitle(plexTrackId: Int, plexSubtitleTracks: [MediaTrack]) -> Bool { false }
    func deselectEmbeddedSubtitle() {}
    var ffmpegSubtitleTracks: [(streamIndex: Int32, language: String?, title: String?, codec: String?)] { [] }
}
#else
import Foundation
import AVFoundation
import Combine
import CoreMedia

/// Unified player using AVSampleBufferDisplayLayer for all content.
@MainActor
final class RivuletPlayer: ObservableObject {

    // MARK: - Rendering Layer (public for view binding)

    let renderer = SampleBufferRenderer()

    /// The display layer for embedding in a SwiftUI view
    var displayLayer: AVSampleBufferDisplayLayer { renderer.displayLayer }

    // MARK: - Publishers

    private let playbackStateSubject = CurrentValueSubject<UniversalPlaybackState, Never>(.idle)
    private let timeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    private let errorSubject = PassthroughSubject<PlayerError, Never>()
    private let tracksSubject = PassthroughSubject<Void, Never>()

    var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> {
        playbackStateSubject.eraseToAnyPublisher()
    }
    var timePublisher: AnyPublisher<TimeInterval, Never> {
        timeSubject.eraseToAnyPublisher()
    }
    var errorPublisher: AnyPublisher<PlayerError, Never> {
        errorSubject.eraseToAnyPublisher()
    }
    var tracksPublisher: AnyPublisher<Void, Never> {
        tracksSubject.eraseToAnyPublisher()
    }

    // MARK: - Playback State

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var bufferedTime: TimeInterval = 0
    var playbackRate: Float = 1.0
    /// True once the pipeline has actually transitioned to .running for the
    /// first time. Used to distinguish initial-load .loading events (which
    /// arrive on a delayed @MainActor task and must NOT be turned into
    /// .buffering) from real mid-playback buffer underruns.
    private var hasStartedPlayback = false

    // MARK: - Track Info

    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var currentAudioTrackId: Int?
    private(set) var currentSubtitleTrackId: Int?

    // MARK: - Active Pipeline

    /// Which pipeline is currently handling playback
    enum ActivePipeline {
        case none
        case directPlay
        case hls
    }

    private(set) var activePipeline: ActivePipeline = .none
    private var directPlayPipeline: DirectPlayPipeline?
    private var hlsPipeline: HLSPipeline?

    // MARK: - Private State

    private var timeObserverTask: Task<Void, Never>?
    private var streamURL: URL?
    private var loadHeaders: [String: String]?
    private var pipelineGeneration: UInt64 = 0
    private var routeChangeObserver: NSObjectProtocol?
    private var isAudioRecoveryInFlight = false
    private var lastAudioRecoveryRequestWallTime: CFAbsoluteTime = 0
    private var lastRecordedRendererFailureWallTime: CFAbsoluteTime = 0
    private var autoFlushEventTimes: [CFAbsoluteTime] = []
    private var outputConfigRecoveryEventTimes: [CFAbsoluteTime] = []
    private var rendererFailureEventTimes: [CFAbsoluteTime] = []
    private var hasReportedAirPlayInstability = false
    private var airPlayStabilityFallbackToStereo = false
    private var isAirPlayStabilityFallbackInFlight = false
    private var loadedDirectPlayIsDolbyVision = false
    private var loadedDirectPlayEnableDVConversion = false
    private let airPlayInstabilityWindow: CFAbsoluteTime = 20.0

    // MARK: - Init

    init() {
        configureRendererCallbacks()
        observeRouteChanges()
    }

    deinit {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    // MARK: - Load (PlayerProtocol)

    /// Load a URL for playback. This is the simple PlayerProtocol entry point.
    /// For routed playback (direct play vs HLS), use `load(route:...)` instead.
    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?) async throws {
        playerDebugLog("[RivuletPlayer] load(url:) → HLS path: \(url.lastPathComponent)")
        hasStartedPlayback = false
        resetAirPlayRouteOverrides()
        try await loadHLS(url: url, headers: headers, startTime: startTime)
    }

    /// Load an HLS URL with optional DV profile conversion.
    /// Used when the ViewModel knows the content needs RPU conversion (P7/P8.6).
    func loadHLSWithConversion(url: URL, headers: [String: String]?, startTime: TimeInterval?, requiresProfileConversion: Bool) async throws {
        playerDebugLog("[RivuletPlayer] loadHLS: \(url.lastPathComponent) profileConversion=\(requiresProfileConversion)")
        hasStartedPlayback = false
        playbackStateSubject.send(.loading)
        resetAirPlayRouteOverrides()
        PlaybackAudioSessionConfigurator.activatePlaybackSession(
            mode: .moviePlayback,
            owner: "[RivuletPlayer]"
        )
        try await loadHLS(url: url, headers: headers, startTime: startTime, requiresProfileConversion: requiresProfileConversion)
    }

    // MARK: - Routed Load

    /// Load using a content routing decision.
    /// - Parameters:
    ///   - route: The routing decision (directPlay or hls)
    ///   - startTime: Optional resume position
    ///   - isDolbyVision: Whether Plex metadata confirms DV content (forces dvh1 tagging)
    ///   - enableDVConversion: Enable DV P7/P8.6 → P8.1 conversion
    func load(route: PlaybackRoute, startTime: TimeInterval?, isDolbyVision: Bool = false, enableDVConversion: Bool = false) async throws {
        hasStartedPlayback = false
        isPlaying = false
        playbackStateSubject.send(.loading)
        resetAirPlayRouteOverrides()

        // Configure audio session
        PlaybackAudioSessionConfigurator.activatePlaybackSession(
            mode: .moviePlayback,
            owner: "[RivuletPlayer]"
        )

        switch route {
        case .avPlayerDirect(let url, let headers):
            playerDebugLog("[RivuletPlayer] load(route:) → DirectPlay: \(url.lastPathComponent) DV=\(isDolbyVision)")
            try await loadDirectPlay(url: url, headers: headers, startTime: startTime, isDolbyVision: isDolbyVision, enableDVConversion: enableDVConversion)

        case .localRemux(let url, let headers, let analysis):
            let dv = isDolbyVision || analysis.needsDVConversion
            let conversion = enableDVConversion || analysis.needsDVConversion
            playerDebugLog("[RivuletPlayer] load(route:) → DirectPlay: \(url.lastPathComponent) DV=\(dv) conversion=\(conversion)")
            try await loadDirectPlay(url: url, headers: headers, startTime: startTime, isDolbyVision: dv, enableDVConversion: conversion)

        case .hls(let url, let headers):
            playerDebugLog("[RivuletPlayer] load(route:) → HLS: \(url.lastPathComponent)")
            try await loadHLS(url: url, headers: headers, startTime: startTime, requiresProfileConversion: enableDVConversion)
        }
    }

    // MARK: - Private: Audio Policy + Recovery

    private enum AirPlayInstabilityEvent {
        case autoFlush
        case outputRecovery
        case rendererFailure
    }

    private func configureRendererCallbacks() {
        renderer.onAudioRendererFlushedAutomatically = { [weak self] flushTime in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleAudioRendererAutoFlush(flushTime: flushTime)
            }
        }

        renderer.onAudioOutputConfigurationChanged = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleAudioOutputConfigurationChange()
            }
        }

        // When the video sink swaps (AVSBL ⇄ Metal), force any SwiftUI views
        // bound to this player to re-render so SampleBufferDisplayView picks
        // up the new metal renderer's UIView.
        renderer.onVideoSinkChanged = { [weak self] in
            self?.objectWillChange.send()
        }
    }

    private func observeRouteChanges() {
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleSystemRouteChange(notification)
            }
        }
    }

    private func handleSystemRouteChange(_ notification: Notification) async {
        let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = reasonValue
            .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            .map { "\($0.rawValue)" } ?? "unknown"

        _ = applyCurrentAudioPolicy(reason: "route_change_\(reason)")
        await recoverAudioFromRendererEvent(afterFlushTime: .invalid, reason: "route_change_\(reason)")
    }

    private func handleAudioRendererAutoFlush(flushTime: CMTime) async {
        _ = applyCurrentAudioPolicy(reason: "audio_renderer_auto_flush")
        // Always handle auto-flush, even during pause. Per Apple's
        // SampleBufferPlayer sample code, auto-flush must trigger a full
        // restart — the renderer's internal AirPlay transport is
        // invalidated and will silently discard audio on resume if
        // not recovered. The recovery (seek-to-flush-time) is safe
        // during pause because seek handles the paused state.
        let instabilityHandled = recordAirPlayInstabilityEvent(.autoFlush)
        if instabilityHandled { return }
        await recoverAudioFromRendererEvent(afterFlushTime: flushTime, reason: "audio_renderer_auto_flush")
    }

    private func handleAudioOutputConfigurationChange() async {
        _ = applyCurrentAudioPolicy(reason: "audio_output_configuration_changed")
        guard isPlaying else { return }
        let instabilityHandled = recordAirPlayInstabilityEvent(.outputRecovery)
        if instabilityHandled { return }
        await recoverAudioFromRendererEvent(afterFlushTime: .invalid, reason: "audio_output_configuration_changed")
    }

    @discardableResult
    private func applyCurrentAudioPolicy(reason: String) -> RouteAudioSnapshot {
        let snapshot = PlaybackAudioSessionConfigurator.currentRouteAudioSnapshot(
            owner: "RivuletPlayer",
            reason: reason
        )
        applyAudioPolicy(snapshot: snapshot, reason: reason)
        return snapshot
    }

    private func applyAudioPolicy(snapshot: RouteAudioSnapshot, reason: String) {
        let defaultPolicy = PlaybackAudioSessionConfigurator.recommendedAudioPolicy(for: snapshot)
        let policy = airPlayStabilityFallbackToStereo
            ? PlaybackAudioSessionConfigurator.stabilityFallbackAudioPolicy(for: snapshot)
            : defaultPolicy
        let basePolicyReason = PlaybackAudioSessionConfigurator.policyDecisionReason(for: snapshot)
        let policyReason = airPlayStabilityFallbackToStereo
            ? "airplay_stability_fallback:\(basePolicyReason)"
            : basePolicyReason
        renderer.useAudioPullMode = policy.useAudioPullMode
        renderer.minimumAudioPullStartBuffer = policy.audioPullStartBufferDuration
        renderer.minimumAudioPullResumeBuffer = policy.audioPullResumeBufferDuration

        if let directPlayPipeline {
            directPlayPipeline.targetOutputSampleRate = policy.targetOutputSampleRate
            directPlayPipeline.preferAudioEngineForPCM = policy.preferAudioEngineForPCM
            directPlayPipeline.forceClientDecodeAllAudio = policy.forceClientDecodeAllAudio
            directPlayPipeline.forceClientDecodeCodecs = policy.forceClientDecodeCodecs
            directPlayPipeline.enableSurroundReEncoding = policy.enableSurroundReEncoding
            directPlayPipeline.useSignedInt16Audio = policy.useSignedInt16Audio
            directPlayPipeline.forceDownmixToStereo = policy.forceDownmixToStereo
        }
        renderer.audioBackpressureMaxWait = policy.audioBackpressureMaxWait

        // AirPlay A/V sync: no explicit video delay needed.
        // AVSampleBufferRenderSynchronizer + AVSampleBufferAudioRenderer handle
        // AirPlay latency automatically via the delaysRateChangeUntilHasSufficientMediaData
        // preroll mechanism. The synchronizer's currentTime tracks what's being heard
        // at the AirPlay receiver, so video displayed at currentTime is in sync.
        // Confirmed by WWDC22 Apple guidance and empirical testing (drift < 50ms).

        playerDebugLog(
            "[RivuletPlayer] AudioPolicy reason=\(reason) " +
            "profile=\(policy.profile.rawValue) airPlay=\(snapshot.isAirPlay) " +
            "decision=\(policyReason) " +
            "multichannelAirPlay=\(snapshot.isLikelyMultichannelAirPlay) " +
            "pullMode=\(policy.useAudioPullMode) " +
            "pullStart=\(String(format: "%.2f", policy.audioPullStartBufferDuration))s " +
            "pullResume=\(String(format: "%.2f", policy.audioPullResumeBufferDuration))s " +
            "audioEngine=\(policy.preferAudioEngineForPCM) " +
            "forceDecodeAll=\(policy.forceClientDecodeAllAudio) " +
            "forceDecode=\(policy.forceClientDecodeCodecs.sorted().joined(separator: ",")) " +
            "reencode=\(policy.enableSurroundReEncoding) " +
            "downmix=\(policy.forceDownmixToStereo) s16=\(policy.useSignedInt16Audio) " +
            "backpressure=\(String(format: "%.2f", policy.audioBackpressureMaxWait))s " +
            "maxOutCh=\(snapshot.maximumOutputChannels) " +
            "targetRate=\(policy.targetOutputSampleRate > 0 ? "\(policy.targetOutputSampleRate)Hz" : "native")"
        )
    }

    private func recoverAudioFromRendererEvent(afterFlushTime flushTime: CMTime, reason: String) async {
        guard activePipeline != .none else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if isAudioRecoveryInFlight {
            playerDebugLog("[RivuletPlayer] Skipping audio recovery (\(reason)) — already in flight")
            return
        }
        if now - lastAudioRecoveryRequestWallTime < 0.2 {
            playerDebugLog("[RivuletPlayer] Debouncing audio recovery (\(reason))")
            return
        }
        lastAudioRecoveryRequestWallTime = now
        isAudioRecoveryInFlight = true
        defer { isAudioRecoveryInFlight = false }

        do {
            switch activePipeline {
            case .directPlay:
                try await directPlayPipeline?.recoverAudio(afterFlushTime: flushTime, reason: reason)
            case .hls:
                await hlsPipeline?.recoverAudio(afterFlushTime: flushTime, reason: reason)
            case .none:
                break
            }
        } catch {
            playerDebugLog("[RivuletPlayer] Audio recovery failed (\(reason)): \(error.localizedDescription)")
            handlePipelineError(error)
        }
    }

    private func resetAirPlayInstabilityState() {
        autoFlushEventTimes.removeAll(keepingCapacity: false)
        outputConfigRecoveryEventTimes.removeAll(keepingCapacity: false)
        rendererFailureEventTimes.removeAll(keepingCapacity: false)
        hasReportedAirPlayInstability = false
        lastRecordedRendererFailureWallTime = 0
    }

    private func resetAirPlayRouteOverrides() {
        airPlayStabilityFallbackToStereo = false
        isAirPlayStabilityFallbackInFlight = false
        loadedDirectPlayIsDolbyVision = false
        loadedDirectPlayEnableDVConversion = false
    }

    @discardableResult
    private func recordAirPlayInstabilityEvent(_ event: AirPlayInstabilityEvent) -> Bool {
        guard PlaybackAudioSessionConfigurator.isAirPlayRouteActive() else { return false }
        let now = CFAbsoluteTimeGetCurrent()

        switch event {
        case .autoFlush:
            autoFlushEventTimes.append(now)
        case .outputRecovery:
            outputConfigRecoveryEventTimes.append(now)
        case .rendererFailure:
            rendererFailureEventTimes.append(now)
        }

        pruneAirPlayInstabilityEvents(now: now)
        return evaluateAirPlayInstabilityIfNeeded(trigger: event)
    }

    private func pruneAirPlayInstabilityEvents(now: CFAbsoluteTime) {
        let cutoff = now - airPlayInstabilityWindow
        autoFlushEventTimes.removeAll(where: { $0 < cutoff })
        outputConfigRecoveryEventTimes.removeAll(where: { $0 < cutoff })
        rendererFailureEventTimes.removeAll(where: { $0 < cutoff })
    }

    @discardableResult
    private func evaluateAirPlayInstabilityIfNeeded(trigger: AirPlayInstabilityEvent) -> Bool {
        guard !hasReportedAirPlayInstability else { return true }
        guard activePipeline == .directPlay else { return false }
        guard PlaybackAudioSessionConfigurator.isAirPlayRouteActive() else { return false }

        let autoFlushCount = autoFlushEventTimes.count
        let outputRecoveryCount = outputConfigRecoveryEventTimes.count
        let rendererFailureCount = rendererFailureEventTimes.count
        let totalCount = autoFlushCount + outputRecoveryCount + rendererFailureCount

        if shouldAttemptAirPlayStabilityFallback(
            autoFlushCount: autoFlushCount,
            outputRecoveryCount: outputRecoveryCount,
            rendererFailureCount: rendererFailureCount,
            totalCount: totalCount
        ) {
            airPlayStabilityFallbackToStereo = true

            let triggerLabel: String
            switch trigger {
            case .autoFlush: triggerLabel = "auto_flush"
            case .outputRecovery: triggerLabel = "output_recovery"
            case .rendererFailure: triggerLabel = "renderer_failure"
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.attemptAirPlayStabilityFallback(triggerLabel: triggerLabel)
            }
            return true
        }

        let isUnstable = autoFlushCount >= 3 || outputRecoveryCount >= 3 || rendererFailureCount >= 2 || totalCount >= 5
        guard isUnstable else { return false }

        hasReportedAirPlayInstability = true
        let error = PlayerError.loadFailed("AirPlay audio unstable")
        isPlaying = false
        playbackStateSubject.send(.failed(error))
        errorSubject.send(error)

        let triggerLabel: String
        switch trigger {
        case .autoFlush: triggerLabel = "auto_flush"
        case .outputRecovery: triggerLabel = "output_recovery"
        case .rendererFailure: triggerLabel = "renderer_failure"
        }

        playerDebugLog(
            "[RivuletPlayer] AirPlay instability detected (trigger=\(triggerLabel), " +
            "autoFlush=\(autoFlushCount), outputRecoveries=\(outputRecoveryCount), rendererFailures=\(rendererFailureCount))"
        )
        return true
    }

    private func shouldAttemptAirPlayStabilityFallback(
        autoFlushCount: Int,
        outputRecoveryCount: Int,
        rendererFailureCount: Int,
        totalCount: Int
    ) -> Bool {
        guard !airPlayStabilityFallbackToStereo else { return false }
        guard !isAirPlayStabilityFallbackInFlight else { return false }

        let snapshot = PlaybackAudioSessionConfigurator.currentRouteAudioSnapshot(
            owner: "RivuletPlayer",
            reason: "airplay_stability_eval"
        )
        let defaultPolicy = PlaybackAudioSessionConfigurator.recommendedAudioPolicy(for: snapshot)
        let fallbackPolicy = PlaybackAudioSessionConfigurator.stabilityFallbackAudioPolicy(for: snapshot)
        guard defaultPolicy != fallbackPolicy else { return false }

        return rendererFailureCount >= 1 || autoFlushCount >= 2 || outputRecoveryCount >= 2 || totalCount >= 3
    }

    private func attemptAirPlayStabilityFallback(triggerLabel: String) async {
        guard !isAirPlayStabilityFallbackInFlight else { return }
        guard activePipeline == .directPlay else { return }
        guard let url = streamURL else { return }

        isAirPlayStabilityFallbackInFlight = true
        defer { isAirPlayStabilityFallbackInFlight = false }

        let resumeTime = max(0, renderer.currentTime)
        let shouldResume = isPlaying
        let headers = loadHeaders
        isPlaying = false
        playbackStateSubject.send(.buffering)

        playerDebugLog(
            "[RivuletPlayer] Attempting AirPlay stability fallback " +
            "(trigger=\(triggerLabel), resume=\(String(format: "%.3f", resumeTime))s)"
        )

        do {
            try await loadDirectPlay(
                url: url,
                headers: headers,
                startTime: resumeTime,
                isDolbyVision: loadedDirectPlayIsDolbyVision,
                enableDVConversion: loadedDirectPlayEnableDVConversion
            )
            if shouldResume {
                play()
            }
        } catch {
            airPlayStabilityFallbackToStereo = false
            playerDebugLog("[RivuletPlayer] AirPlay stability fallback failed: \(error.localizedDescription)")
            handlePipelineError(error)
        }
    }

    // MARK: - Private: Load Implementations

    private func loadDirectPlay(url: URL, headers: [String: String]?, startTime: TimeInterval?, isDolbyVision: Bool = false, enableDVConversion: Bool) async throws {
        invalidatePipelineGeneration()
        let generation = pipelineGeneration
        await cleanupPipelinesAsync()

        let pipeline = DirectPlayPipeline(renderer: renderer)
        self.directPlayPipeline = pipeline
        self.activePipeline = .directPlay
        self.streamURL = url
        self.loadHeaders = headers
        self.loadedDirectPlayIsDolbyVision = isDolbyVision
        self.loadedDirectPlayEnableDVConversion = enableDVConversion
        resetAirPlayInstabilityState()
        let routeSnapshot = applyCurrentAudioPolicy(reason: "direct_play_load_preflight")

        // Wire callbacks
        pipeline.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.pipelineGeneration == generation else { return }
                self.handlePipelineStateChange(state)
            }
        }
        pipeline.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.pipelineGeneration == generation else { return }
                self.handlePipelineError(error)
            }
        }
        pipeline.onEndOfStream = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.pipelineGeneration == generation else { return }
                self.handleEndOfStream()
            }
        }

        try await pipeline.load(url: url, headers: headers, startTime: startTime, isDolbyVision: isDolbyVision, enableDVConversion: enableDVConversion)

        playerDebugLog(
            "[RivuletPlayer] DirectPlay startup route: airPlay=\(routeSnapshot.isAirPlay) " +
            "maxOutCh=\(routeSnapshot.maximumOutputChannels) sampleRate=\(String(format: "%.0f", routeSnapshot.sampleRate))"
        )

        // Update state from pipeline
        self.duration = pipeline.duration
        self.audioTracks = pipeline.audioTracks
        self.subtitleTracks = pipeline.subtitleTracks
        if let firstAudio = audioTracks.first {
            currentAudioTrackId = firstAudio.id
        }
        tracksSubject.send()

        // Don't send .ready — keep .loading visible until play() sends .playing.
        // This prevents a brief black flash between loading screen hide and first video frame.
        startTimeObserver()
    }

    private func loadHLS(url: URL, headers: [String: String]?, startTime: TimeInterval?, requiresProfileConversion: Bool = false) async throws {
        invalidatePipelineGeneration()
        let generation = pipelineGeneration
        await cleanupPipelinesAsync()

        let pipeline = HLSPipeline(renderer: renderer)
        self.hlsPipeline = pipeline
        self.activePipeline = .hls
        self.streamURL = url
        self.loadHeaders = headers
        self.loadedDirectPlayIsDolbyVision = false
        self.loadedDirectPlayEnableDVConversion = false
        resetAirPlayInstabilityState()
        let routeSnapshot = applyCurrentAudioPolicy(reason: "hls_load_preflight")

        // Wire callbacks
        pipeline.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.pipelineGeneration == generation else { return }
                self.handlePipelineStateChange(state)
            }
        }
        pipeline.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.pipelineGeneration == generation else { return }
                self.handlePipelineError(error)
            }
        }
        pipeline.onEndOfStream = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.pipelineGeneration == generation else { return }
                self.handleEndOfStream()
            }
        }

        try await pipeline.load(url: url, headers: headers, startTime: startTime, requiresProfileConversion: requiresProfileConversion)

        playerDebugLog(
            "[RivuletPlayer] HLS startup route: airPlay=\(routeSnapshot.isAirPlay) " +
            "maxOutCh=\(routeSnapshot.maximumOutputChannels) sampleRate=\(String(format: "%.0f", routeSnapshot.sampleRate))"
        )

        // Update state from pipeline
        self.duration = pipeline.duration
        self.audioTracks = pipeline.audioTracks
        self.subtitleTracks = pipeline.subtitleTracks
        if let firstAudio = audioTracks.first {
            currentAudioTrackId = firstAudio.id
        }
        tracksSubject.send()

        playbackStateSubject.send(.ready)
        startTimeObserver()
    }

    // MARK: - Playback Controls

    func play() {
        guard !isPlaying else {
            playerDebugLog("[RivuletPlayer] play() called but already playing — ignoring")
            return
        }
        isPlaying = true
        playerDebugLog("[RivuletPlayer] play() → \(activePipeline)")

        switch activePipeline {
        case .directPlay:
            // DirectPlay defers its .running state change until preroll completes,
            // which routes to .playing via handlePipelineStateChange. Don't emit
            // .playing here — that would dismiss the loading view before audio
            // and video are actually flowing.
            directPlayPipeline?.start(rate: playbackRate)
        case .hls:
            hlsPipeline?.start(rate: playbackRate)
            playbackStateSubject.send(.playing)
        case .none:
            playbackStateSubject.send(.playing)
        }
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false

        switch activePipeline {
        case .directPlay:
            directPlayPipeline?.pause()
        case .hls:
            hlsPipeline?.pause()
        case .none:
            break
        }

        playbackStateSubject.send(.paused)
    }

    func setMuted(_ muted: Bool) {
        renderer.setMuted(muted)
    }

    func stop() {
        invalidatePipelineGeneration()
        let pipelineName: String = switch activePipeline {
        case .directPlay: "directPlay"
        case .hls: "hls"
        case .none: "none"
        }
        playerDebugLog("[RivuletPlayer] stop() pipeline=\(pipelineName)")
        isPlaying = false
        hasStartedPlayback = false
        timeObserverTask?.cancel()
        timeObserverTask = nil

        switch activePipeline {
        case .directPlay:
            directPlayPipeline?.stop()
        case .hls:
            hlsPipeline?.stop()
        case .none:
            break
        }

        renderer.flush()
        renderer.disableAudioEngine()
        renderer.setRate(0)
        resetAirPlayInstabilityState()
        resetAirPlayRouteOverrides()

        playbackStateSubject.send(.idle)
    }

    func seek(to time: TimeInterval) async {
        let wasPlaying = isPlaying
        playbackStateSubject.send(.buffering)

        do {
            switch activePipeline {
            case .directPlay:
                try await directPlayPipeline?.seek(to: time, isPlaying: wasPlaying)
            case .hls:
                await hlsPipeline?.seek(to: time, isPlaying: wasPlaying)
            case .none:
                break
            }
        } catch {
            playerDebugLog("[RivuletPlayer] Seek error: \(error)")
        }

        // Ensure UI exits buffering even if pipeline doesn't emit an immediate post-seek state.
        playbackStateSubject.send(wasPlaying ? .playing : .paused)

        // Update current time immediately for UI responsiveness
        currentTime = time
        timeSubject.send(time)
    }

    func seekRelative(by seconds: TimeInterval) async {
        let newTime = max(0, min(currentTime + seconds, duration))
        await seek(to: newTime)
    }

    // MARK: - Track Selection

    func selectAudioTrack(id: Int) {
        currentAudioTrackId = id
        // Note: For DirectPlay, use selectAudioTrack(plexTrackId:plexAudioTracks:) instead
        // to correctly map Plex IDs to FFmpeg stream indices.
        // This bare method is kept for PlayerProtocol conformance and HLS use.
    }

    /// Select audio track by Plex track ID, mapping to FFmpeg stream index by position.
    /// - Parameters:
    ///   - plexTrackId: The Plex stream ID (e.g., 209431)
    ///   - plexAudioTracks: The Plex audio track list from the ViewModel (for position mapping)
    func selectAudioTrack(plexTrackId: Int, plexAudioTracks: [MediaTrack]) {
        currentAudioTrackId = plexTrackId

        if activePipeline == .directPlay, let pipeline = directPlayPipeline {
            let ffmpegAudio = ffmpegAudioTracks

            guard let plexIndex = plexAudioTracks.firstIndex(where: { $0.id == plexTrackId }),
                  plexIndex < ffmpegAudio.count else {
                playerDebugLog("[RivuletPlayer] Cannot map Plex audio track \(plexTrackId) to FFmpeg index " +
                      "(plex tracks=\(plexAudioTracks.count), ffmpeg tracks=\(ffmpegAudio.count))")
                return
            }

            let ffmpegStreamIndex = ffmpegAudio[plexIndex].streamIndex
            playerDebugLog("[RivuletPlayer] Mapped Plex audio \(plexTrackId) → FFmpeg stream \(ffmpegStreamIndex)")
            Task {
                do {
                    try await pipeline.selectAudioTrack(streamIndex: ffmpegStreamIndex)
                } catch {
                    playerDebugLog("[RivuletPlayer] ❌ Audio track switch failed: \(error)")
                }
            }
        }
        // For HLS, audio track switching requires a new HLS stream from Plex
        // with audioStreamID parameter — handled by UniversalPlayerViewModel
    }

    func selectSubtitleTrack(id: Int?) {
        currentSubtitleTrackId = id
    }

    func disableSubtitles() {
        currentSubtitleTrackId = nil
    }

    // MARK: - Embedded Subtitle Selection

    /// The FFmpeg audio track list from the demuxer (for mapping Plex IDs → FFmpeg indices)
    var ffmpegAudioTracks: [FFmpegTrackInfo] {
        directPlayPipeline?.demuxer.audioTracks ?? []
    }

    /// The FFmpeg subtitle track list from the demuxer (for mapping Plex IDs → FFmpeg indices)
    var ffmpegSubtitleTracks: [FFmpegTrackInfo] {
        directPlayPipeline?.demuxer.subtitleTracks ?? []
    }

    /// Set a callback for embedded subtitle cues delivered from the read loop.
    var onSubtitleCue: ((String, TimeInterval, TimeInterval) -> Void)? {
        didSet {
            directPlayPipeline?.onSubtitleCue = onSubtitleCue
        }
    }

    /// Set a callback for bitmap subtitle cues (PGS, DVB-SUB) from the read loop.
    var onBitmapSubtitleCue: ((BitmapSubtitleCue) -> Void)? {
        didSet {
            directPlayPipeline?.onBitmapSubtitleCue = onBitmapSubtitleCue
        }
    }

    /// Enable embedded subtitle extraction for a Plex track ID.
    /// Matches to FFmpeg stream by codec type to handle Plex lists that include
    /// external/sidecar subs not present in the container.
    /// Returns `true` if an embedded FFmpeg match was found, `false` if the track
    /// is likely external and should be fetched via Plex URL instead.
    @discardableResult
    func selectEmbeddedSubtitle(plexTrackId: Int, plexSubtitleTracks: [MediaTrack]) -> Bool {
        guard activePipeline == .directPlay, let pipeline = directPlayPipeline else { return false }

        let ffmpegSubs = ffmpegSubtitleTracks
        guard let plexTrack = plexSubtitleTracks.first(where: { $0.id == plexTrackId }) else { return false }

        let plexCodec = MediaTrack.normalizedSubtitleCodec(plexTrack.codec)

        // Count how many Plex subs with the same codec appear before the selected one.
        // This gives us the "Nth track of this codec" position.
        var sameCodecPosition = 0
        for plex in plexSubtitleTracks {
            if plex.id == plexTrackId { break }
            if MediaTrack.normalizedSubtitleCodec(plex.codec) == plexCodec {
                sameCodecPosition += 1
            }
        }

        // Find the Nth FFmpeg sub with matching codec
        var matchCount = 0
        for ffmpeg in ffmpegSubs {
            if MediaTrack.normalizedSubtitleCodec(ffmpeg.codecName) == plexCodec {
                if matchCount == sameCodecPosition {
                    playerDebugLog("[RivuletPlayer] Mapped Plex subtitle \(plexTrackId) → FFmpeg stream \(ffmpeg.streamIndex) (\(ffmpeg.codecName))")
                    pipeline.selectSubtitleStream(ffmpegStreamIndex: ffmpeg.streamIndex)
                    return true
                }
                matchCount += 1
            }
        }

        // No match — likely an external/sidecar subtitle not in the container
        playerDebugLog("[RivuletPlayer] No FFmpeg match for Plex subtitle \(plexTrackId) " +
              "(\(plexTrack.codec ?? "unknown") \(plexTrack.language ?? "")) — falling back to Plex URL")
        return false
    }

    /// Disable embedded subtitle reading.
    func deselectEmbeddedSubtitle() {
        directPlayPipeline?.deselectSubtitleStream()
    }

    // MARK: - Lifecycle

    func prepareForReuse() {
        stop()
        cleanupPipelines()
        currentTime = 0
        duration = 0
        bufferedTime = 0
        audioTracks = []
        subtitleTracks = []
        currentAudioTrackId = nil
        currentSubtitleTrackId = nil
    }

    // MARK: - Private: Pipeline Management

    private func cleanupPipelines() {
        invalidatePipelineGeneration()
        directPlayPipeline?.stop()
        directPlayPipeline = nil
        hlsPipeline?.stop()
        hlsPipeline = nil
        activePipeline = .none

        // Flush the shared renderer so the display layer and audio renderer
        // don't have stale data from a previous pipeline.
        renderer.flush()
        renderer.disableAudioEngine()
        renderer.setRate(0, time: .zero)
        resetAirPlayInstabilityState()
    }

    private func cleanupPipelinesAsync() async {
        let oldDirect = directPlayPipeline
        let oldHLS = hlsPipeline
        directPlayPipeline = nil
        hlsPipeline = nil
        activePipeline = .none

        await oldDirect?.shutdown()
        await oldHLS?.shutdown()

        renderer.flush()
        renderer.disableAudioEngine()
        // Reset synchronizer to time 0 so the time observer doesn't emit
        // stale position from the previous content during episode transitions.
        renderer.setRate(0, time: .zero)
        resetAirPlayInstabilityState()
    }

    private func invalidatePipelineGeneration() {
        pipelineGeneration &+= 1
    }

    // MARK: - Private: Pipeline Callbacks

    private func handlePipelineStateChange(_ state: PipelineState) {
        switch state {
        case .idle:
            playbackStateSubject.send(.idle)
        case .loading:
            // Only treat .loading as a mid-stream buffer underrun once playback
            // has actually started at least once. Pipeline.load() emits .loading
            // synchronously during the initial open, but the @MainActor delivery
            // is deferred — by the time it runs, isPlaying may already be true
            // (because rp.play() ran), so a stale initial-load event would
            // otherwise look like a buffer underrun and dismiss the loading
            // view before preroll completes.
            if isPlaying && hasStartedPlayback {
                playbackStateSubject.send(.buffering)
            } else {
                playerDebugLog("[StartupTrace] handlePipelineStateChange: ignoring stale .loading (isPlaying=\(isPlaying), hasStartedPlayback=\(hasStartedPlayback))")
            }
        case .ready:
            // Suppress during initial load — play() will transition to .playing.
            break
        case .running:
            if isPlaying {
                hasStartedPlayback = true
                playbackStateSubject.send(.playing)
            }
        case .paused:
            playbackStateSubject.send(.paused)
        case .seeking:
            playbackStateSubject.send(.buffering)
        case .ended:
            break // Handled by onEndOfStream
        case .failed:
            break // Handled by onError
        }
    }

    private func handlePipelineError(_ error: Error) {
        let playerError: PlayerError
        if let ffmpegError = error as? FFmpegError {
            playerError = .loadFailed(ffmpegError.localizedDescription)
        } else {
            playerError = .networkError(error.localizedDescription)
        }

        isPlaying = false
        playbackStateSubject.send(.failed(playerError))
        errorSubject.send(playerError)
    }

    private func handleEndOfStream() {
        isPlaying = false
        playbackStateSubject.send(.ended)
    }

    // MARK: - Private: Time Observer

    private func startTimeObserver() {
        timeObserverTask?.cancel()

        timeObserverTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms

                guard let self = self, !Task.isCancelled else { return }

                let time = self.renderer.displayTime
                let usingEngine = self.renderer.useAudioEngine
                let rate = usingEngine ? (self.isPlaying ? 1.0 : 0.0) : self.renderer.renderSynchronizer.rate
                let playing = self.isPlaying

                if time >= 0 {
                    await MainActor.run {
                        self.currentTime = time
                        self.timeSubject.send(time)
                        self.renderer.jitterStats.recordSynchronizerTime(time, isPlaying: playing, rate: rate)
                        _ = self.renderer.jitterStats.reportIfNeeded()
                    }
                }

                // Update buffered time from active pipeline
                await MainActor.run {
                    switch self.activePipeline {
                    case .directPlay:
                        self.bufferedTime = self.directPlayPipeline?.bufferedTime ?? 0
                    case .hls:
                        self.bufferedTime = self.hlsPipeline?.bufferedTime ?? 0
                    case .none:
                        break
                    }
                }

                if !usingEngine {
                    let shouldHandleRendererFailure = await MainActor.run { [weak self] () -> Bool in
                        guard let self else { return false }
                        guard self.renderer.audioRenderer.status == .failed else { return false }

                        let now = CFAbsoluteTimeGetCurrent()
                        if now - self.lastRecordedRendererFailureWallTime < 0.75 {
                            return false
                        }

                        self.lastRecordedRendererFailureWallTime = now
                        let instabilityHandled = self.recordAirPlayInstabilityEvent(.rendererFailure)
                        return !instabilityHandled
                    }

                    if shouldHandleRendererFailure {
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            _ = self.applyCurrentAudioPolicy(reason: "audio_renderer_failed")
                        }
                        await self.recoverAudioFromRendererEvent(
                            afterFlushTime: .invalid,
                            reason: "audio_renderer_failed"
                        )
                    }
                }
            }
        }
    }

    /// Fetches up to ~8 MB of the direct-play URL with a bare
    /// URLSession.dataTask delegate and prints the wire-level throughput.
    /// Use this to compare plain URLSession against our AVIO source — if the
    /// numbers match, the cap is not in our code.
    fileprivate static func runURLSessionProbe(url: URL, headers: [String: String]?) async {
        final class ProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
            var bytes: Int64 = 0
            var firstByte: CFAbsoluteTime = 0
            var lastByte: CFAbsoluteTime = 0
            var done = DispatchSemaphore(value: 0)
            let stopAfter: Int64
            init(stopAfter: Int64) { self.stopAfter = stopAfter }
            func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
                if firstByte == 0 { firstByte = CFAbsoluteTimeGetCurrent() }
                bytes += Int64(data.count)
                lastByte = CFAbsoluteTimeGetCurrent()
                if bytes >= stopAfter { dataTask.cancel() }
            }
            func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                done.signal()
            }
        }

        let stopAfter: Int64 = 8 * 1024 * 1024
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("bytes=0-\(stopAfter - 1)", forHTTPHeaderField: "Range")
        if let headers {
            for (k, v) in headers { request.addValue(v, forHTTPHeaderField: k) }
        }

        // Probe A: default config
        do {
            let cfg = URLSessionConfiguration.default
            cfg.urlCache = nil
            cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let delegate = ProbeDelegate(stopAfter: stopAfter)
            let q = OperationQueue(); q.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: q)
            let task = session.dataTask(with: request)
            task.resume()
            _ = delegate.done.wait(timeout: .now() + 30)
            session.invalidateAndCancel()
            let elapsed = max(delegate.lastByte - delegate.firstByte, 0.001)
            let mbps = Double(delegate.bytes) * 8 / 1_000_000 / elapsed
            playerDebugLog(String(format: "[URLSessionProbe/default] bytes=%.2fMB elapsed=%.2fs rate=%.1fMbps",
                         Double(delegate.bytes) / 1_000_000, elapsed, mbps))
        }

        // Probe B: ephemeral + .avStreaming (same config our AVIO uses)
        do {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.urlCache = nil
            cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            cfg.networkServiceType = .avStreaming
            cfg.waitsForConnectivity = false
            cfg.allowsConstrainedNetworkAccess = true
            cfg.allowsExpensiveNetworkAccess = true
            let delegate = ProbeDelegate(stopAfter: stopAfter)
            let q = OperationQueue(); q.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: q)
            let task = session.dataTask(with: request)
            task.resume()
            _ = delegate.done.wait(timeout: .now() + 30)
            session.invalidateAndCancel()
            let elapsed = max(delegate.lastByte - delegate.firstByte, 0.001)
            let mbps = Double(delegate.bytes) * 8 / 1_000_000 / elapsed
            playerDebugLog(String(format: "[URLSessionProbe/ephemeral-avs] bytes=%.2fMB elapsed=%.2fs rate=%.1fMbps",
                         Double(delegate.bytes) / 1_000_000, elapsed, mbps))
        }
    }
}

// MARK: - PlayerProtocol Conformance

extension RivuletPlayer: PlayerProtocol {}
#endif // RIVULET_FFMPEG
