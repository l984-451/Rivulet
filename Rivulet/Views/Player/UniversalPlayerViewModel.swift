//
//  UniversalPlayerViewModel.swift
//  Rivulet
//
//  ViewModel managing VOD playback state
//

import SwiftUI
import Combine
import UIKit
import Sentry
import AVFoundation
import AVKit

// MARK: - Post-Video State
//
// Track memory (audio + subtitle intent, resolution, migration) lives in
// Services/Plex/Playback/TrackIntent.swift.

/// State machine for post-video summary experience
enum PostVideoState: Equatable {
    case hidden
    case loading
    case showingEpisodeSummary
    case showingMovieSummary
}

/// Video frame state for shrink animation
enum VideoFrameState: Equatable {
    case fullscreen
    case shrunk

    var scale: CGFloat {
        switch self {
        case .fullscreen: return 1.0
        case .shrunk: return 0.25  // 25% size - roughly 480x270 on 1920x1080
        }
    }

    var offset: CGSize {
        switch self {
        case .fullscreen: return .zero
        case .shrunk: return CGSize(width: 60, height: 60)  // Padding from top-left corner
        }
    }
}

/// Seek indicator shown briefly when user taps left/right to skip
enum SeekIndicator: Equatable {
    case forward(Int)   // seconds skipped forward
    case backward(Int)  // seconds skipped backward

    var systemImage: String {
        switch self {
        case .forward: return "goforward.10"
        case .backward: return "gobackward.10"
        }
    }

    var seconds: Int {
        switch self {
        case .forward(let s), .backward(let s): return s
        }
    }
}

@MainActor
final class UniversalPlayerViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var playbackState: UniversalPlaybackState = .idle {
        didSet {
            // Mirror playback lifecycle onto the Sentry App Hang scope so a
            // main-thread hang during e.g. loading/buffering is attributable.
            // See RIVULET-41 and AppHangContext.
            guard playbackState != oldValue else { return }
            AppHangContext.setPlaybackState(playbackState.appHangLabel)
        }
    }
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var errorMessage: String?

    @Published var showControls = true {
        didSet {
            // Focus mode cannot outlive visible controls.
            if !showControls { controlsFocusActive = false }
        }
    }

    /// True while the focus engine is navigating the transport bar's
    /// buttons (Subtitles/Audio/Info/Skip). While active, the SwiftUI
    /// content layer is not focusable, directional input is left to the
    /// focus engine, and controls do not auto-hide.
    @Published var controlsFocusActive = false
    @Published var isScrubbing = false

    /// True while iPod-style circular clickpad rotation is actively
    /// driving the scrub (see `handleWheelRotation(_:)`). Distinct from
    /// `isScrubbing`, which also covers swipe/click-step scrubbing — this
    /// flag is only for the wheel-specific ring indicator in
    /// `PlayerProgressBarView`. Cleared 0.8s after the last rotation tick,
    /// or immediately on `commitScrub()` / `cancelScrub()`.
    @Published private(set) var wheelScrubbing = false

    /// The three tiers of the paused ambient presentation: `.frame` is the
    /// live video frame (no overlay); `.ambient` shows the full-res
    /// crossfaded backdrop + title logo after `pausedPosterDelay` seconds
    /// paused; `.dimmed` adds a deeper black overlay after
    /// `pausedPosterDimDelay` seconds paused (OLED burn-in guard).
    enum PausePresentation: Equatable {
        case frame
        case ambient
        case dimmed
    }
    @Published private(set) var pausePresentation: PausePresentation = .frame

    /// Kept for existing call sites; true in either ambient tier.
    var showPausedPoster: Bool { pausePresentation != .frame }

    /// Full-resolution backdrop for the ambient pause state: raw Plex art
    /// path with token, NOT the `/photo/:/transcode` downscale that
    /// `PlexNetworkManager.buildThumbnailURL` applies (the TV renders it at
    /// native size, full-bleed).
    var ambientBackdropURL: URL? {
        guard let art = metadata.art,
              var components = URLComponents(string: "\(serverURL)\(art)") else { return nil }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "X-Plex-Token", value: authToken)
        ]
        return components.url
    }

    /// Title logo (clearArt) for the transport bar, resolved once per item:
    /// prefer the Plex-provided clearLogo image, falling back to TMDB's
    /// images API via the shared cache (same precedence the home hero and
    /// media detail chrome use).
    @Published private(set) var titleLogoImage: UIImage?
    private var titleLogoResolveTask: Task<Void, Never>?

    @Published var shouldDismiss = false  // Used to request player dismissal on tvOS
    @Published var compatibilityNotice: String?

    // MARK: - Seek Indicator State
    /// Shows a brief indicator when user taps left/right to skip 10 seconds
    @Published var seekIndicator: SeekIndicator?

    // MARK: - Chapter Thumbnails
    private var chapterThumbnails: [Int: Data] = [:]  // index → image data

    // MARK: - Skip Marker State
    @Published private(set) var activeMarker: PlexMarker?
    @Published private(set) var showSkipButton = false
    private var hasSkippedIntro = false
    private var skippedCreditsIds: Set<Int> = []  // Track skipped credits by ID (can have multiple)
    private var skippedCommercialIds: Set<Int> = []  // Track skipped commercials by ID
    private var skippedRecapIds: Set<Int> = []  // Track skipped recaps by ID (IntroDB backup)
    private var skippedPreviewIds: Set<Int> = []  // Track skipped previews by ID
    private var hasTriggeredPostVideo = false

    // MARK: - Auto-Skip Countdown State
    /// Current countdown value (5...4...3...2...1), 0 means no countdown active.
    /// Runs only when the matching Auto-Skip setting (Intro/Credits/Ads) is on;
    /// drives the pill's "· N" suffix and auto-skips the active marker at 0.
    @Published var skipCountdownSeconds: Int = 0
    private var skipCountdownTimer: Timer?
    private let skipCountdownDelaySeconds: Int = 5
    /// Tracks if the user cancelled the auto-skip countdown for the CURRENT
    /// marker (Menu press): keeps the manual pill up without restarting the
    /// countdown. Reset when the active marker clears or the user seeks back.
    private var userDeclinedAutoSkip = false
    @Published var scrubTime: TimeInterval = 0

    // MARK: - Post-Video State
    @Published var postVideoState: PostVideoState = .hidden
    @Published var videoFrameState: VideoFrameState = .fullscreen
    @Published private(set) var nextEpisode: PlexMetadata?
    /// Set once the next episode has been RESOLVED EARLY for the current episode
    /// (driven by Aether's first non-nil currentAVPlayer). Guards the fetch so
    /// it runs once per episode even though currentAVPlayer re-emits on every
    /// Aether internal AVPlayer swap. Reset on episode change in playNextEpisode().
    private var nextEpisodeResolvedEarly = false
    /// Current season's episodes (sorted by index) for the Up Next panel. When
    /// the current episode is a season finale, the next season's opener is
    /// appended so the panel can still show an up-next row. Populated by
    /// `loadUpNextEpisodes()`, hooked off `resolveNextEpisodeEarlyIfNeeded()`;
    /// cleared on episode swap in `playNextEpisode()`.
    @Published private(set) var upNextEpisodes: [PlexMetadata] = []
    /// Cast for the Insights rail panel. TMDB credits primary (headshots +
    /// character names for anything with a tmdb guid), Plex Role fallback
    /// for home media / unmatched items. Loaded once per item by the
    /// container's $itemGeneration sink; reset on item swap.
    @Published private(set) var insightsCast: [MediaPerson] = []
    /// Trivia for the Insights rail panel's Trivia section (P2a, read-only).
    /// `nil` = no trivia available (title uncovered / network failure) —
    /// the panel renders no Trivia section at all, same graceful-absent
    /// rule as `insightsCast`. Loaded in the same per-item flow as cast by
    /// `loadInsightsTrivia()`; reset on item swap.
    @Published private(set) var insightsTrivia: TitleTrivia?
    /// Fact ids the Worker has auto-hidden after enough user reports.
    /// Fetched alongside trivia; empty on any failure (fail-open — showing
    /// a fact is acceptable, failing closed is not required for this list).
    @Published private(set) var suppressedTriviaIDs: Set<String> = []
    /// Item keys we've already asked the pipeline to generate this session — fire once.
    private var requestedInsightKeys: Set<String> = []
    /// Cancels the mid-playback trivia re-check on item swaps or player teardown.
    private var insightsRecheckTask: Task<Void, Never>?
    @Published private(set) var recommendations: [PlexMetadata] = []
    @Published var countdownSeconds: Int = 0
    @Published var isCountdownPaused: Bool = false
    private var countdownTimer: Timer?
    @Published var scrubThumbnail: UIImage?
    @Published private(set) var scrubSpeed: Int = 0  // -3...3 shuttle level (0 = not shuttling); see ShuttleGrammar
    private var scrubStartTime: Date?  // When scrubbing started (for YouTube-style acceleration)
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var currentAudioTrackId: Int?
    @Published private(set) var currentSubtitleTrackId: Int?
    /// Active "What did they say?" replay window, if the user is currently
    /// inside one. Cleared (without reverting) by any user-initiated
    /// absolute seek, manual subtitle-track change, or stopPlayback.
    private var replayWindow: ReplayWindowLogic?
    private var compatibilityNoticeTimer: Timer?
    private nonisolated(unsafe) var userActivity: NSUserActivity?

    // MARK: - Player Instance

    /// AVPlayer used for all playback paths (direct, remuxed HLS, Plex HLS)
    @Published private(set) var player: AVPlayer?

    /// HLS manifest enricher — injects audio/subtitle track labels into the master playlist.
    /// Must be retained for the lifetime of the AVURLAsset.
    private var hlsManifestEnricher: HLSManifestEnricher?

    /// KVO observers
    private var rateObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    // Non-isolated reference for cleanup in deinit
    private nonisolated(unsafe) var _playerForCleanup: AVPlayer?
    private nonisolated(unsafe) var _timeObserverForCleanup: Any?

    /// The VOD player: AetherEngine, surfaced through a PlayerProtocol
    /// adapter. @Published to drive internal subscriptions that rebind the
    /// underlying AVPlayer on every Aether internal reload (audio-track
    /// switch, background reopen).
    @Published private(set) var aetherPlayer: AetherPlayer?

    /// Subtitle manager for custom subtitle rendering.
    let subtitleManager = SubtitleManager()
    private let subtitleClockSync = SubtitleClockSyncController()

    /// Cue store for the Aether route's subtitle overlay. Fed from
    /// AetherPlayer's cue/clock publishers in bindAetherPublishers();
    /// rendered by AetherSubtitleOverlayView in UniversalPlayerView.
    /// (The AVPlayer routes render through subtitleManager instead.)
    let aetherSubtitleModel = SubtitleModel()

    // MARK: - Metadata

    private(set) var metadata: PlexMetadata
    /// Bumped whenever `metadata` is swapped to a different playable item
    /// on this same view-model instance (e.g. `playNextEpisode()`), as
    /// opposed to in-place field fills like `fetchFullMetadataIfNeeded()`
    /// completing parent keys for the *same* item. UI that caches
    /// per-item state (e.g. the progress bar's filmstrip tiles) should
    /// observe this to know when to reset, since `metadata` itself isn't
    /// `@Published` and its `ratingKey` is the only reliable identity
    /// signal across a swap.
    @Published private(set) var itemGeneration = 0
    var title: String { metadata.title ?? "Unknown" }
    var subtitle: String? {
        if metadata.type == "episode" {
            let show = metadata.grandparentTitle ?? ""
            let season = metadata.parentIndex.map { "S\($0)" } ?? ""
            let episode = metadata.index.map { "E\($0)" } ?? ""
            return "\(show) \(season)\(episode)"
        }
        return metadata.year.map { String($0) }
    }

    // MARK: - Private State

    private var cancellables = Set<AnyCancellable>()
    private var controlsTimer: Timer?
    private let controlsHideDelay: TimeInterval = 5
    private var scrubTimer: Timer?
    private var wheelScrubbingTimer: Timer?
    private let wheelScrubbingIdleDelay: TimeInterval = 0.8
    private var appBecameActiveObserver: Any?
    private var appBackgroundObserver: Any?
    private var pausedDueToAppInactive: Bool = false
    private let scrubUpdateInterval: TimeInterval = 0.1  // 100ms updates for smooth scrubbing
    private var seekIndicatorTimer: Timer?
    private var pausedPosterTimer: Timer?
    private let pausedPosterDelay: TimeInterval = 5.0
    private var pausedPosterDimTimer: Timer?
    private let pausedPosterDimDelay: TimeInterval = 120.0
    /// True while a rail panel (Subtitles/Audio/Info/Up Next/Insights) is
    /// presented. The ambient-pause backdrop is a full-screen visual that
    /// otherwise shows through/around an open panel — set by
    /// `PlayerContainerViewController` around `presentRailPanel`/dismiss so
    /// the timer below can suppress itself while a panel is up.
    var isRailPanelOpen = false {
        didSet {
            guard isRailPanelOpen != oldValue else { return }
            if isRailPanelOpen {
                cancelPausedPosterTimer()
            } else if playbackState == .paused {
                startPausedPosterTimer()
            }
        }
    }
    private var aetherStallWatchdogTask: Task<Void, Never>?
    private let aetherStallRecoveryDelay: TimeInterval = 20
    private let aetherStallFailureDelay: TimeInterval = 20

    // MARK: - Playback Context

    let serverURL: String
    let authToken: String
    private(set) var startOffset: TimeInterval?

    // MARK: - Loading Screen Images (passed from detail view for instant display)

    let loadingArtImage: UIImage?
    let loadingThumbImage: UIImage?
    /// Season/show poster fetched for Now Playing artwork (episodes only)
    private var seasonPosterImage: UIImage?

    // MARK: - Stream URL (computed once)

    @Published private(set) var streamURL: URL?
    private(set) var streamHeaders: [String: String] = [:]
    /// Single-flight guard so concurrent starts/retries don't race URL preparation.
    private var streamPreparationTask: Task<Void, Never>?
    /// Plex transcode session ID, extracted from HLS stream URL for cleanup on stop
    private var plexSessionId: String?
    /// Playback startup/fallback plan for Rivulet direct-play-first policy.
    private var playbackPlan: PlaybackPlan?
    /// Optional prebuilt HLS fallback URL/headers to reduce fallback startup latency.
    private var rivuletFallbackURL: URL?
    private var rivuletFallbackHeaders: [String: String] = [:]
    /// One-shot direct-play -> HLS fallback guards (prevents loops).
    private var hasAttemptedRivuletHLSFallback = false
    private var isAttemptingRivuletHLSFallback = false
    /// Causal-chain diagnostics for this playback session. Carries the ORIGINAL
    /// (primary-route) failure through to whatever error finally surfaces, so a
    /// fallback failure never reports itself as the root cause. See RIVULET-19.
    private let diagnostics = PlaybackDiagnostics()

    // MARK: - Shuffled Queue

    private var shuffledQueue: [PlexMetadata] = []
    private var shuffledQueueIndex: Int = 0
    var isShufflePlay: Bool { !shuffledQueue.isEmpty }

    // MARK: - Preloaded Next Episode Data

    private var preloadedNextStreamURL: URL?
    private var preloadedNextStreamHeaders: [String: String] = [:]
    private var preloadedNextMetadata: PlexMetadata?

    // MARK: - Initialization

    /// Pre-play subtitle choice from the item-detail picker. Distinguishes
    /// "user hasn't picked yet" from "user explicitly turned subs off"
    /// from "user picked this specific subtitle track".
    enum InitialSubtitleSelection {
        case auto              // No preselection — fall through to the stored SubtitleIntent.
        case off               // User explicitly chose Off in the pre-play picker.
        case track(id: Int)    // User picked a specific subtitle track.
    }

    init(
        metadata: PlexMetadata,
        serverURL: String,
        authToken: String,
        startOffset: TimeInterval? = nil,
        shuffledQueue: [PlexMetadata] = [],
        loadingArtImage: UIImage? = nil,
        loadingThumbImage: UIImage? = nil,
        initialAudioTrackId: Int? = nil,
        initialSubtitleSelection: InitialSubtitleSelection = .auto
    ) {
        self.metadata = metadata
        self.serverURL = serverURL
        self.authToken = authToken
        self.startOffset = startOffset
        self.shuffledQueue = shuffledQueue
        self.loadingArtImage = loadingArtImage
        self.loadingThumbImage = loadingThumbImage
        self.initialAudioTrackId = initialAudioTrackId
        self.initialSubtitleSelection = initialSubtitleSelection

        let isAirPlayRoute = Self.isAirPlayOutput()
        let hasDolbyVision = metadata.hasDolbyVision

        // Get container format for logging
        let container = metadata.Media?.first?.Part?.first?.container?.lowercased() ?? ""

        let dvProfile = metadata.Media?.first?.Part?.first?.Stream?
            .first { $0.isVideo && (($0.DOVIProfile != nil) || ($0.DOVIPresent == true)) }?
            .DOVIProfile

        print("[PlayerSelect] content: DV=\(hasDolbyVision) profile=\(dvProfile ?? -1) " +
              "container=\(container) airPlay=\(isAirPlayRoute) → Aether")

        setupPlayer()

        addPlaybackSelectionBreadcrumb(reason: "init")
    }

    private func setupPlayer() {
        bindPlayerState()
        observeAppLifecycle()
    }

    /// Clear any prepared stream state so the next startup recomputes route + URLs.
    private func resetPreparedStreamContext() {
        streamPreparationTask?.cancel()
        streamPreparationTask = nil
        streamURL = nil
        streamHeaders = [:]
        playbackPlan = nil
        rivuletFallbackURL = nil
        rivuletFallbackHeaders = [:]
    }

    /// Ensure stream URL preparation runs at most once for a startup attempt.
    private func ensureStreamURLPrepared(forceRefresh: Bool = false) async {
        if forceRefresh {
            resetPreparedStreamContext()
        }

        if streamURL != nil {
            return
        }

        if let task = streamPreparationTask {
            await task.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareStreamURL()
        }
        streamPreparationTask = task
        await task.value

        if streamPreparationTask != nil {
            streamPreparationTask = nil
        }
    }

    /// Observe app lifecycle to pause playback when app goes to background
    /// Only pauses on actual background entry (not Control Center overlay)
    private func observeAppLifecycle() {
        // Only pause when actually entering background (home button, sleep, etc.)
        // This does NOT fire for Control Center overlay on tvOS
        appBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // The Aether engine self-manages background: it tears the video pipeline down on background
            // and reloads + restores play state on foreground. Pausing it here would run before the
            // engine captures its pre-background play state, clobbering it so it always returned paused.
            // Let Aether own its lifecycle; this host pause covers the HLS/AVPlayer route only.
            if self.aetherPlayer != nil { return }
            if self.playbackState == .playing {
                self.pausedDueToAppInactive = true
                print("[Player] App entering background — pausing")
                Task { @MainActor in
                    self.pause()
                }
            }
        }

        // When returning from background, keep paused (user must manually resume)
        appBecameActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.pausedDueToAppInactive {
                self.pausedDueToAppInactive = false
            }
        }
    }

    private func prepareStreamURL() async {
        let networkManager = PlexNetworkManager.shared

        guard metadata.ratingKey != nil else { return }

        // Fetch full metadata if Media array is missing (needed for info overlay display)
        // This happens when starting playback from Continue Watching or other hubs with minimal metadata
        if metadata.Media == nil || metadata.Media?.isEmpty == true {
            await fetchFullMetadataIfNeeded()
        }

        // IntroDB backup markers: ALWAYS check, even when Plex metadata (and
        // its markers) arrived complete — Plex never emits recap, so there is
        // almost always a kind worth backfilling. Off the critical path so a
        // slow/dead community DB can't delay playback start; the recap window
        // sits at the top of the episode, and the merge lands within the
        // first marker-check ticks.
        Task { [weak self] in
            await self?.backfillMarkersFromIntroDB()
        }

        let routingContext = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: serverURL)!,
            authToken: authToken,
            playbackPolicy: .directPlayFirst
        )
        let plan = ContentRouter.plan(for: routingContext)
        playbackPlan = plan
        rivuletFallbackURL = nil
        rivuletFallbackHeaders = [:]
        // Tag the chosen route for App Hang triage (RIVULET-41).
        AppHangContext.setPlaybackRoute(plan.primary.description)
        // Seed the media fingerprint (codec / DV profile / audio / resume offset)
        // so EVERY playback error from here on is self-describing. Without this,
        // "playback failed" can't be told apart from "playback fails on DV P7".
        diagnostics.setMedia(metadata, route: plan.primary.description, startOffset: startOffset)
        diagnostics.step("route_selected", detail: plan.description)

        switch plan.primary {
        case .hls:
            if let result = buildRivuletHLSURL(offset: startOffset) {
                streamURL = result.url
                streamHeaders = result.headers
                plexSessionId = result.sessionId
            }

        case .aether(let url, let headers):
            // Aether takes the direct-play URL: the engine demuxes the
            // source itself and serves HLS-fMP4 to AVPlayer over loopback.
            streamURL = url
            streamHeaders = headers ?? rivuletDirectPlayHeaders()

            // Prepare an HLS fallback so a load failure on Aether can
            // recover via the Plex HLS transcode path.
            if plan.fallbacks.contains(where: { if case .hls = $0 { return true } else { return false } }),
               let preparedFallback = buildRivuletHLSURL(offset: startOffset) {
                rivuletFallbackURL = preparedFallback.url
                rivuletFallbackHeaders = preparedFallback.headers
                // The [Plex HLS] / hls_fallback_build lines above come from
                // THIS prebuild. No server session starts unless the URL is
                // actually fetched after "[Fallback] ... → HLS".
                print("[Player] Aether primary; HLS fallback URL prebuilt only (not playing)")
            }
        }
    }

    /// Determines whether audio can be safely direct-streamed on the HLS path.
    /// DTS/TrueHD should be transcoded by Plex. Multichannel AAC should be
    /// transcoded when output is AirPlay stereo.
    private static func isAudioDirectStreamCapable(_ metadata: PlexMetadata) -> Bool {
        // Try stream-level codec first, fall back to media-level
        let audioCodec: String
        let channelCount: Int
        if let audioStream = metadata.Media?.first?.Part?.first?.Stream?.first(where: { $0.isAudio }),
           let streamCodec = audioStream.codec?.lowercased() {
            audioCodec = streamCodec
            channelCount = audioStream.channels ?? 2
        } else if let mediaCodec = metadata.Media?.first?.audioCodec?.lowercased() {
            audioCodec = mediaCodec
            channelCount = metadata.Media?.first?.audioChannels ?? 2
        } else {
            // Unknown codec - prefer safety and allow server to transcode
            return false
        }

        // DTS/TrueHD must always be transcoded
        guard ["aac", "ac3", "eac3"].contains(audioCodec) else {
            return false
        }

        // AC3/EAC3 (Dolby Digital) can always be direct streamed - HomePod supports these
        if audioCodec == "ac3" || audioCodec == "eac3" {
            return true
        }

        // For AAC, check if it's multichannel AND output is AirPlay (HomePod)
        // HomePod supports Dolby Digital surround but NOT multichannel AAC
        if audioCodec == "aac" && channelCount > 2 {
            if isAirPlayOutput() {
                return false
            }
        }

        return true
    }

    /// Route-aware audio direct-stream decision for each HLS URL build path.
    /// Must be evaluated at runtime (not cached) because AirPlay routes can change.
    private func allowAudioDirectStreamDecision(reason: String) -> Bool {
        let allow = Self.isAudioDirectStreamCapable(metadata)
        let audioStream = metadata.Media?.first?.Part?.first?.Stream?.first(where: { $0.isAudio })
        let codec = audioStream?.codec?.lowercased()
            ?? metadata.Media?.first?.audioCodec?.lowercased()
            ?? "unknown"
        let channels = audioStream?.channels
            ?? metadata.Media?.first?.audioChannels
            ?? 0
        let routeSnapshot = PlaybackAudioSessionConfigurator.currentRouteAudioSnapshot(
            owner: "UniversalPlayerViewModel",
            reason: "hls_audio_policy_\(reason)"
        )

        print(
            "[HLSAudioPolicy] reason=\(reason) allowAudioDirectStream=\(allow) " +
            "codec=\(codec) channels=\(channels) airPlay=\(routeSnapshot.isAirPlay) " +
            "maxOutCh=\(routeSnapshot.maximumOutputChannels)"
        )
        return allow
    }

    /// Check if the current audio output is AirPlay.
    private static func isAirPlayOutput() -> Bool {
        guard PlaybackAudioSessionConfigurator.isAirPlayRouteActive() else {
            return false
        }

        let session = AVAudioSession.sharedInstance()
        _ = session.currentRoute.outputs.first(where: { $0.portType == .airPlay })
        return true
    }

    private func bindPlayerState() {
        // Nothing to bind at init — observers are set up in setupAVPlayerObservers()
        // when the player is created during startPlayback()
    }

    // MARK: - AVPlayer Observation (standard KVO)

    /// Set up KVO observers on the current AVPlayer + AVPlayerItem.
    private func setupAVPlayerObservers() {
        guard let player = player else { return }

        // Rate changes → play/pause state
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if player.rate > 0 {
                    self.updatePlaybackState(.playing)
                } else if self.playbackState == .playing {
                    let item = player.currentItem
                    let bufEmpty = item?.isPlaybackBufferEmpty ?? true
                    let keepUp = item?.isPlaybackLikelyToKeepUp ?? false
                    let time = String(format: "%.1f", item?.currentTime().seconds ?? 0)
                    let loaded = item?.loadedTimeRanges.first?.timeRangeValue
                    let loadedEnd = loaded.map { String(format: "%.1f", CMTimeGetSeconds($0.start) + CMTimeGetSeconds($0.duration)) } ?? "?"
                    print("[Player] rate→0 (was playing) at \(time)s bufEmpty=\(bufEmpty) keepUp=\(keepUp) tcs=\(player.timeControlStatus.rawValue) loadedTo=\(loadedEnd)s")
                    self.updatePlaybackState(.paused)
                }
            }
        }

        // Buffering detection
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
                switch player.timeControlStatus {
                case .waitingToPlayAtSpecifiedRate:
                    if self.playbackState != .buffering {
                        print("[Player] AVPlayer: waitingToPlay (reason=\(reason), rate=\(player.rate))")
                    }
                    self.updatePlaybackState(.buffering)
                case .playing:
                    print("[Player] AVPlayer: playing (rate=\(player.rate))")
                    if self.playbackState == .buffering {
                        self.updatePlaybackState(.playing)
                    }
                case .paused:
                    print("[Player] AVPlayer: paused (rate=\(player.rate))")
                    break  // Handled by rate observer
                @unknown default:
                    break
                }
            }
        }

        // Player item status → ready/failed
        if let item = player.currentItem {
            print("[Player] Setting up item status observer (current status: \(item.status.rawValue), item: \(item))")
            itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let statusVal = item.status.rawValue
                print("[Player] AVPlayerItem KVO fired: status=\(statusVal) error=\(item.error?.localizedDescription ?? "nil")")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch item.status {
                    case .readyToPlay:
                        print("[Player] AVPlayerItem status: readyToPlay")
                        let dur = item.duration.seconds
                        if dur.isFinite { self.duration = dur }
                        self.updateTrackLists()
                    case .failed:
                        let message = item.error?.localizedDescription ?? "Playback failed"
                        print("[Player] AVPlayerItem status: FAILED — \(message)")
                        if let error = item.error as? NSError {
                            print("[Player] Error domain=\(error.domain) code=\(error.code)")
                            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                                print("[Player] Underlying: \(underlying.domain) code=\(underlying.code) — \(underlying.localizedDescription)")
                            }
                        }
                        // The AVPlayerItem error was previously only printed to
                        // the console, so a mid-playback item failure that the
                        // HLS fallback rescued left no trace in Sentry at all.
                        let itemError = item.error ?? PlayerError.loadFailed(message)
                        self.diagnostics.recordPrimaryFailure(
                            itemError,
                            kind: self.classifyDirectPlayFailure(PlayerError.loadFailed(message)),
                            route: self.playbackPlan?.primary.description.lowercased() ?? "unknown"
                        )
                        if self.shouldAttemptRivuletFallbackOnItemFailure() {
                            let failureKind = self.classifyDirectPlayFailure(PlayerError.loadFailed(message))
                            let resumeTime = self.currentTime
                            self.updatePlaybackState(.loading)
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                do {
                                    try await self.attemptRivuletHLSFallback(
                                        resumeTime: resumeTime,
                                        reason: "avplayer_item_failed",
                                        failureKind: failureKind
                                    )
                                    self.player?.play()
                                } catch {
                                    let technicalMessage = error.localizedDescription
                                    if let playerError = error as? PlayerError {
                                        self.errorMessage = playerError.userFacingDescription
                                    } else {
                                        self.errorMessage = PlayerError.loadFailed(message).userFacingDescription
                                    }
                                    self.updatePlaybackState(.failed(.loadFailed(technicalMessage)))
                                }
                            }
                            break
                        }
                        self.errorMessage = PlayerError.loadFailed(message).userFacingDescription
                        self.updatePlaybackState(.failed(.loadFailed(message)))
                    case .unknown:
                        print("[Player] AVPlayerItem status: unknown")
                    @unknown default:
                        break
                    }
                }
            }

            // End of playback
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updatePlaybackState(.ended)
                }
            }
        }

        // Time updates (every 0.5s)
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = time.seconds
                self.checkMarkers(at: time.seconds)
                self.tickReplayWindow(at: time.seconds)
            }
        }
        timeObserver = observer
        _timeObserverForCleanup = observer
    }

    /// Tear down AVPlayer observers.
    private func teardownAVPlayerObservers() {
        rateObservation?.invalidate()
        rateObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    /// Update playback state with side effects (controls, screensaver, post-video).
    private func updatePlaybackState(_ state: UniversalPlaybackState) {
        playbackState = state
        isBuffering = state == .buffering

        if state == .playing {
            startControlsHideTimer()
            UIApplication.shared.isIdleTimerDisabled = true
            cancelPausedPosterTimer()
        } else {
            controlsTimer?.invalidate()
            if state == .paused || state == .ended || state == .idle {
                UIApplication.shared.isIdleTimerDisabled = false
            }
            if state == .paused {
                startPausedPosterTimer()
            } else {
                cancelPausedPosterTimer()
            }
        }

        if state == .ended {
            Task { await handlePlaybackEnded() }
        }
    }

    // MARK: - Computed Properties

    var isPlaying: Bool {
        if let ap = aetherPlayer {
            return ap.isPlaying
        }
        return (player?.rate ?? 0) > 0
    }

    /// Log the selection decision to Sentry for debugging DV routing.
    private func addPlaybackSelectionBreadcrumb(reason: String) {
        let videoStreams = metadata.Media?.first?.Part?.first?.Stream?.filter { $0.isVideo } ?? []
        let dvStream = videoStreams.first { ($0.DOVIProfile != nil) || ($0.DOVIPresent == true) }
        let audioStream = metadata.Media?.first?.Part?.first?.Stream?.first(where: { $0.isAudio })
        let breadcrumb = Breadcrumb(level: .info, category: "playback.selection")
        breadcrumb.message = "Playback selection (\(reason))"
        breadcrumb.data = [
            "player": "avplayer",
            "has_dv": metadata.hasDolbyVision,
            "dv_profile": dvStream?.DOVIProfile ?? -1,
            "dv_bl_compat": dvStream?.DOVIBLCompatID ?? -1,
            "video_codec_id": dvStream?.codecID ?? "unknown",
            "video_codec": dvStream?.codec ?? "unknown",
            "audio_codec": audioStream?.codec ?? "unknown",
            "container": metadata.Media?.first?.container ?? "unknown",
            "allow_audio_direct_stream": allowAudioDirectStreamDecision(reason: "selection_breadcrumb")
        ]
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    // MARK: - Playback Controls

    func retryPlayback() async {
        // Reset error state and retry
        errorMessage = nil
        playbackState = .loading
        hasAttemptedRivuletHLSFallback = false
        isAttemptingRivuletHLSFallback = false

        // Stop existing player before retrying
        stopPlayback()
        resetPreparedStreamContext()
        subtitleClockSync.stop()

        await startPlayback()
    }

    func startPlayback() async {
        // Fetch detailed metadata if markers or chapters are missing
        let hasMarkers = !(metadata.Marker ?? []).isEmpty
        let hasChapters = !(metadata.Chapter ?? []).isEmpty
        let hasStreamDetails = metadata.Media?.first?.Part?.first?.Stream?.isEmpty == false
        if !hasMarkers || !hasChapters || !hasStreamDetails {
            await fetchMarkersIfNeeded()
        }

        // Fetch season/show poster for Now Playing artwork (episodes)
        await fetchSeasonPosterIfNeeded()

        // Resolve the title logo for the ambient-pause transport bar swap.
        fetchTitleLogoIfNeeded()

        // Aether is the only VOD engine; ContentRouter.plan() emits the
        // .aether route (or an AVPlayer fallback route) and
        // startAVPlayerPlayback() drives both.
        await startAVPlayerPlayback()
    }

    // MARK: - AVPlayer Startup

    private func startAVPlayerPlayback() async {
        await ensureStreamURLPrepared()

        guard let url = streamURL else {
            errorMessage = "No stream URL available"
            playbackState = .failed(.invalidURL)
            return
        }
        hasAttemptedRivuletHLSFallback = false
        isAttemptingRivuletHLSFallback = false

        addPlaybackSelectionBreadcrumb(reason: "startAVPlayerPlayback")

        do {
            // Aether drives AVDisplayManager.preferredDisplayCriteria
            // itself, synchronously before AVPlayer.replaceCurrentItem, so
            // Rivulet's DisplayCriteriaManager stands down here to avoid
            // two writers fighting over the panel-mode handshake.

            let plan = playbackPlan ?? ContentRouter.plan(for: ContentRoutingContext(
                metadata: metadata,
                serverURL: URL(string: serverURL)!,
                authToken: authToken,
                playbackPolicy: .directPlayFirst
            ))
            try await startWithFallback(plan: plan, startTime: startOffset)

            if let ap = aetherPlayer {
                // Aether kicks playback through its own internal AVPlayer;
                // Rivulet's `player` is nil on this path. Just call play()
                // on the adapter and let Aether's state machine drive.
                print("[Aether] play() — adapter")
                ap.play()
            } else {
                let itemStatus = player?.currentItem?.status.rawValue ?? -1
                let bufferEmpty = player?.currentItem?.isPlaybackBufferEmpty ?? true
                let bufferFull = player?.currentItem?.isPlaybackBufferFull ?? false
                let likelyKeepUp = player?.currentItem?.isPlaybackLikelyToKeepUp ?? false
                print("[Player] play() — status=\(itemStatus) bufferEmpty=\(bufferEmpty) bufferFull=\(bufferFull) likelyKeepUp=\(likelyKeepUp)")
                player?.play()
            }

            // Index for Siri Suggestions
            let activity = NSUserActivity(activityType: "com.rivulet.playMedia")
            activity.title = metadata.title
            activity.isEligibleForSearch = true
            activity.userInfo = ["ratingKey": metadata.ratingKey ?? ""]
            activity.targetContentIdentifier = "rivulet://play?ratingKey=\(metadata.ratingKey ?? "")"
            self.userActivity = activity
            activity.becomeCurrent()
            if let dur = player?.currentItem?.duration.seconds, dur.isFinite {
                self.duration = dur
            }
            updateTrackLists()
            preloadThumbnails()
            startControlsHideTimer()
        } catch {
            let technicalError = error.localizedDescription
            if let playerError = error as? PlayerError {
                errorMessage = playerError.userFacingDescription
            } else {
                errorMessage = "Something went wrong during playback. Please try again."
            }
            playbackState = .failed(.loadFailed(technicalError))

            // Route through PlaybackDiagnostics so this carries the media
            // fingerprint, the startup timeline, and any earlier primary-route
            // failure. The old inline capture reported the media title but not
            // the codec, and knew nothing about a prior Aether failure.
            diagnostics.step("avplayer_start_failed", detail: technicalError)
            diagnostics.capture(error, event: "avplayer_start_failed", extraTags: [
                "player_type": "avplayer"
            ])
        }
    }

    // MARK: - Rivulet Direct-Play-First Fallback

    /// Build standard direct-play headers for FFmpeg requests.
    private func rivuletDirectPlayHeaders() -> [String: String] {
        [
            "X-Plex-Token": authToken,
            "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
            "X-Plex-Platform": PlexAPI.platform,
            "X-Plex-Device": PlexAPI.deviceName,
            "X-Plex-Product": PlexAPI.productName
        ]
    }

    /// Build an HLS URL and headers for Rivulet fallback at the requested offset.
    private func buildRivuletHLSURL(offset: TimeInterval?) -> (url: URL, headers: [String: String], sessionId: String?)? {
        guard let ratingKey = metadata.ratingKey else { return nil }
        // Source video codec has no Apple TV decoder (e.g. MPEG-2): the
        // direct-play-shaped URL would hand back the raw file and the
        // local decoder would fail. Flip on forceVideoTranscode so the
        // URL becomes a real transcode request.
        let forceVideoTranscode = ContentRouter.requiresVideoTranscode(metadata: metadata)
        guard let result = PlexNetworkManager.shared.buildHLSDirectPlayURL(
            serverURL: serverURL,
            authToken: authToken,
            ratingKey: ratingKey,
            offsetMs: Int((offset ?? 0) * 1000),
            hasHDR: metadata.hasHDR,
            useDolbyVision: metadata.hasDolbyVision,
            forceVideoTranscode: forceVideoTranscode,
            allowAudioDirectStream: allowAudioDirectStreamDecision(reason: "rivulet_hls_fallback_build")
        ) else {
            return nil
        }
        let sessionId = URLComponents(url: result.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "session" })?.value
        return (url: result.url, headers: result.headers, sessionId: sessionId)
    }

    private func classifyDirectPlayFailure(_ error: Error) -> DirectPlayFailureKind {
        if let playerError = error as? PlayerError {
            switch playerError {
            case .codecUnsupported:
                return .unsupportedCodec
            case .networkError:
                return .network
            case .loadFailed(let message):
                let lower = message.lowercased()
                if lower.contains("unsupported codec") { return .unsupportedCodec }
                if lower.contains("open input") || lower.contains("stream info") ||
                    lower.contains("no codec parameters") || lower.contains("invalid stream") {
                    return .demuxInit
                }
                if lower.contains("formatdescription") || lower.contains("samplebuffer") ||
                    lower.contains("decoder") || lower.contains("decode") {
                    return .decodeInit
                }
                return .runtimeFatal
            case .invalidURL:
                return .demuxInit
            case .unknown:
                return .unknown
            }
        }

        let lower = error.localizedDescription.lowercased()
        if lower.contains("network") || lower.contains("timed out") || lower.contains("connection") {
            return .network
        }
        if lower.contains("unsupported codec") {
            return .unsupportedCodec
        }
        return .unknown
    }

    private func planHasHLSFallback(_ plan: PlaybackPlan?) -> Bool {
        guard let plan else { return false }
        return plan.fallbacks.contains { route in
            if case .hls = route { return true }
            return false
        }
    }

    private func shouldAttemptRivuletFallbackOnItemFailure() -> Bool {
        guard planHasHLSFallback(playbackPlan) else { return false }
        guard !hasAttemptedRivuletHLSFallback, !isAttemptingRivuletHLSFallback else { return false }
        guard let current = streamURL else { return false }
        if let fallback = rivuletFallbackURL, current == fallback {
            return false
        }
        return true
    }

    /// Wait for AVPlayerItem status to leave `.unknown` during startup.
    /// Returns true when ready, false on timeout/failed/missing item.
    private func waitForCurrentItemReady(timeout: TimeInterval) async -> Bool {
        guard let item = player?.currentItem else {
            print("[Player] waitReady: no currentItem")
            return false
        }

        // Already ready
        if item.status == .readyToPlay { return true }
        if item.status == .failed { return false }

        // Use KVO continuation — wakes immediately when status changes, no polling
        return await withCheckedContinuation { continuation in
            var observation: NSKeyValueObservation?
            var timeoutTask: Task<Void, Never>?
            var resumed = false
            let lock = NSLock()

            func resume(with value: Bool) {
                lock.lock()
                guard !resumed else { lock.unlock(); return }
                resumed = true
                lock.unlock()
                observation?.invalidate()
                timeoutTask?.cancel()
                continuation.resume(returning: value)
            }

            observation = item.observe(\.status, options: [.new]) { item, _ in
                switch item.status {
                case .readyToPlay:
                    print("[Player] waitReady: readyToPlay")
                    resume(with: true)
                case .failed:
                    print("[Player] waitReady: FAILED — \(item.error?.localizedDescription ?? "unknown")")
                    resume(with: false)
                default:
                    break
                }
            }

            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                let s = item.status.rawValue
                print("[Player] waitReady: TIMEOUT after \(Int(timeout))s — status=\(s) bufEmpty=\(item.isPlaybackBufferEmpty) keepUp=\(item.isPlaybackLikelyToKeepUp)")
                resume(with: false)
            }
        }
    }

    /// Load content using the appropriate path from the playback plan.
    ///
    /// Two paths:
    /// 1. **Aether** — the engine demuxes the direct-play URL itself
    /// 2. **Plex HLS** — AVPlayer opens the Plex transcode URL (primary
    ///    when no direct-play URL exists; fallback after an Aether failure)
    private func startWithFallback(plan: PlaybackPlan, startTime: TimeInterval?) async throws {
        switch plan.primary {
        case .hls:
            if streamURL == nil, let builtHLS = buildRivuletHLSURL(offset: startTime) {
                streamURL = builtHLS.url
                streamHeaders = builtHLS.headers
                plexSessionId = builtHLS.sessionId
            }
            guard let hlsURL = streamURL else {
                throw PlayerError.loadFailed("Unable to build HLS URL")
            }

            let transcodeReady = await waitForHLSTranscodeReady(url: hlsURL, headers: streamHeaders)
            if !transcodeReady {
                // HLS as the PRIMARY route (no direct-play URL existed), not a
                // fallback. Tagged separately from `fallback_preflight_failed`
                // so the two don't grind together in one Sentry issue: this one
                // means the server is slow, that one means Aether ALSO broke.
                let error = PlayerError.loadFailed("HLS transcode session failed to start")
                diagnostics.step("hls_primary_preflight_failed")
                diagnostics.capture(error, event: "primary_preflight_failed", extraTags: [
                    "player_type": "avplayer"
                ])
                throw error
            }

            // Log the HLS master manifest for debugging track labels and I-frame playlists
            await logHLSManifest(url: hlsURL, headers: streamHeaders)

            try loadAVPlayer(url: hlsURL, headers: streamHeaders)

            if let startTime, startTime > 0 {
                await player?.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
            }

        case .aether(let url, let headers):
            let aetherURL = streamURL ?? url
            let aetherHeaders = streamHeaders.isEmpty ? (headers ?? rivuletDirectPlayHeaders()) : streamHeaders
            do {
                let ap = aetherPlayer ?? AetherPlayer()
                aetherPlayer = ap
                bindAetherPublishers(ap)
                // Feed title/artwork/description to Aether's internal AVPlayerItem
                // (it makes its own item, so our native-path externalMetadata never
                // reaches it). Set before load so Aether stashes + replays it.
                ap.setExternalMetadata(buildExternalMetadata())
                try await ap.load(
                    url: aetherURL,
                    headers: aetherHeaders,
                    startTime: startTime,
                    subtitleLanguageHintsByStreamIndex: aetherSubtitleLanguageHintsByStreamIndex(),
                    preferredAudioLanguages: aetherPreferredAudioLanguages(),
                    preferredSubtitleLanguages: aetherPreferredSubtitleLanguages(),
                    externalSubtitles: aetherExternalSubtitles()
                )
            } catch {
                let kind = classifyDirectPlayFailure(error)
                // Record the ORIGINAL Aether failure before doing anything else.
                // This is the root cause of RIVULET-19: previously `error` was
                // classified and then discarded, so if the HLS fallback ALSO
                // failed we reported the fallback's error and destroyed the only
                // evidence of why direct play died in the first place.
                diagnostics.recordPrimaryFailure(error, kind: kind, route: "aether")
                guard planHasHLSFallback(plan) else { throw error }
                try await attemptRivuletHLSFallback(
                    resumeTime: startTime ?? 0,
                    reason: "aether_startup_load_failed",
                    failureKind: kind
                )
                return
            }
        }
    }

    /// Plex external (sidecar) subtitle streams, registered with the engine
    /// at load as first-class tracks. External streams are the ones with a
    /// `key` (a /library/streams path served by the Plex server) — they are
    /// NOT inside the media container, so the engine can't discover them by
    /// demuxing. Registration order == metadata stream order, which is what
    /// lets `TrackMerge` pair each sidecar with its Plex stream by ordinal.
    private func aetherExternalSubtitles() -> [AetherPlayer.SidecarSubtitle] {
        guard let streams = metadata.Media?.first?.Part?.first?.Stream else { return [] }
        return streams.filter { $0.isSubtitle && $0.key != nil }.compactMap { stream in
            guard let key = stream.key,
                  var components = URLComponents(string: "\(serverURL)\(key)") else { return nil }
            components.queryItems = (components.queryItems ?? [])
                + [URLQueryItem(name: "X-Plex-Token", value: authToken)]
            guard let url = components.url else { return nil }
            return AetherPlayer.SidecarSubtitle(
                url: url,
                name: stream.displayTitle ?? stream.extendedDisplayTitle,
                language: stream.languageCode ?? stream.language,
                isForced: stream.forced ?? false,
                isHearingImpaired: stream.hearingImpaired ?? false,
                isDefault: stream.default ?? false,
                formatHint: stream.codec
            )
        }
    }

    private func aetherSubtitleLanguageHintsByStreamIndex() -> [Int: String] {
        guard let streams = metadata.Media?.first?.Part?.first?.Stream else { return [:] }

        var hints: [Int: String] = [:]
        for stream in streams where stream.isSubtitle {
            guard let index = stream.index else { continue }
            let language = [stream.languageTag, stream.languageCode, stream.language]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
            if let language {
                hints[index] = language
            }
        }
        return hints
    }

    private func aetherPreferredAudioLanguages() -> [String] {
        var languages: [String] = []

        if let id = initialAudioTrackId,
           let track = plexAudioTracksFromMetadata().first(where: { $0.id == id }) {
            languages.append(contentsOf: languageCandidates(for: track))
        }

        languages.append(TrackIntentStore.effectiveAudioIntent.language)

        if let selected = plexAudioTracksFromMetadata().first(where: { $0.isDefault }) {
            languages.append(contentsOf: languageCandidates(for: selected))
        }

        return uniqueNonEmpty(languages)
    }

    private func aetherPreferredSubtitleLanguages() -> [String] {
        var languages: [String] = []

        switch initialSubtitleSelection {
        case .track(let id):
            if let track = plexSubtitleTracksFromMetadata().first(where: { $0.id == id }) {
                languages.append(contentsOf: languageCandidates(for: track))
            }
        case .off:
            return []
        case .auto:
            break
        }

        switch TrackIntentStore.subtitleIntent {
        case let .track(language, _, _, _) where !language.isEmpty:
            languages.append(language)
        case .off:
            break
        case .track, .none:
            // No stored intent (or an intent with no usable language): fall
            // back to the file's forced/default subtitle stream.
            if let selected = plexSubtitleTracksFromMetadata()
                .first(where: { $0.isForced || $0.isDefault }) {
                languages.append(contentsOf: languageCandidates(for: selected))
            }
        }

        return uniqueNonEmpty(languages)
    }

    private func languageCandidates(for track: MediaTrack) -> [String] {
        [track.languageCode, track.language]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// Subscribe to Aether's player surface so the view model's
    /// universal state (playbackState, currentTime, errors) mirrors the
    /// engine. Called whenever a fresh AetherPlayer is created in
    /// startWithFallback.
    private func bindAetherPublishers(_ player: AetherPlayer) {
        player.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                // End-of-stream must route through `updatePlaybackState(.ended)`
                // (not direct assignment) so the EOF -> `handlePlaybackEnded`
                // chain fires for Aether: mark-watched + Plex scrobble + next-up
                // post-video. Aether surfaces this via `PlaybackState.ended`
                // (AetherEngine 4.0.0, #63); before that the engine collapsed
                // end-of-media to `.idle` and this never fired. Every other
                // state keeps the existing direct assignment so Aether's
                // loading/seeking behavior is unchanged.
                if state == .ended {
                    self.updatePlaybackState(.ended)
                } else if state == .playing, player.isBuffering {
                    self.updatePlaybackState(.buffering)
                } else {
                    self.updatePlaybackState(state)
                }
            }
            .store(in: &cancellables)

        player.timePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.currentTime = time
                // Drive marker handling for Aether (skip intro/credits/ad buttons,
                // auto-skip, and the real Plex credits-marker post-video trigger).
                // Mirrors the AVPlayer periodic observer (~line 979). Aether
                // ticks at 0.1s (native host)
                // or 0.25s (software host), both finer than checkMarkers' ~0.5s
                // assumption, so no throttle change is needed.
                self?.checkMarkers(at: time)
                self?.tickReplayWindow(at: time)
            }
            .store(in: &cancellables)

        player.durationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dur in
                if dur > 0 { self?.duration = dur }
            }
            .store(in: &cancellables)

        player.errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] err in
                self?.errorMessage = err.userFacingDescription
            }
            .store(in: &cancellables)

        // Subtitle overlay feed: Aether decodes cues (text and PGS/DVB
        // bitmap) and publishes them; the host renders via
        // AetherSubtitleOverlayView driven by this model. sourceTime shares
        // the engine clock tick so cue lookup can't drift from playback.
        player.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                self?.aetherSubtitleModel.update(cues: cues)
            }
            .store(in: &cancellables)

        player.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                self?.aetherSubtitleModel.sourceTime = t
            }
            .store(in: &cancellables)

        // Up Next early resolve. The playhead must know the next episode
        // BEFORE the credits marker so the overlay can present without a
        // fetch stall. Guarded to run once per episode; the publisher
        // re-emits on every Aether AVPlayer swap.
        player.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avp in
                guard let self, avp != nil else { return }  // native route only
                Task { await self.resolveNextEpisodeEarlyIfNeeded() }
            }
            .store(in: &cancellables)

        // Engine track lists. Both funnel through updateTrackLists(), which
        // merges them with Plex's streams into ONE list per type (engine index
        // as the id, Plex's forced/SDH/commentary labels folded on). Either
        // side can arrive first, so the merge re-runs on each.
        player.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                guard let self, !tracks.isEmpty else { return }
                self.updateTrackLists()
            }
            .store(in: &cancellables)

        player.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                guard let self, !tracks.isEmpty else { return }
                self.updateTrackLists()
            }
            .store(in: &cancellables)

        player.$activeAudioTrackId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self, let id else { return }
                self.currentAudioTrackId = id
            }
            .store(in: &cancellables)

        player.$activeSubtitleTrackId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                // Ignore engine-originated nil, exactly as the audio sink above
                // does. The engine transiently clears its active subtitle index
                // to nil while it rebuilds the pipeline (e.g. on an audio-track
                // change) and then re-arms the same subtitle — but that nil
                // would otherwise flip our UI to "off" even though captions keep
                // rendering. A genuine user turn-off sets currentSubtitleTrackId
                // directly via selectSubtitleTrackWithoutSaving, not through this
                // mirror sink, so dropping nil here doesn't miss real off events.
                guard let self, let id else { return }
                // Track ids ARE engine indices on this route (see TrackMerge) —
                // the engine's active index needs no translation.
                self.currentSubtitleTrackId = id
            }
            .store(in: &cancellables)

        player.$isBuffering
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak player] buffering in
                guard let self, let player else { return }
                self.handleAetherBufferingChanged(buffering, player: player)
            }
            .store(in: &cancellables)
    }

    // MARK: - HLS Manifest Debugging

    /// Fetch and log the HLS master manifest to inspect track labels and I-frame playlists.
    private func logHLSManifest(url: URL, headers: [String: String]) async {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let manifest = String(data: data, encoding: .utf8) {
                print("[HLS Manifest] ===== Master Playlist =====")
                for line in manifest.components(separatedBy: "\n") {
                    print("[HLS Manifest] \(line)")
                }
                print("[HLS Manifest] ===== End =====")

                // Quick summary
                let hasIFrame = manifest.contains("EXT-X-I-FRAME")
                let audioTags = manifest.components(separatedBy: "\n").filter { $0.contains("TYPE=AUDIO") }
                let subtitleTags = manifest.components(separatedBy: "\n").filter { $0.contains("TYPE=SUBTITLES") }
                print("[HLS Manifest] I-Frame playlist: \(hasIFrame ? "YES" : "NO")")
                print("[HLS Manifest] Audio tracks: \(audioTags.count)")
                print("[HLS Manifest] Subtitle tracks: \(subtitleTags.count)")

                // Also fetch and log keyframe playlist if present
                if let iframeLine = manifest.components(separatedBy: "\n")
                    .first(where: { $0.contains("EXT-X-I-FRAME-STREAM-INF") }),
                   let uriRange = iframeLine.range(of: "URI=\""),
                   let endQuote = iframeLine[uriRange.upperBound...].firstIndex(of: "\"") {
                    let keyframeRelative = String(iframeLine[uriRange.upperBound..<endQuote])
                    let keyframeURL: URL?
                    if keyframeRelative.contains("://") {
                        keyframeURL = URL(string: keyframeRelative)
                    } else {
                        keyframeURL = URL(string: keyframeRelative, relativeTo: url.deletingLastPathComponent())
                    }
                    if let kfURL = keyframeURL {
                        var kfRequest = URLRequest(url: kfURL)
                        for (key, value) in headers { kfRequest.setValue(value, forHTTPHeaderField: key) }
                        if let (kfData, _) = try? await URLSession.shared.data(for: kfRequest),
                           let kfManifest = String(data: kfData, encoding: .utf8) {
                            let kfLines = kfManifest.components(separatedBy: "\n")
                            print("[HLS Manifest] ===== Keyframe Playlist (\(kfLines.count) lines) =====")
                            for line in kfLines.prefix(20) { print("[HLS Manifest/KF] \(line)") }
                            if kfLines.count > 20 { print("[HLS Manifest/KF] ... (\(kfLines.count - 20) more lines)") }
                        }
                    }
                }
            }
        } catch {
            print("[HLS Manifest] Failed to fetch: \(error.localizedDescription)")
        }
    }

    // MARK: - AVPlayer Creation

    /// Create an AVPlayer for a URL (direct play or HLS).
    private func loadAVPlayer(url: URL, headers: [String: String]?) throws {
        teardownAVPlayerObservers()
        player?.pause()
        hlsManifestEnricher = nil

        let asset: AVURLAsset

        // For HLS URLs, use the manifest enricher to inject audio/subtitle track labels.
        // The enricher intercepts ONLY the master playlist (custom scheme), patches it,
        // and rewrites all sub-URLs to absolute HTTP so AVPlayer fetches them directly.
        if url.path.contains("start.m3u8") || url.pathExtension == "m3u8",
           let headers = headers {
            let enricher = HLSManifestEnricher(metadata: metadata, headers: headers, originalURL: url)
            if let enrichedURL = enricher.enrichedURL(from: url) {
                hlsManifestEnricher = enricher
                asset = AVURLAsset(url: enrichedURL)
                asset.resourceLoader.setDelegate(enricher, queue: DispatchQueue(label: "com.rivulet.hls-enricher"))
            } else {
                var options: [String: Any] = [:]
                options["AVURLAssetHTTPHeaderFieldsKey"] = headers
                asset = AVURLAsset(url: url, options: options)
            }
        } else {
            var options: [String: Any] = [:]
            if let headers = headers, !headers.isEmpty {
                options["AVURLAssetHTTPHeaderFieldsKey"] = headers
            }
            asset = AVURLAsset(url: url, options: options)
        }

        let item = AVPlayerItem(asset: asset)

        // Feed metadata to AVPlayerViewController (info panel + Now Playing)
        item.externalMetadata = buildExternalMetadata()
        if let markers = buildNavigationMarkers() {
            item.navigationMarkerGroups = markers
        }

        if let existing = player {
            existing.replaceCurrentItem(with: item)
        } else {
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            _playerForCleanup = newPlayer
        }

        setupAVPlayerObservers()
        updatePlaybackState(.loading)
    }

    // MARK: - AVPlayerItem Metadata

    /// Build external metadata for AVPlayerViewController info panel and Now Playing.
    private func buildExternalMetadata() -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        // Title
        let displayTitle: String
        if metadata.type == "episode" {
            let seasonNum = metadata.parentIndex ?? 0
            let episodeNum = metadata.index ?? 0
            let epTitle = metadata.title ?? ""
            displayTitle = "S\(seasonNum) E\(episodeNum) · \(epTitle)"
        } else {
            displayTitle = metadata.title ?? ""
        }
        items.append(makeMetadataItem(.commonIdentifierTitle, value: displayTitle))

        // Show name (for episodes)
        if metadata.type == "episode", let showName = metadata.grandparentTitle {
            items.append(makeMetadataItem(
                .iTunesMetadataTrackSubTitle,
                value: showName
            ))
        }

        // Description
        if let summary = metadata.summary {
            items.append(makeMetadataItem(.commonIdentifierDescription, value: summary))
        }

        // Genre
        if let genres = metadata.Genre, !genres.isEmpty {
            let genreString = genres.compactMap(\.tag).joined(separator: ", ")
            if !genreString.isEmpty {
                items.append(makeMetadataItem(.quickTimeMetadataGenre, value: genreString))
            }
        }

        // Content rating
        if let rating = metadata.contentRating {
            items.append(makeMetadataItem(
                .iTunesMetadataContentRating,
                value: rating
            ))
        }

        // Year. commonIdentifierCreationDate is a DATE-typed key; passing a
        // bare "2025" string makes AVKit misparse it (it rendered a wrong
        // year, e.g. 2042). Hand it a real Date (Jan 1 of the year).
        if let year = metadata.year {
            var comps = DateComponents()
            comps.year = year
            comps.month = 1
            comps.day = 1
            if let date = Calendar(identifier: .gregorian).date(from: comps) {
                items.append(makeMetadataItem(.commonIdentifierCreationDate, value: date as NSDate))
            }
        }

        // Artwork — for episodes use season/show poster, for movies use poster/backdrop
        if let image = nowPlayingArtwork(),
           let jpegData = image.jpegData(compressionQuality: 0.85) {
            items.append(makeMetadataItem(.commonIdentifierArtwork, value: jpegData))
        }

        // Audio format description — helps AVPlayerViewController label the audio track
        let audioDesc = buildAudioDescription()
        if !audioDesc.isEmpty {
            items.append(makeMetadataItem(
                .quickTimeMetadataInformation,
                value: audioDesc
            ))
        }

        return items
    }

    /// Select the best artwork image for Now Playing.
    /// Episodes: season poster → show poster → episode thumb → backdrop
    /// Movies: poster (thumb) → backdrop
    private func nowPlayingArtwork() -> UIImage? {
        if metadata.type == "episode" {
            // Prefer season/show poster over episode screenshot for Now Playing
            if let poster = seasonPosterImage { return poster }
        }
        return loadingThumbImage ?? loadingArtImage
    }

    /// Fetch the season or show poster for episode Now Playing artwork.
    /// Called before building external metadata so the image is ready.
    private func fetchSeasonPosterIfNeeded() async {
        guard metadata.type == "episode" else { return }

        // Try season poster first, then show poster
        let posterPath = metadata.parentThumb ?? metadata.grandparentThumb
        guard let path = posterPath else { return }

        let urlString = "\(serverURL)\(path)?X-Plex-Token=\(authToken)"
        guard let url = URL(string: urlString) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                seasonPosterImage = image
            }
        } catch {
            // Fall through to episode thumb/backdrop
        }
    }

    /// Resolve the title logo for the transport bar's ambient-pause swap:
    /// prefer the Plex-provided clearLogo image (same precedence as the
    /// home hero and media detail chrome), falling back to TMDB's images
    /// API via `TMDBLogoCache` when Plex doesn't carry one. Cancels any
    /// in-flight resolve from a previous item so an episode swap can't
    /// stomp the new item's result with a stale one.
    private func fetchTitleLogoIfNeeded() {
        titleLogoResolveTask?.cancel()
        titleLogoImage = nil

        if let logoPath = metadata.clearLogoPath,
           let url = URL(string: "\(serverURL)\(logoPath)?X-Plex-Token=\(authToken)") {
            titleLogoResolveTask = Task { [weak self] in
                guard let image = await ImageCacheManager.shared.image(for: url) else { return }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.titleLogoImage = image
                }
            }
            return
        }

        // TMDB-mapped items (or episodes, which carry no logo of their own —
        // fall back to the parent show's tmdbId) resolve via the shared cache.
        guard let tmdbID = metadata.tmdbId ?? metadata.parentShowTmdbId ?? metadata.showTmdbId else { return }
        let type: TMDBMediaType = metadata.type == "movie" ? .movie : .tv
        titleLogoResolveTask = Task { [weak self] in
            guard let url = await TMDBLogoCache.shared.logoURL(tmdbId: tmdbID, type: type) else { return }
            guard !Task.isCancelled else { return }
            guard let image = await ImageCacheManager.shared.image(for: url) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.titleLogoImage = image
            }
        }
    }

    /// Build a human-readable audio description from metadata.
    private func buildAudioDescription() -> String {
        let codec = metadata.Media?.first?.audioCodec?.uppercased() ?? ""
        let channels = metadata.Media?.first?.audioChannels ?? 0

        guard !codec.isEmpty else { return "" }

        let codecName: String
        switch codec {
        case "EAC3", "EC-3": codecName = "Dolby Digital+"
        case "AC3": codecName = "Dolby Digital"
        case "AAC": codecName = "AAC"
        case "DTS": codecName = "DTS"
        case "DTS-HD", "DTSHD": codecName = "DTS-HD MA"
        case "TRUEHD", "MLP": codecName = "Dolby TrueHD"
        case "FLAC": codecName = "FLAC"
        default: codecName = codec
        }

        let channelDesc: String
        switch channels {
        case 8: channelDesc = "7.1"
        case 6: channelDesc = "5.1"
        case 2: channelDesc = "Stereo"
        case 1: channelDesc = "Mono"
        default: channelDesc = channels > 0 ? "\(channels)ch" : ""
        }

        if channelDesc.isEmpty {
            return codecName
        }
        return "\(codecName) \(channelDesc)"
    }

    /// Fetch chapter thumbnail images from Plex with limited concurrency.
    /// Uses a concurrency limit to avoid N+1 API call patterns flagged by Sentry.
    private func fetchChapterThumbnails(chapters: [PlexChapter]) async {
        let thumbChapters = chapters.filter { $0.thumb != nil && $0.index != nil }
        let thumbCount = thumbChapters.count
        guard thumbCount > 0 else { return }
        print("[Chapters] Fetching \(thumbCount) chapter thumbnails (max 3 concurrent)...")

        // Use a limited concurrency approach to avoid N+1 API call detection
        let maxConcurrency = 3

        await withTaskGroup(of: (Int, Data?).self) { group in
            var iterator = thumbChapters.makeIterator()
            var inFlight = 0

            // Seed initial batch
            while inFlight < maxConcurrency, let chapter = iterator.next() {
                guard let index = chapter.index, let thumbPath = chapter.thumb else { continue }
                let url = URL(string: "\(serverURL)\(thumbPath)?X-Plex-Token=\(authToken)")
                guard let url else { continue }

                group.addTask {
                    do {
                        let (data, _) = try await URLSession.shared.data(from: url)
                        return (index, data)
                    } catch {
                        return (index, nil)
                    }
                }
                inFlight += 1
            }

            // As each completes, start the next
            for await (index, data) in group {
                if let data {
                    chapterThumbnails[index] = data
                }
                inFlight -= 1

                // Start next fetch if available
                if let chapter = iterator.next() {
                    guard let nextIndex = chapter.index, let thumbPath = chapter.thumb else { continue }
                    let url = URL(string: "\(serverURL)\(thumbPath)?X-Plex-Token=\(authToken)")
                    guard let url else { continue }

                    group.addTask {
                        do {
                            let (data, _) = try await URLSession.shared.data(from: url)
                            return (nextIndex, data)
                        } catch {
                            return (nextIndex, nil)
                        }
                    }
                    inFlight += 1
                }
            }
        }

        print("[Chapters] Fetched \(chapterThumbnails.count)/\(thumbCount) chapter thumbnails")
    }

    /// Build navigation markers from Plex chapters (preferred) or intro/credits markers (fallback).
    private func buildNavigationMarkers() -> [AVNavigationMarkersGroup]? {
        // Prefer real chapters from the media file (Plex returns these at metadata level, not Part level)
        let chapters = metadata.Chapter ?? []
        if !chapters.isEmpty {
            let timedGroups: [AVTimedMetadataGroup] = chapters.compactMap { chapter in
                guard let startMs = chapter.startTimeOffset,
                      let endMs = chapter.endTimeOffset else { return nil }

                let start = CMTime(value: CMTimeValue(startMs), timescale: 1000)
                let end = CMTime(value: CMTimeValue(endMs), timescale: 1000)
                let range = CMTimeRange(start: start, end: end)

                let title = chapter.tag ?? "Chapter \(chapter.index ?? 0)"
                var items = [makeMetadataItem(.commonIdentifierTitle, value: title)]

                if let index = chapter.index, let imageData = chapterThumbnails[index] {
                    items.append(makeMetadataItem(.commonIdentifierArtwork, value: imageData))
                }

                return AVTimedMetadataGroup(items: items, timeRange: range)
            }
            if !timedGroups.isEmpty {
                return [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: timedGroups)]
            }
        }

        // Fall back to Plex markers (intro, credits)
        guard let markers = metadata.Marker, !markers.isEmpty else { return nil }

        let timedGroups: [AVTimedMetadataGroup] = markers.compactMap { marker in
            guard let startMs = marker.startTimeOffset,
                  let endMs = marker.endTimeOffset else { return nil }

            let start = CMTime(value: CMTimeValue(startMs), timescale: 1000)
            let end = CMTime(value: CMTimeValue(endMs), timescale: 1000)
            let range = CMTimeRange(start: start, end: end)

            let titleItem = makeMetadataItem(.commonIdentifierTitle, value: marker.type?.capitalized ?? "Marker")
            return AVTimedMetadataGroup(items: [titleItem], timeRange: range)
        }

        guard !timedGroups.isEmpty else { return nil }
        return [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: timedGroups)]
    }

    /// Helper to create an AVMutableMetadataItem.
    private func makeMetadataItem(_ identifier: AVMetadataIdentifier, value: Any) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as? NSCopying & NSObjectProtocol
        item.extendedLanguageTag = "und"
        return item.copy() as! AVMetadataItem
    }

    /// One-shot fallback path to Plex HLS.
    private func attemptRivuletHLSFallback(
        resumeTime: TimeInterval,
        reason: String,
        failureKind: DirectPlayFailureKind
    ) async throws {
        guard !isAttemptingRivuletHLSFallback else {
            throw PlayerError.loadFailed("HLS fallback already in progress")
        }
        guard !hasAttemptedRivuletHLSFallback else {
            throw PlayerError.loadFailed("Already attempted HLS fallback")
        }

        isAttemptingRivuletHLSFallback = true
        hasAttemptedRivuletHLSFallback = true
        defer { isAttemptingRivuletHLSFallback = false }

        print("[Fallback] Failed (\(failureKind.rawValue), reason=\(reason)) → HLS")

        let fallback: (url: URL, headers: [String: String], sessionId: String?)?
        if resumeTime <= 0.5, let prebuiltURL = rivuletFallbackURL, !rivuletFallbackHeaders.isEmpty {
            let sessionId = URLComponents(url: prebuiltURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "session" })?.value
            fallback = (prebuiltURL, rivuletFallbackHeaders, sessionId)
        } else {
            fallback = buildRivuletHLSURL(offset: resumeTime)
        }

        guard let fallback else {
            throw PlayerError.loadFailed("Unable to build HLS fallback URL")
        }

        // Stop current player. The Aether engine session must be torn down
        // explicitly: leaving it running keeps its audio playing under the
        // fallback AVPlayer and keeps the render surface claimed by a dead
        // session (UniversalPlayerView switches surfaces on aetherPlayer == nil).
        aetherPlayer?.stop()
        aetherPlayer = nil
        teardownAVPlayerObservers()
        player?.pause()

        streamURL = fallback.url
        streamHeaders = fallback.headers
        plexSessionId = fallback.sessionId

        diagnostics.step("hls_fallback_preflight", detail: "reason=\(reason) kind=\(failureKind.rawValue)")
        let transcodeReady = await waitForHLSTranscodeReady(url: fallback.url, headers: fallback.headers)
        if !transcodeReady {
            // RIVULET-19. Capture with the full causal chain: the Aether failure
            // that sent us here, plus what the server said on all 8 preflight
            // polls. Reported as `fallback_preflight_failed` — the user got
            // NOTHING, both routes died.
            let error = PlayerError.loadFailed("HLS transcode session failed to start")
            diagnostics.step("hls_fallback_preflight_failed")
            diagnostics.capture(error, event: "fallback_preflight_failed", extraTags: [
                "fallback_reason": reason,
                "player_type": "avplayer"
            ])
            throw error
        }
        diagnostics.step("hls_fallback_preflight_ready")

        try loadAVPlayer(url: fallback.url, headers: fallback.headers)
        if resumeTime > 0 {
            await player?.seek(to: CMTime(seconds: resumeTime, preferredTimescale: 600))
        }
    }

    // MARK: - HLS Transcode Preflight

    /// Wait for the HLS transcode session to be ready before loading playback.
    /// Plex needs time to start the transcoder and generate the initial manifest and segments.
    /// This method verifies both the manifest and at least one segment are accessible
    /// - Parameters:
    ///   - url: The HLS manifest URL
    ///   - headers: HTTP headers including auth token
    /// - Returns: true if the transcode is ready, false if it failed to start
    private func waitForHLSTranscodeReady(url: URL, headers: [String: String]) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        // Add auth headers
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }

        // Try up to 8 times with delays to give Plex time to start the transcode
        for attempt in 1...8 {
            do {

                let (data, response) = try await URLSession.shared.data(for: request)

                if let httpResponse = response as? HTTPURLResponse {

                    if httpResponse.statusCode == 200 && data.count > 0 {
                        if let content = String(data: data, encoding: .utf8) {
                            // Check for valid HLS manifest with actual content
                            let hasHeader = content.contains("#EXTM3U")
                            let hasVariants = content.contains(".m3u8")
                            let hasSegments = content.contains("#EXTINF")

                            if hasHeader && hasVariants {
                                // This is a master playlist - follow a variant to check for segments
                                if let variantReady = await checkVariantPlaylist(masterContent: content, baseURL: url, headers: headers), variantReady {
                                    diagnostics.recordPreflightAttempt(attempt, outcome: "ready (variant has segments)")
                                    return true
                                } else {
                                    // Master resolved but the variant has no #EXTINF yet:
                                    // the transcoder started but is not producing segments.
                                    // Distinct from a 404, and the likeliest RIVULET-19 shape.
                                    diagnostics.recordPreflightAttempt(attempt, outcome: "200 master, variant has NO segments (transcoder starving)")
                                }
                            } else if hasHeader && hasSegments {
                                // This is already a media playlist with segments
                                diagnostics.recordPreflightAttempt(attempt, outcome: "ready (media playlist has segments)")
                                return true
                            } else if hasHeader {
                                // Has header but no content yet
                                diagnostics.recordPreflightAttempt(attempt, outcome: "200 manifest header only, no variants/segments")
                            } else {
                                print("🎬 [HLSPreflight] Invalid manifest content")
                                // A 200 that is not a manifest is usually a Plex HTML
                                // error page. Record a prefix so we can tell.
                                let prefix = content.prefix(120).replacingOccurrences(of: "\n", with: " ")
                                diagnostics.recordPreflightAttempt(attempt, outcome: "200 but NOT a manifest: \(prefix)")
                            }
                        } else {
                            diagnostics.recordPreflightAttempt(attempt, outcome: "200 but body is not UTF-8 (\(data.count) bytes)")
                        }
                    } else if httpResponse.statusCode == 404 || httpResponse.statusCode == 503 {
                        // Transcode not started yet
                        diagnostics.recordPreflightAttempt(attempt, outcome: "HTTP \(httpResponse.statusCode) (transcode not started)")
                    } else {
                        print("🎬 [HLSPreflight] Unexpected status \(httpResponse.statusCode)")
                        diagnostics.recordPreflightAttempt(attempt, outcome: "HTTP \(httpResponse.statusCode) (unexpected)")
                    }
                }
            } catch {
                print("🎬 [HLSPreflight] Error: \(error.localizedDescription)")
                let nsError = error as NSError
                diagnostics.recordPreflightAttempt(
                    attempt,
                    outcome: "transport error \(nsError.domain) code=\(nsError.code): \(error.localizedDescription)"
                )
            }

            // Wait before retrying (increasing delay: 0.5s, 1s, 1.5s, 2s, 2.5s, 3s, 3.5s, 4s)
            if attempt < 8 {
                let delay = Double(attempt) * 0.5
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        print("🎬 [HLSPreflight] Transcode failed to start after 8 attempts")
        return false
    }

    /// Check if a variant playlist has actual segments ready
    private func checkVariantPlaylist(masterContent: String, baseURL: URL, headers: [String: String]) async -> Bool? {
        // Parse the master playlist to find a variant playlist URL
        let lines = masterContent.components(separatedBy: .newlines)
        var variantURL: URL?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(".m3u8") && !trimmed.hasPrefix("#") {
                // Construct the full URL for the variant
                if let url = URL(string: trimmed, relativeTo: baseURL) {
                    variantURL = url.absoluteURL
                    break
                }
            }
        }

        guard let variant = variantURL else {
            print("🎬 [HLSPreflight] No variant playlist URL found in master")
            return nil
        }

        var request = URLRequest(url: variant)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200,
               let content = String(data: data, encoding: .utf8) {

                // Check if variant playlist has actual segments
                let hasSegments = content.contains("#EXTINF")
                let hasMediaContent = content.contains(".mp4") || content.contains(".ts") || content.contains(".m4s")

                if hasSegments && hasMediaContent {
                    return true
                } else {
                    return false
                }
            } else {
                return false
            }
        } catch {
            print("🎬 [HLSPreflight] Failed to fetch variant: \(error.localizedDescription)")
            return false
        }
    }

    func stopPlayback() {
        streamPreparationTask?.cancel()
        streamPreparationTask = nil
        aetherStallWatchdogTask?.cancel()
        aetherStallWatchdogTask = nil
        titleLogoResolveTask?.cancel()
        titleLogoResolveTask = nil
        subtitleClockSync.stop()
        clearReplayWindow()

        // Clear the active playback route from the App Hang scope (RIVULET-41).
        AppHangContext.setPlaybackRoute(nil)

        // Stop AetherPlayer if active
        aetherPlayer?.stop()
        aetherPlayer = nil
        aetherSubtitleModel.update(cues: [])

        teardownAVPlayerObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        _playerForCleanup = nil
        hlsManifestEnricher = nil
        subtitleManager.clear()

        // Stop the Plex transcode session so the server frees resources immediately.
        // Without this, switching between DV files can timeout waiting for the init segment
        // because the server is still busy with the previous transcode.
        if let sessionId = plexSessionId {
            let serverURL = self.serverURL
            let authToken = self.authToken
            plexSessionId = nil
            Task {
                await PlexNetworkManager.shared.stopTranscodeSession(
                    serverURL: serverURL,
                    authToken: authToken,
                    sessionId: sessionId
                )
            }
        }

        controlsTimer?.invalidate()
        wheelScrubbingTimer?.invalidate()
        wheelScrubbingTimer = nil
        wheelScrubbing = false
        hideCompatibilityNotice()

        // Reset display criteria to default (allows TV to return to normal mode)
        DisplayCriteriaManager.shared.reset()

        // Re-enable screensaver
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func togglePlayPause() {
        hidePausedPoster()
        if isPlaying {
            activePlayer_pause()
        } else {
            activePlayer_play()
        }
        showControlsTemporarily()
    }

    /// Resume playback (used by remote commands)
    func resume() {
        pausedDueToAppInactive = false
        hidePausedPoster()
        activePlayer_play()
        showControlsTemporarily()
    }

    /// Pause playback (used by remote commands)
    func pause() {
        activePlayer_pause()
        showControlsTemporarily()
    }

    // MARK: - Active Player Helpers

    private func activePlayer_play() {
        if let ap = aetherPlayer {
            ap.play()
            return
        }
        player?.play()
    }

    private func activePlayer_pause() {
        if let ap = aetherPlayer {
            ap.pause()
            return
        }
        player?.pause()
    }

    private func handleAetherBufferingChanged(_ buffering: Bool, player: AetherPlayer) {
        guard aetherPlayer === player else { return }

        if buffering {
            updatePlaybackState(.buffering)
            startAetherStallWatchdog(for: player)
        } else {
            aetherStallWatchdogTask?.cancel()
            aetherStallWatchdogTask = nil
            if playbackState == .buffering {
                updatePlaybackState(player.isPlaying ? .playing : .paused)
            }
        }
    }

    private func startAetherStallWatchdog(for player: AetherPlayer) {
        aetherStallWatchdogTask?.cancel()
        let baselineTime = currentTime
        aetherStallWatchdogTask = Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }

            try? await Task.sleep(nanoseconds: UInt64(self.aetherStallRecoveryDelay * 1_000_000_000))
            guard !Task.isCancelled,
                  self.aetherPlayer === player,
                  player.isBuffering else { return }

            let recoveryTime = self.currentTime
            guard recoveryTime <= baselineTime + 0.5 else { return }

            let kickTarget = min(max(0, recoveryTime + 0.1), max(player.duration, recoveryTime))
            await player.seek(to: kickTarget)
            player.play()

            try? await Task.sleep(nanoseconds: UInt64(self.aetherStallFailureDelay * 1_000_000_000))
            guard !Task.isCancelled,
                  self.aetherPlayer === player,
                  player.isBuffering,
                  self.currentTime <= recoveryTime + 0.5 else { return }

            let error = PlayerError.networkError("Aether playback stalled while waiting for buffered media")
            self.errorMessage = error.userFacingDescription
            self.updatePlaybackState(.failed(error))
        }
    }

    /// - Parameter revealsControls: whether the seek should surface the
    ///   transport chrome (the normal reveal-the-scrubber affordance). A marker
    ///   skip taken while the chrome is hidden passes `false` so the jump
    ///   doesn't pop the rail open.
    func seek(to time: TimeInterval, revealsControls: Bool = true) async {
        if let ap = aetherPlayer {
            await ap.seek(to: time)
        } else {
            await player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        }
        subtitleClockSync.didSeek()
        if revealsControls { showControlsTemporarily() }
    }

    func seekRelative(by seconds: TimeInterval) async {
        hidePausedPoster()
        let targetTime = max(0, min(currentTime + seconds, duration))
        if let ap = aetherPlayer {
            await ap.seek(to: targetTime)
        } else {
            await player?.seek(to: CMTime(seconds: targetTime, preferredTimescale: 600))
        }
        subtitleClockSync.didSeek()
        showControlsTemporarily()

        // Show seek indicator for tap-to-skip
        let intSeconds = Int(abs(seconds))
        showSeekIndicator(seconds >= 0 ? .forward(intSeconds) : .backward(intSeconds))
    }

    /// "What did they say?" — jump back 15s with subtitles temporarily on,
    /// auto-reverting once playback passes the point this was invoked
    /// from. A repeat invocation while already inside a window extends
    /// the revert point rather than layering a second window on top.
    /// If subtitles are already on, this only jumps back; the active
    /// track is left alone (no revert-to-off later).
    func replayWithCaptions() {
        guard duration > 0 else { return }
        guard !isScrubbing else { return }
        let invokedAt = currentTime
        if let window = replayWindow {
            replayWindow = window.extended(to: invokedAt)
        } else {
            replayWindow = ReplayWindowLogic(invokedAt: invokedAt, priorSubtitleTrackId: currentSubtitleTrackId)
            if currentSubtitleTrackId == nil, let track = preferredReplaySubtitleTrack() {
                selectSubtitleTrackWithoutSaving(id: track.id)
            }
        }
        Task { await seek(to: max(0, invokedAt - 15)) }
    }

    /// First non-forced subtitle track, or the first track if all are
    /// forced (better to show something than nothing when the user asks
    /// "what did they say?").
    private func preferredReplaySubtitleTrack() -> MediaTrack? {
        subtitleTracks.first { !$0.isForced } ?? subtitleTracks.first
    }

    /// Called from both the AVPlayer and Aether periodic time-observer
    /// sites alongside `checkMarkers(at:)`. Reverts the active replay
    /// window once playback passes its invocation point.
    private func tickReplayWindow(at time: TimeInterval) {
        guard let existing = replayWindow else { return }
        // Arm first: the window's backward seek happens asynchronously in a
        // Task, so a stale tick can land at/after invokedAt before the seek
        // actually takes effect. Only a tick observed below invokedAt proves
        // the seek landed; only then can a later pass back over invokedAt
        // count as a real revert trigger.
        let window = existing.observing(currentTime: time)
        replayWindow = window
        guard window.shouldRevert(currentTime: time) else { return }
        replayWindow = nil
        if window.priorSubtitleTrackId == nil {
            selectSubtitleTrackWithoutSaving(id: nil)
        }
    }

    /// Clears any active replay window without reverting subtitles — used
    /// wherever the user (or the system) moves playback or subtitle state
    /// out from under the window: manual scrubs, absolute seeks, manual
    /// subtitle picks, and stopPlayback. The in-progress choice wins.
    /// Internal (not private): the `.seekAbsolute` input-action handler in
    /// `UniversalPlayerView` calls this directly for user-initiated absolute
    /// seeks (remote-scrub, Now Playing widget) that bypass `commitScrub()`.
    func clearReplayWindow() {
        replayWindow = nil
    }

    /// Show seek indicator briefly (1.5 seconds)
    private func showSeekIndicator(_ indicator: SeekIndicator) {
        seekIndicatorTimer?.invalidate()
        withAnimation(.easeOut(duration: 0.15)) {
            seekIndicator = indicator
        }
        seekIndicatorTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                withAnimation(.easeOut(duration: 0.25)) {
                    self?.seekIndicator = nil
                }
            }
        }
    }

    // MARK: - Scrubbing

    /// Human-readable label for current scrub speed
    var scrubStepLabel: String? {
        ShuttleGrammar.badge(forSpeed: scrubSpeed)
    }

    /// Start or advance scrub speed in given direction via ShuttleGrammar:
    /// click-and-hold enters at level 1, same-direction clicks bump up to the
    /// level 3 cap, opposite-direction clicks step down then cancel. Badges
    /// show the human ladder (2x/4x/6x); real rates are 15x/60x/240x.
    /// - Parameter forward: true for forward, false for backward
    func scrubInDirection(forward: Bool) {
        hidePausedPoster()

        let speedBefore = scrubSpeed
        let newSpeed = ShuttleGrammar.step(current: isScrubbing ? scrubSpeed : 0, clickForward: forward)
        if newSpeed == 0 {
            cancelScrub()
            return
        }

        if !isScrubbing {
            // Start scrubbing
            isScrubbing = true
            scrubTime = currentTime
            controlsTimer?.invalidate()
            loadThumbnail(for: scrubTime)
        }
        // Restart the shuttle timer on any 0 -> nonzero transition, not just
        // fresh-entry. A wheel tick mid-shuttle can zero scrubSpeed and stop
        // the timer while leaving isScrubbing true; without this, a later
        // hold re-enters shuttle with a live badge but a frozen playhead.
        // startScrubTimer() invalidates before rescheduling, so calling it
        // when already running is safe.
        if speedBefore == 0 && newSpeed != 0 {
            startScrubTimer()
        }
        scrubSpeed = newSpeed

        // Immediate jump on each press
        let jumpAmount: TimeInterval = forward ? 10 : -10
        scrubTime = max(0, min(duration, scrubTime + jumpAmount))
        loadThumbnail(for: scrubTime)
    }

    func startScrubbing() {
        isScrubbing = true
        scrubTime = currentTime
        scrubSpeed = 0
        controlsTimer?.invalidate()
        loadThumbnail(for: scrubTime)
    }

    /// Start swipe-based scrubbing (proportional, no speed acceleration)
    func startSwipeScrubbing() {
        hidePausedPoster()
        isScrubbing = true
        scrubTime = currentTime
        scrubSpeed = 0  // No direction-based speed for swipe scrubbing
        scrubStartTime = nil  // No time-based acceleration for swipe
        controlsTimer?.invalidate()
        loadThumbnail(for: scrubTime)
    }

    /// Update scrub position by a relative amount (for swipe gestures)
    /// - Parameter seconds: Amount to seek (positive = forward, negative = backward)
    func updateSwipeScrubPosition(by seconds: TimeInterval) {
        if !isScrubbing {
            startSwipeScrubbing()
        }
        scrubTime = max(0, min(duration, scrubTime + seconds))
        loadThumbnail(for: scrubTime)
    }

    /// Handle click wheel rotation (iPod-style circular scrubbing)
    /// - Parameter radians: Rotation amount in radians (clockwise/positive = forward)
    func handleWheelRotation(_ radians: Float) {
        // Convert rotation to seek time
        // ~10 seconds per full rotation (2π radians), so ~1.6 seconds per radian
        let secondsPerRadian: TimeInterval = 10.0
        let seekDelta = TimeInterval(radians) * secondsPerRadian

        if !isScrubbing {
            hidePausedPoster()
            isScrubbing = true
            scrubTime = currentTime
            scrubSpeed = 0
            scrubStartTime = nil  // No time-based acceleration for wheel
            controlsTimer?.invalidate()
        } else if scrubSpeed != 0 {
            // A wheel tick arrived mid-shuttle. Cancel the timer-driven shuttle
            // and hand control to the wheel delta alone, same as
            // startSwipeScrubbing neutralizes speed for passive scrub.
            stopScrubTimer()
            scrubSpeed = 0
            scrubStartTime = nil
        }

        scrubTime = max(0, min(duration, scrubTime + seekDelta))
        loadThumbnail(for: scrubTime)

        wheelScrubbing = true
        startWheelScrubbingIdleTimer()
    }

    /// Resets the 0.8s idle timer that clears `wheelScrubbing` after
    /// rotation ticks stop arriving. A single Timer is reused (reset on
    /// each call) rather than accumulating one per rotation event.
    private func startWheelScrubbingIdleTimer() {
        wheelScrubbingTimer?.invalidate()
        wheelScrubbingTimer = Timer.scheduledTimer(withTimeInterval: wheelScrubbingIdleDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.wheelScrubbing = false
            }
        }
    }

    private func stopWheelScrubbingTimer() {
        wheelScrubbingTimer?.invalidate()
        wheelScrubbingTimer = nil
        wheelScrubbing = false
    }

    func updateScrubPosition(_ time: TimeInterval) {
        scrubTime = max(0, min(duration, time))
        loadThumbnail(for: scrubTime)
    }

    func scrubRelative(by seconds: TimeInterval) {
        if !isScrubbing {
            startScrubbing()
        }
        scrubTime = max(0, min(duration, scrubTime + seconds))
        loadThumbnail(for: scrubTime)
    }

    func commitScrub() async {
        stopScrubTimer()
        stopWheelScrubbingTimer()
        if isScrubbing {
            clearReplayWindow()
            await seek(to: scrubTime)
            isScrubbing = false
            scrubSpeed = 0
            scrubStartTime = nil
            scrubThumbnail = nil
        }
    }

    func cancelScrub() {
        stopScrubTimer()
        stopWheelScrubbingTimer()
        isScrubbing = false
        scrubSpeed = 0
        scrubStartTime = nil
        scrubTime = currentTime
        scrubThumbnail = nil
        startControlsHideTimer()
    }

    private func startScrubTimer() {
        scrubTimer?.invalidate()
        scrubTimer = Timer.scheduledTimer(withTimeInterval: scrubUpdateInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.updateScrubFromTimer()
            }
        }
    }

    private func stopScrubTimer() {
        scrubTimer?.invalidate()
        scrubTimer = nil
    }

    private func updateScrubFromTimer() {
        guard isScrubbing, scrubSpeed != 0 else { return }

        let direction: TimeInterval = scrubSpeed > 0 ? 1 : -1
        // ShuttleGrammar.rate(forLevel:) is content-seconds per REAL-second;
        // scale by the timer's actual firing interval to get the per-tick advance.
        let secondsPerSecond = ShuttleGrammar.rate(forLevel: scrubSpeed)
        let secondsPerTick = secondsPerSecond * scrubUpdateInterval

        let newTime = scrubTime + (secondsPerTick * direction)
        scrubTime = max(0, min(duration, newTime))

        // Stop at boundaries
        if scrubTime <= 0 || scrubTime >= duration {
            scrubSpeed = 0
            scrubStartTime = nil
            stopScrubTimer()
        }

        loadThumbnail(for: scrubTime)
    }

    private func loadThumbnail(for time: TimeInterval) {
        guard let partId = metadata.Media?.first?.Part?.first?.id else {
            print("⚠️ No part ID available for thumbnails")
            return
        }

        Task {
            let thumbnail = await PlexThumbnailService.shared.getThumbnail(
                partId: partId,
                time: time,
                serverURL: serverURL,
                authToken: authToken
            )
            self.scrubThumbnail = thumbnail
        }
    }

    /// Chapter start times in seconds, derived from Plex chapter metadata.
    var chapterStartTimes: [TimeInterval] {
        (metadata.Chapter ?? []).compactMap { chapter in
            chapter.startTimeOffset.map { TimeInterval($0) / 1000.0 }
        }
    }

    /// Snap the scrub position to the next chapter boundary in the
    /// direction of travel (shuttle direction; forward when idle).
    func chapterSnap() {
        guard isScrubbing else { return }
        let forward = scrubSpeed >= 0
        guard let target = ChapterNavigator.snapTarget(
            from: scrubTime, chapterStarts: chapterStartTimes, forward: forward) else { return }
        scrubTime = min(max(0, target), duration)
        loadThumbnail(for: scrubTime)
    }

    /// Preload thumbnails when playback starts
    func preloadThumbnails() {
        // Debug: Log metadata structure
        if let media = metadata.Media {
            //print("🖼️ [THUMB] Media count: \(media.count)")
            if let firstMedia = media.first {
                //print("🖼️ [THUMB] First media id: \(firstMedia.id)")
                if let parts = firstMedia.Part {
                    //print("🖼️ [THUMB] Part count: \(parts.count)")
                    if let firstPart = parts.first {
                        //print("🖼️ [THUMB] First part id: \(firstPart.id)")
                    }
                } else {
                    print("⚠️ [THUMB] No Part array in media")
                }
            }
        } else {
            print("⚠️ [THUMB] No Media array in metadata")
        }

        guard let partId = metadata.Media?.first?.Part?.first?.id else {
            print("⚠️ No part ID available for thumbnail preload")
            return
        }
        // print("🖼️ Preloading BIF thumbnails for part \(partId)")
        PlexThumbnailService.shared.preloadBIF(
            partId: partId,
            serverURL: serverURL,
            authToken: authToken
        )
    }

    // MARK: - Track Selection

    func selectAudioTrack(id: Int) {
        // Delegate the actual pipeline switch to the auto-selection helper,
        // then persist the user's explicit choice as the saved preference so
        // future playback sessions restore it.
        selectAudioTrackWithoutSaving(id: id)

        if let track = audioTracks.first(where: { $0.id == id }) {
            TrackIntentStore.audioIntent = AudioIntent(from: track)
        }
    }

    /// Select audio track without saving preference (for auto-selection)
    private func selectAudioTrackWithoutSaving(id: Int) {
        if let ap = aetherPlayer {
            ap.selectAudioTrack(id: id)
            currentAudioTrackId = id
            return
        }
        currentAudioTrackId = id
    }

    func selectSubtitleTrack(id: Int?) {
        // User picked a track manually: their choice wins over any active
        // replay window (no later revert-to-prior-track).
        clearReplayWindow()

        // Delegate the actual pipeline switch to the auto-selection helper,
        // then persist the user's explicit choice as the saved preference so
        // future playback sessions restore it.
        selectSubtitleTrackWithoutSaving(id: id)

        if let id = id, let track = subtitleTracks.first(where: { $0.id == id }) {
            TrackIntentStore.subtitleIntent = SubtitleIntent(from: track)
        } else {
            TrackIntentStore.subtitleIntent = .off
        }
    }

    /// Native (AVKit) subtitle picker bridge. Track ids ARE engine indices on
    /// the aether route, so a pick from the native picker is the same value our
    /// own picker produces — just forward it.
    func selectAetherSubtitleTrackFromNativePicker(aetherTrackId: Int?) {
        guard aetherPlayer != nil else { return }
        selectSubtitleTrack(id: aetherTrackId)
    }

    /// Whether we've already applied track preferences for this playback session
    private var hasAppliedSubtitlePreference = false
    private var hasAppliedAudioPreference = false

    /// Pre-play track selections passed in from the item-detail picker.
    /// Override the saved-preference auto-apply on first track population
    /// — explicit user choice wins over remembered language preferences.
    /// Cleared after consumption so subsequent re-applications fall back
    /// to the preference managers.
    private var initialAudioTrackId: Int?
    private var initialSubtitleSelection: InitialSubtitleSelection = .auto

    /// Rebuild `audioTracks` / `subtitleTracks`.
    ///
    /// ON THE AETHER ROUTE there is ONE list per stream type, produced by
    /// `TrackMerge`: engine tracks (authoritative stream index = `id`, but no
    /// forced bit and no long title) folded together with Plex's streams (which
    /// have both). Track ids are therefore engine indices, directly selectable,
    /// and no Plex->engine id translation exists anywhere downstream.
    ///
    /// ON THE HLS ROUTE there is no engine, so the tracks are Plex's as-is and
    /// the ids are Plex stream ids. Selection there goes through AVPlayer's own
    /// media selection, which is keyed off the same Plex list.
    ///
    /// Called from `updateTrackLists()`'s original sites AND from the engine's
    /// track publishers, since either side can arrive first.
    private func updateTrackLists() {
        let previousSubtitleCount = subtitleTracks.count
        let previousAudioCount = audioTracks.count

        let plexStreams = metadata.Media?.first?.Part?.first?.Stream ?? []
        let plexAudio = plexStreams.filter { $0.isAudio }.map { MediaTrack(from: $0) }
        let plexSubs = plexStreams.filter { $0.isSubtitle }.map { MediaTrack(from: $0) }

        if let ap = aetherPlayer {
            // Engine list drives membership; Plex supplies the labels. Until the
            // engine reports (empty list), leave the current tracks alone rather
            // than publishing a Plex list whose ids the engine can't accept.
            if !ap.audioTracks.isEmpty {
                audioTracks = TrackMerge.mergeAudio(engine: ap.audioTracks, plex: plexAudio)
            }
            if !ap.subtitleTracks.isEmpty {
                subtitleTracks = TrackMerge.mergeSubtitles(engine: ap.subtitleTracks, plex: plexSubs)
            }
            // The engine's active indices ARE our ids now — no translation.
            //
            // Both are re-read on EVERY call, not latched to first population.
            // The engine re-publishes its track lists mid-session (the native
            // side-demuxer swap on an audio switch rebuilds them from a fresh
            // format context), and the ids are renumbered when it does. Latching
            // would strand `currentAudioTrackId` in the old numbering, so the
            // picker's checkmark and the rail's label would point at the wrong
            // row. The engine's active index is authoritative and always in the
            // current numbering.
            if let active = ap.activeSubtitleTrackId {
                currentSubtitleTrackId = active
            }
            if let active = ap.activeAudioTrackId {
                currentAudioTrackId = active
            }
        } else {
            audioTracks = plexAudio
            subtitleTracks = plexSubs

            // Plex route: seed the current ids from the server's stream flags.
            if previousAudioCount == 0 {
                currentAudioTrackId = plexStreams.first(where: { $0.isAudio && $0.selected == true })?.id
                    ?? plexAudio.first(where: { $0.isDefault })?.id
                    ?? plexAudio.first?.id
            }
            if previousSubtitleCount == 0 {
                currentSubtitleTrackId = plexStreams.first(where: { $0.isSubtitle && $0.selected == true })?.id
                    ?? plexSubs.first(where: { $0.isForced })?.id
                    ?? plexSubs.first(where: { $0.isDefault })?.id
            }
        }

        // Apply remembered intent once, when each list first has content.
        if !hasAppliedAudioPreference, !audioTracks.isEmpty, previousAudioCount == 0 {
            hasAppliedAudioPreference = true
            applyAudioPreference()
        }
        if !hasAppliedSubtitlePreference, !subtitleTracks.isEmpty, previousSubtitleCount == 0 {
            hasAppliedSubtitlePreference = true
            applySubtitlePreference()
        }
    }

    /// Apply saved audio preference. Selection priority is:
    ///  1. `initialAudioTrackId` from the pre-play picker (this session).
    ///  2. Plex's per-item explicit selection (a `selected: true` stream
    ///     that isn't also the file's `default: true` track — meaning the
    ///     user picked something deliberately, in Plex Web / mobile / our
    ///     own picker — that choice persists server-side and should win
    ///     over a global language default).
    ///  3. The global `AudioIntent` (which defaults to English even when
    ///     nothing has been stored — drives the typical "auto-pick the
    ///     highest-quality English stream" behavior for items the user has
    ///     never deliberately picked for). Commentary / audio-description
    ///     tracks are excluded from this automatic tier.
    ///  4. Plex's default-flagged stream as a final fallback.
    /// In every tier we issue `selectAudioTrackWithoutSaving` explicitly,
    /// even when `currentAudioTrackId` already matches the desired id.
    /// Reason: DirectPlay loaded the file's default-flagged audio track
    /// and won't switch on its own, and Plex's HLS session is built from
    /// server-state-at-session-start which doesn't always reflect the
    /// persisted per-part selection — so an explicit switch is the only
    /// reliable way to honor the user's actual choice. The cost is a
    /// possibly-redundant HLS session rebuild at startup; correctness wins.
    private func applyAudioPreference() {
        // 1. Pre-play picker (this session). The pre-play picker lists Plex
        //    streams (it runs before any engine exists), so its id is a Plex
        //    stream id — the one place a translation is still needed. Resolve it
        //    positionally against the merged list.
        if let id = initialAudioTrackId {
            initialAudioTrackId = nil
            if let track = audioTrackMatchingPlexStreamId(id) {
                selectAudioTrackWithoutSaving(id: track.id)
                return
            }
        }

        // 2. Plex per-item explicit selection: a `selected: true` stream that
        //    isn't also the file's default means the user deliberately picked it
        //    (here, or in Plex Web / mobile), and that persists server-side.
        let plexAudioStreams = (metadata.Media?.first?.Part?.first?.Stream ?? []).filter { $0.isAudio }
        if let selectedId = plexAudioStreams.first(where: { $0.selected == true })?.id,
           let defaultId = plexAudioStreams.first(where: { $0.default == true })?.id,
           selectedId != defaultId,
           let track = audioTrackMatchingPlexStreamId(selectedId) {
            selectAudioTrackWithoutSaving(id: track.id)
            return
        }

        // 3. Global audio intent (defaults to English when nothing stored).
        //    Excludes commentary / audio-description tracks from every
        //    automatic tier — see TrackIntentResolver.resolveAudio.
        if let match = TrackIntentResolver.resolveAudio(
            intent: TrackIntentStore.effectiveAudioIntent,
            in: audioTracks
        ) {
            selectAudioTrackWithoutSaving(id: match.id)
            return
        }

        // 4. Plex default fallback.
        if let id = currentAudioTrackId,
           audioTracks.contains(where: { $0.id == id }) {
            selectAudioTrackWithoutSaving(id: id)
        }
    }

    /// Apply saved subtitle preference
    private func applySubtitlePreference() {
        // 1. Pre-play picker selection (this session). Off and a specific
        //    track id are both explicit; auto means "no selection was
        //    made, fall through". Consume and clear in either explicit
        //    branch.
        switch initialSubtitleSelection {
        case .off:
            initialSubtitleSelection = .auto
            selectSubtitleTrackWithoutSaving(id: nil)
            return
        case .track(let id):
            // Pre-play picker id is a PLEX stream id (it runs before any engine
            // exists) — resolve it positionally onto the merged list.
            initialSubtitleSelection = .auto
            if let track = subtitleTrackMatchingPlexStreamId(id) {
                selectSubtitleTrackWithoutSaving(id: track.id)
                return
            }
        case .auto:
            break
        }

        // 2. Plex's per-item explicit selection. A `selected: true` stream
        //    that's neither the default nor the forced one is a deliberate
        //    user pick (here, or in Plex Web / mobile) — honor it over the
        //    global intent.
        let plexSubStreams = (metadata.Media?.first?.Part?.first?.Stream ?? []).filter { $0.isSubtitle }
        if let selectedId = plexSubStreams.first(where: { $0.selected == true })?.id,
           let track = subtitleTrackMatchingPlexStreamId(selectedId),
           !track.isDefault, !track.isForced {
            selectSubtitleTrackWithoutSaving(id: track.id)
            return
        }

        // 3. No explicit user intent yet: honor selected/default stream behavior.
        guard let intent = TrackIntentStore.subtitleIntent else {
            if currentSubtitleTrackId == nil,
               let forcedTrack = subtitleTracks.first(where: { $0.isForced }) {
                selectSubtitleTrackWithoutSaving(id: forcedTrack.id)
            } else if let activeSubtitleTrackId = currentSubtitleTrackId {
                selectSubtitleTrackWithoutSaving(id: activeSubtitleTrackId)
            }
            return
        }

        // 4. Global subtitle intent. Resolution is a PURE READ: when no track
        //    on this title matches the intent (e.g. stored "ENG forced" but
        //    this title only ships a regular English track), subtitles come up
        //    off for this title and the stored intent is left ALONE, so it
        //    re-engages on the next title that does have a forced English
        //    track. Only an explicit user pick writes intent.
        if let match = TrackIntentResolver.resolveSubtitle(intent: intent, in: subtitleTracks) {
            selectSubtitleTrackWithoutSaving(id: match.id)
        } else {
            selectSubtitleTrackWithoutSaving(id: nil)
        }
    }

    /// Select a subtitle track without persisting intent (auto-selection).
    ///
    /// No id translation: on the aether route `subtitleTracks` ids ARE engine
    /// stream indices (see `TrackMerge`), so the id dispatches straight through.
    private func selectSubtitleTrackWithoutSaving(id: Int?) {
        aetherPlayer?.selectSubtitleTrack(id: id)
        currentSubtitleTrackId = id
    }

    private func plexAudioTracksFromMetadata() -> [MediaTrack] {
        metadata.Media?.first?.Part?.first?.Stream?
            .filter { $0.isAudio }
            .map { MediaTrack(from: $0) } ?? []
    }

    private func plexSubtitleTracksFromMetadata() -> [MediaTrack] {
        metadata.Media?.first?.Part?.first?.Stream?
            .filter { $0.isSubtitle }
            .map { MediaTrack(from: $0) } ?? []
    }

    // MARK: - Plex stream id -> merged track
    //
    // Two inputs still speak PLEX stream ids rather than our (engine-indexed)
    // track ids: the pre-play picker, which runs before any engine exists, and
    // Plex's server-side `selected` flag. These are the only Plex-id boundaries
    // left; everything downstream of the merge is one id space.
    //
    // On the HLS route the merged list IS the Plex list, so the id matches
    // directly. On the aether route we join on the container stream index —
    // the same key `TrackMerge` used to build the list (sidecars excepted:
    // they have no stream index, so they pair by registration order).

    private func audioTrackMatchingPlexStreamId(_ id: Int) -> MediaTrack? {
        // HLS route: the merged list IS the Plex list, so the id matches directly.
        guard aetherPlayer != nil else {
            return audioTracks.first { $0.id == id }
        }
        // Aether route: join on the container stream index, the key both sides
        // carry (see TrackMerge).
        guard let streamIndex = plexAudioTracksFromMetadata()
            .first(where: { $0.id == id })?.streamIndex else { return nil }
        return audioTracks.first { $0.streamIndex == streamIndex }
    }

    private func subtitleTrackMatchingPlexStreamId(_ id: Int) -> MediaTrack? {
        guard aetherPlayer != nil else {
            return subtitleTracks.first { $0.id == id }
        }
        let plex = plexSubtitleTracksFromMetadata()
        guard let plexIndex = plex.firstIndex(where: { $0.id == id }) else { return nil }
        let plexTrack = plex[plexIndex]

        // Sidecars have no stream index — they pair by registration order.
        if plexTrack.subtitleKey != nil {
            let ordinal = plex[..<plexIndex].count(where: { $0.subtitleKey != nil })
            return subtitleTracks.filter(\.isExternal)[safe: ordinal]
        }
        guard let streamIndex = plexTrack.streamIndex else { return nil }
        return subtitleTracks.first { $0.streamIndex == streamIndex }
    }

    // MARK: - Controls Visibility

    func showControlsTemporarily() {
        showControls = true
        startControlsHideTimer()
    }

    /// Enter transport-control focus mode: the SwiftUI content layer
    /// stops being focusable, the focus engine lands on the transport
    /// bar's buttons, and the auto-hide timer is suspended while the
    /// user is navigating the controls. Menu exits back to playback.
    func enterControlsFocus() {
        guard showControls, !isScrubbing, postVideoState == .hidden else { return }
        controlsTimer?.invalidate()
        controlsTimer = nil
        controlsFocusActive = true
    }

    /// Leave transport-control focus mode; controls stay visible and
    /// the auto-hide timer restarts.
    func exitControlsFocus() {
        guard controlsFocusActive else { return }
        controlsFocusActive = false
        startControlsHideTimer()
    }

    private func startControlsHideTimer() {
        // Never auto-hide out from under focused transport controls.
        guard !controlsFocusActive else { return }
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: controlsHideDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            let isPlaying = self.playbackState == .playing
            Task { @MainActor [weak self] in
                guard let self, isPlaying else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    self.showControls = false
                }
            }
        }
    }

    // MARK: - Compatibility Notice

    private func showCompatibilityNotice(_ message: String) {
        compatibilityNotice = message
        compatibilityNoticeTimer?.invalidate()
        compatibilityNoticeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.compatibilityNotice = nil
        }
    }

    private func hideCompatibilityNotice() {
        compatibilityNoticeTimer?.invalidate()
        compatibilityNoticeTimer = nil
        compatibilityNotice = nil
    }

    // MARK: - Paused Poster Timer

    /// Start timers for the ambient pause presentation: `.ambient` after
    /// `pausedPosterDelay` seconds paused, `.dimmed` after
    /// `pausedPosterDimDelay` seconds paused. No-ops while a rail panel is
    /// open (`isRailPanelOpen`) — the ambient backdrop is a full-screen
    /// visual that would otherwise show through/around the panel.
    private func startPausedPosterTimer() {
        guard !isRailPanelOpen else { return }
        pausedPosterTimer?.invalidate()
        pausedPosterTimer = Timer.scheduledTimer(withTimeInterval: pausedPosterDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackState == .paused, !self.isRailPanelOpen else { return }
                withAnimation(.easeIn(duration: 1.0)) {
                    self.pausePresentation = .ambient
                }
            }
        }

        pausedPosterDimTimer?.invalidate()
        pausedPosterDimTimer = Timer.scheduledTimer(withTimeInterval: pausedPosterDimDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackState == .paused, !self.isRailPanelOpen else { return }
                withAnimation(.easeInOut(duration: 1.0)) {
                    self.pausePresentation = .dimmed
                }
            }
        }
    }

    /// Cancel both ambient-pause timers and drop back to the live frame.
    private func cancelPausedPosterTimer() {
        pausedPosterTimer?.invalidate()
        pausedPosterTimer = nil
        pausedPosterDimTimer?.invalidate()
        pausedPosterDimTimer = nil
        if pausePresentation != .frame {
            withAnimation(.easeOut(duration: 0.5)) {
                pausePresentation = .frame
            }
        }
    }

    /// Hide paused poster on any control input
    func hidePausedPoster() {
        cancelPausedPosterTimer()
    }

    // MARK: - Marker Detection & Skipping

    /// How many seconds before a marker to show the skip button
    private let markerPreviewTime: TimeInterval = 5.0

    /// Check if current time is within a marker range (or approaching one)
    /// Also triggers post-video summary at credits marker or 45s before end
    private func checkMarkers(at time: TimeInterval) {
        // Don't check while scrubbing or if post-video already showing
        guard !isScrubbing, postVideoState == .hidden else { return }

        // Check recap markers first — recaps precede the intro in an episode.
        // These only exist via the IntroDB backup (Plex never emits recap).
        for recap in metadata.recapMarkers {
            guard let recapId = recap.id else { continue }
            guard recap.endTimeSeconds > recap.startTimeSeconds else { continue }

            let previewStart = max(0, recap.startTimeSeconds - markerPreviewTime)

            // Reset skip flag if user rewound before the marker (same
            // starts-at-0 special case as intro markers)
            if skippedRecapIds.contains(recapId) {
                if time < previewStart {
                    skippedRecapIds.remove(recapId)
                } else if previewStart == 0 && time < recap.startTimeSeconds + 1.0 && activeMarker == nil {
                    skippedRecapIds.remove(recapId)
                }
            }

            if time >= previewStart && time < recap.endTimeSeconds {
                handleRecapMarkerActive(recap, currentTime: time)
                return
            }
        }

        // Check intro marker (show 5 seconds early)
        if let intro = metadata.introMarker {
            // Skip malformed markers where end time is not after start time
            guard intro.endTimeSeconds > intro.startTimeSeconds else {
                // Invalid marker data - skip this check
                return
            }

            let previewStart = max(0, intro.startTimeSeconds - markerPreviewTime)

            // Reset skip flag if user rewound before the marker preview window.
            // Special case: when intro starts at 0 (previewStart is also 0), we reset if:
            // 1. User is at the very beginning (within 1 second of start), AND
            // 2. We've already left the marker region (activeMarker is nil)
            // This allows re-triggering after seeking back without causing repeated skips
            // during initial playback.
            if hasSkippedIntro || userDeclinedAutoSkip {
                if time < previewStart {
                    hasSkippedIntro = false
                    userDeclinedAutoSkip = false
                    // Cancel any running countdown
                    cancelSkipCountdownTimer()
                } else if previewStart == 0 && time < intro.startTimeSeconds + 1.0 && activeMarker == nil {
                    hasSkippedIntro = false
                    userDeclinedAutoSkip = false
                    cancelSkipCountdownTimer()
                }
            }

            if time >= previewStart && time < intro.endTimeSeconds {
                handleMarkerActive(intro, isIntro: true, currentTime: time)
                return
            }
        }

        // Check credits markers - can have multiple (e.g., mid-credits and post-credits)
        // Trigger post-video when FIRST credits marker starts
        for credits in metadata.creditsMarkers {
            guard let creditsId = credits.id else { continue }

            // Skip malformed markers
            guard credits.endTimeSeconds > credits.startTimeSeconds else { continue }

            let previewStart = max(0, credits.startTimeSeconds - markerPreviewTime)
            let creditsStartPercent = duration > 0 ? credits.startTimeSeconds / duration : 1.0
            let remainingAfterCredits = duration - credits.startTimeSeconds

            // Sanity check: credits should be in the last half of the video OR < 5 min of content remains
            let creditsAreValid = creditsStartPercent >= 0.5 || remainingAfterCredits < 300

            // Reset skip flag if user rewound before the marker
            if skippedCreditsIds.contains(creditsId) {
                if time < previewStart {
                    skippedCreditsIds.remove(creditsId)
                } else if previewStart == 0 && time < credits.startTimeSeconds + 1.0 && activeMarker == nil {
                    skippedCreditsIds.remove(creditsId)
                }
            }

            // Reset post-video trigger if rewound before first credits marker
            if let firstCredits = metadata.firstCreditsMarker,
               time < max(0, firstCredits.startTimeSeconds - markerPreviewTime) {
                if hasTriggeredPostVideo { hasTriggeredPostVideo = false }
            }

            // Show skip button from the exact credits marker start (no 5s
            // preview lead-in) through the end of the credits — consistent with
            // the native Up Next card, which presents at the marker start. Only
            // show if the credits marker is in a valid position.
            if creditsAreValid && time >= credits.startTimeSeconds && time < credits.endTimeSeconds {
                handleCreditsMarkerActive(credits, currentTime: time)

                // Trigger post-video summary when FIRST credits marker actually starts
                // (skip button will be hidden by UI when postVideoState != .hidden)
                if let firstCredits = metadata.firstCreditsMarker,
                   credits.id == firstCredits.id,
                   time >= credits.startTimeSeconds && !hasTriggeredPostVideo {
                    hasTriggeredPostVideo = true
                    triggerPostVideoTransition()
                }
                return
            }
        }

        // Check commercial markers
        for commercial in metadata.commercialMarkers {
            guard let commercialId = commercial.id else { continue }

            // Skip malformed markers
            guard commercial.endTimeSeconds > commercial.startTimeSeconds else { continue }

            let previewStart = max(0, commercial.startTimeSeconds - markerPreviewTime)

            // Reset skip flag if user rewound before the marker
            // Same special case handling for commercials starting at 0 as intro markers
            if skippedCommercialIds.contains(commercialId) {
                if time < previewStart {
                    skippedCommercialIds.remove(commercialId)
                } else if previewStart == 0 && time < commercial.startTimeSeconds + 1.0 && activeMarker == nil {
                    skippedCommercialIds.remove(commercialId)
                }
            }

            if time >= previewStart && time < commercial.endTimeSeconds {
                handleCommercialMarkerActive(commercial, currentTime: time)
                return
            }
        }

        // Check next-episode preview markers
        for preview in metadata.previewMarkers {
            guard let previewId = preview.id else { continue }
            guard preview.endTimeSeconds > preview.startTimeSeconds else { continue }

            let previewStart = max(0, preview.startTimeSeconds - markerPreviewTime)

            // Reset skip flag if user rewound before the marker
            if skippedPreviewIds.contains(previewId) {
                if time < previewStart {
                    skippedPreviewIds.remove(previewId)
                } else if previewStart == 0 && time < preview.startTimeSeconds + 1.0 && activeMarker == nil {
                    skippedPreviewIds.remove(previewId)
                }
            }

            if time >= previewStart && time < preview.endTimeSeconds {
                handlePreviewMarkerActive(preview, currentTime: time)
                return
            }
        }

        // No credits markers - trigger post-video 45 seconds before end
        // BUT require at least 85% completion to avoid triggering too early on short videos
        if metadata.creditsMarkers.isEmpty && duration > 60 {
            let triggerTime = duration - 45
            let minCompletionTime = duration * 0.85  // At least 85% watched

            // Reset flag if user rewound before trigger point
            if time < triggerTime - 10 && hasTriggeredPostVideo {
                hasTriggeredPostVideo = false
            }

            // Only trigger if we're both near the end AND have watched most of the content
            if time >= triggerTime && time >= minCompletionTime && !hasTriggeredPostVideo {
                hasTriggeredPostVideo = true
                triggerPostVideoTransition()
                return
            }
        }

        // No active marker: clear the pill and reset the per-marker auto-skip
        // decline/countdown so the next marker starts fresh.
        if activeMarker != nil {
            activeMarker = nil
            showSkipButton = false
            userDeclinedAutoSkip = false
            cancelSkipCountdownTimer()
        }
    }

    /// Handle when playback enters an intro marker range (or preview window)
    /// Auto-skip only triggers when actually inside the marker (at or past startTimeSeconds),
    /// not during the 5-second preview window before the marker starts.
    /// When auto-skip is enabled, shows a countdown to give user a chance to cancel.
    private func handleMarkerActive(_ marker: PlexMarker, isIntro: Bool, currentTime: TimeInterval) {
        let autoSkipIntro = UserDefaults.standard.bool(forKey: "autoSkipIntro")

        // Only auto-skip when actually inside the marker (not during preview window)
        // This ensures we use Plex's exact marker timing and don't cut off content
        let insideMarker = currentTime >= marker.startTimeSeconds

        // Auto-skip with a visible countdown when the setting is on. Show the
        // pill first so the countdown has something to render "· N" onto.
        if isIntro && autoSkipIntro && !hasSkippedIntro && insideMarker && !userDeclinedAutoSkip {
            if activeMarker == nil {
                activeMarker = marker
                showSkipButton = true
            }
            if skipCountdownTimer == nil && skipCountdownSeconds == 0 {
                startSkipCountdown(for: marker)
            }
            return
        }

        // Show skip button if not already skipped
        if !hasSkippedIntro && activeMarker == nil {
            activeMarker = marker
            showSkipButton = true
        }
    }

    /// Start the auto-skip countdown for `marker`. Shared by intro/credits/ads;
    /// at 0 it funnels through `skipMarker` (which marks the right skipped set
    /// per type). The pill shows a live "· N" suffix while this runs.
    private func startSkipCountdown(for marker: PlexMarker) {
        skipCountdownSeconds = skipCountdownDelaySeconds

        skipCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else {
                    timer.invalidate()
                    return
                }

                self.skipCountdownSeconds -= 1

                if self.skipCountdownSeconds <= 0 {
                    timer.invalidate()
                    self.skipCountdownTimer = nil
                    self.skipCountdownSeconds = 0
                    await self.skipMarker(marker)
                }
            }
        }
    }

    /// Tear down the countdown timer without marking the marker declined —
    /// used by seek-back resets and when the active marker clears.
    private func cancelSkipCountdownTimer() {
        skipCountdownTimer?.invalidate()
        skipCountdownTimer = nil
        skipCountdownSeconds = 0
    }

    /// Cancel the auto-skip countdown (user pressed Menu during the countdown).
    /// Leaves the manual pill up but declines auto-skip for the current marker.
    func cancelSkipCountdown() {
        guard skipCountdownTimer != nil || skipCountdownSeconds > 0 else { return }

        cancelSkipCountdownTimer()
        userDeclinedAutoSkip = true  // Don't restart the countdown for this marker
    }

    /// Handle when playback enters a credits marker range (or preview window)
    /// Auto-skip only triggers when actually inside the marker (at or past startTimeSeconds).
    private func handleCreditsMarkerActive(_ marker: PlexMarker, currentTime: TimeInterval) {
        guard let creditsId = marker.id else { return }

        let autoSkipCredits = UserDefaults.standard.bool(forKey: "autoSkipCredits")

        // Only auto-skip when actually inside the marker (not during preview window)
        let insideMarker = currentTime >= marker.startTimeSeconds

        // Auto-skip with a visible countdown when the setting is on.
        if autoSkipCredits && !skippedCreditsIds.contains(creditsId) && insideMarker && !userDeclinedAutoSkip {
            if activeMarker == nil {
                activeMarker = marker
                showSkipButton = true
            }
            if skipCountdownTimer == nil && skipCountdownSeconds == 0 {
                startSkipCountdown(for: marker)
            }
            return
        }

        // Show skip button if not already skipped
        if !skippedCreditsIds.contains(creditsId) && activeMarker == nil {
            activeMarker = marker
            showSkipButton = true
        }
    }

    /// Handle when playback enters a commercial marker range (or preview window)
    /// Auto-skip only triggers when actually inside the marker (at or past startTimeSeconds).
    private func handleCommercialMarkerActive(_ marker: PlexMarker, currentTime: TimeInterval) {
        guard let commercialId = marker.id else { return }

        let autoSkipAds = UserDefaults.standard.bool(forKey: "autoSkipAds")

        // Only auto-skip when actually inside the marker (not during preview window)
        let insideMarker = currentTime >= marker.startTimeSeconds

        // Auto-skip with a visible countdown when the setting is on.
        if autoSkipAds && !skippedCommercialIds.contains(commercialId) && insideMarker && !userDeclinedAutoSkip {
            if activeMarker == nil {
                activeMarker = marker
                showSkipButton = true
            }
            if skipCountdownTimer == nil && skipCountdownSeconds == 0 {
                startSkipCountdown(for: marker)
            }
            return
        }

        // Show skip button if not already skipped
        if !skippedCommercialIds.contains(commercialId) && activeMarker == nil {
            activeMarker = marker
            showSkipButton = true
        }
    }

    /// Handle when playback enters a recap marker range (or preview window).
    /// Recap markers come from the IntroDB backup; same behaviour as the
    /// other marker kinds.
    private func handleRecapMarkerActive(_ marker: PlexMarker, currentTime: TimeInterval) {
        guard let recapId = marker.id else { return }

        let autoSkipRecap = UserDefaults.standard.bool(forKey: "autoSkipRecap")

        // Only auto-skip when actually inside the marker (not during preview window)
        let insideMarker = currentTime >= marker.startTimeSeconds

        // Auto-skip with a visible countdown when the setting is on.
        if autoSkipRecap && !skippedRecapIds.contains(recapId) && insideMarker && !userDeclinedAutoSkip {
            if activeMarker == nil {
                activeMarker = marker
                showSkipButton = true
            }
            if skipCountdownTimer == nil && skipCountdownSeconds == 0 {
                startSkipCountdown(for: marker)
            }
            return
        }

        // Show skip button if not already skipped
        if !skippedRecapIds.contains(recapId) && activeMarker == nil {
            activeMarker = marker
            showSkipButton = true
        }
    }

    /// Handle when playback enters a next-episode preview marker range.
    private func handlePreviewMarkerActive(_ marker: PlexMarker, currentTime: TimeInterval) {
        guard let previewId = marker.id else { return }

        let autoSkipPreview = UserDefaults.standard.bool(forKey: "autoSkipPreview")

        // Only auto-skip when actually inside the marker (not during preview window)
        let insideMarker = currentTime >= marker.startTimeSeconds

        // Auto-skip with a visible countdown when the setting is on.
        if autoSkipPreview && !skippedPreviewIds.contains(previewId) && insideMarker && !userDeclinedAutoSkip {
            if activeMarker == nil {
                activeMarker = marker
                showSkipButton = true
            }
            if skipCountdownTimer == nil && skipCountdownSeconds == 0 {
                startSkipCountdown(for: marker)
            }
            return
        }

        // Show skip button if not already skipped
        if !skippedPreviewIds.contains(previewId) && activeMarker == nil {
            activeMarker = marker
            showSkipButton = true
        }
    }

    /// Skip to end of current marker (called from UI skip button)
    func skipActiveMarker() async {
        guard let marker = activeMarker else { return }
        await skipMarker(marker)
    }

    /// Skip to end of a specific marker
    private func skipMarker(_ marker: PlexMarker) async {
        // Stop any running auto-skip countdown — this funnels both the manual
        // skip (user clicked the pill) and the countdown reaching 0.
        cancelSkipCountdownTimer()
        // Mark as skipped to prevent re-showing button if user seeks back
        if marker.isIntro {
            hasSkippedIntro = true
        } else if marker.isCredits, let creditsId = marker.id {
            skippedCreditsIds.insert(creditsId)
        } else if marker.isCommercial, let commercialId = marker.id {
            skippedCommercialIds.insert(commercialId)
        } else if marker.isRecap, let recapId = marker.id {
            skippedRecapIds.insert(recapId)
        } else if marker.isPreview, let previewId = marker.id {
            skippedPreviewIds.insert(previewId)
        }

        // Seek to end of marker, clamped so we never land at/after duration.
        // Credits markers typically end AT the file end (endTimeSeconds ==
        // duration); seeking to literal EOF stalls Aether's AVPlayer host. Land
        // just inside the media instead: natural end-of-stream then fires within
        // ~epsilon and drives the normal Up Next handoff. AVPlayer/RPlayer
        // tolerate seek-to-duration, but just-before is correct for them too, so
        // the clamp is unconditional (this is the single funnel for both the
        // skip button and auto-skip).
        let skipEpsilon: TimeInterval = 0.5
        let target = duration > 0
            ? max(0, min(marker.endTimeSeconds, duration - skipEpsilon))
            : max(0, marker.endTimeSeconds)

        // Marker skip (manual or auto) is a user-initiated seek that bypasses
        // commitScrub/.seekAbsolute: clear any active replay window so a
        // stale invocation point can't spuriously revert subtitles later,
        // disconnected from where playback actually landed post-skip.
        clearReplayWindow()
        // Preserve the chrome state across the skip: if the controls were
        // hidden (the pill owned focus), the jump must NOT pop the rail open;
        // if they were already up, keep them up.
        await seek(to: target, revealsControls: showControls)

        // Hide button
        activeMarker = nil
        showSkipButton = false
    }

    /// Label for current skip button
    var skipButtonLabel: String {
        guard let marker = activeMarker else { return "Skip" }
        if marker.isIntro {
            return "Skip Intro"
        } else if marker.isCredits {
            return "Skip Credits"
        } else if marker.isCommercial {
            return "Skip Ad"
        } else if marker.isRecap {
            return "Skip Recap"
        } else if marker.isPreview {
            return "Skip Preview"
        }
        return "Skip"
    }

    /// Pill title including the live auto-skip countdown when one is running
    /// (e.g. "Skip Intro · 5"). Without a countdown it is just the base label.
    var skipButtonDisplayLabel: String {
        skipCountdownSeconds > 0 ? "\(skipButtonLabel) · \(skipCountdownSeconds)" : skipButtonLabel
    }

    /// True when the skip pill is the lone on-screen affordance — chrome
    /// hidden, not scrubbing, no post-video, live video frame — and should
    /// own focus so a single Select jumps forward. Mirrors
    /// `controlsFocusActive`: while true the SwiftUI content layer releases
    /// focus and `PlayerContainerViewController` routes it to the pill.
    var skipPillOwnsFocus: Bool {
        showSkipButton
            && !showControls
            && !isScrubbing
            && postVideoState == .hidden
            && pausePresentation == .frame
    }

    /// Fetch detailed metadata with markers if not already present
    private func fetchMarkersIfNeeded() async {
        guard let ratingKey = metadata.ratingKey else {
            return
        }

        do {
            let networkManager = PlexNetworkManager.shared
            let detailedMetadata = try await networkManager.getFullMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )

            // Update metadata with markers from detailed fetch
            if let markers = detailedMetadata.Marker, !markers.isEmpty {
                metadata.Marker = markers
            }

            // Update chapters (Plex returns these at metadata level, not inside Part)
            if let chapters = detailedMetadata.Chapter, !chapters.isEmpty {
                metadata.Chapter = chapters
                await fetchChapterThumbnails(chapters: chapters)
            }

            // Update Media (includes Part with stream details)
            // Hub items often lack Part/Stream data
            if let media = detailedMetadata.Media, !media.isEmpty {
                metadata.Media = media
            }

            // Fill in missing display info (summary, genres, etc.)
            if metadata.summary == nil { metadata.summary = detailedMetadata.summary }
            if metadata.Genre == nil { metadata.Genre = detailedMetadata.Genre }
            if metadata.contentRating == nil { metadata.contentRating = detailedMetadata.contentRating }
        } catch {
            print("⏭️ [Skip] Failed to fetch detailed metadata: \(error)")
        }
    }

    // MARK: - Post-Video Handling

    /// Handle video end - transition to post-video summary
    /// Reads the user's "Show Up Next Panel" preference. A missing key
    /// reads as `true` so the chooser still appears for existing users.
    private var showPostVideoUpNext: Bool {
        UserDefaults.standard.object(forKey: "showPostVideoUpNext") as? Bool ?? true
    }

    /// Resolve the next episode EARLY (as soon as Aether's AVPlayer is
    /// available) so it's ready by the time handlePlaybackEnded() presents the
    /// EpisodeSummaryOverlay, rather than fetching only at end-of-episode. Runs
    /// once per episode; later currentAVPlayer re-emissions are no-ops.
    private func resolveNextEpisodeEarlyIfNeeded() async {
        guard metadata.type == "episode" else { return }
        guard !nextEpisodeResolvedEarly else { return }
        nextEpisodeResolvedEarly = true

        if metadata.parentRatingKey == nil || metadata.index == nil {
            await fetchFullMetadataIfNeeded()
        }
        let next = await fetchNextEpisode()
        guard let next else { return }
        nextEpisode = next
        Task { await preloadNextEpisode() }
        Task { await loadUpNextEpisodes() }
    }

    /// Called by `processMarkers` at the first-credits boundary (or at the
    /// 45-seconds-from-end heuristic for content without markers). Decides
    /// whether to enter the panel flow now or let playback continue to true
    /// EOF based on the user's preference. When the panel is suppressed for
    /// episodes, we still mark the item as watched at credits start so a
    /// manual mid-credits dismissal doesn't leave it in a "not yet finished"
    /// state.
    private func triggerPostVideoTransition() {
        let isEpisode = metadata.type == "episode"

        if showPostVideoUpNext || !isEpisode {
            Task { await handlePlaybackEnded() }
        } else {
            Task { await markCurrentAsWatched() }
        }
    }

    func handlePlaybackEnded() async {
        let isEpisode = metadata.type == "episode"

        // Don't re-enter if already showing post-video
        guard postVideoState == .hidden else { return }

        // Mark as watched immediately when playback ends/reaches credits.
        // This runs exactly once whether the custom overlay or the native
        // card drives Up Next.
        await markCurrentAsWatched()

        postVideoState = .loading

        // Per-user opt-out of the post-video "Up Next" chooser for TV
        // episodes. When disabled, episodes follow the same path movies
        // already take: credits play uninterrupted at full size.
        // Movies: No PostVideo - just let the video play through to the end
        guard isEpisode && showPostVideoUpNext else {
            postVideoState = .hidden
            return
        }

        // TV Show: Only show PostVideo if there's a next episode

        // If parent metadata is missing (e.g., from Continue Watching), fetch full metadata first
        if metadata.parentRatingKey == nil || metadata.index == nil {
            await fetchFullMetadataIfNeeded()
        }

        // Fetch next episode
        nextEpisode = await fetchNextEpisode()

        // No next episode: Skip PostVideo - just let the video play through
        guard nextEpisode != nil else {
            postVideoState = .hidden
            return
        }

        // Animate video shrink
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            videoFrameState = .shrunk
        }

        // Show episode summary after brief delay
        try? await Task.sleep(nanoseconds: 200_000_000)  // 0.2s
        postVideoState = .showingEpisodeSummary

        // Start countdown and preload
        startAutoplayCountdown()
        // Preload next episode in background for instant playback
        Task {
            await preloadNextEpisode()
        }
    }

    /// Fetch full metadata if parent keys or Media info are missing (e.g., from Continue Watching)
    private func fetchFullMetadataIfNeeded() async {
        guard let ratingKey = metadata.ratingKey else {
            return
        }

        let networkManager = PlexNetworkManager.shared

        do {
            let fullMetadata = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey,
                includeGuids: true  // populate external-id guids so Insights can resolve a TMDB id
            )

            // Update our metadata with the parent keys
            if metadata.parentRatingKey == nil {
                metadata.parentRatingKey = fullMetadata.parentRatingKey
            }
            if metadata.grandparentRatingKey == nil {
                metadata.grandparentRatingKey = fullMetadata.grandparentRatingKey
            }
            if metadata.parentIndex == nil {
                metadata.parentIndex = fullMetadata.parentIndex
            }
            if metadata.grandparentTitle == nil {
                metadata.grandparentTitle = fullMetadata.grandparentTitle
            }
            if metadata.index == nil {
                metadata.index = fullMetadata.index
            }

            // Update Media array if missing (needed for info overlay display)
            if metadata.Media == nil || metadata.Media?.isEmpty == true {
                metadata.Media = fullMetadata.Media
            }

            // Carry over external-id guids (fetched via includeGuids=1) so
            // Insights can resolve a show TMDB id. The lightweight metadata the
            // player starts with (e.g. from a hub) usually lacks these.
            if metadata.grandparentGuid == nil {
                metadata.grandparentGuid = fullMetadata.grandparentGuid
            }
            if metadata.parentGuid == nil {
                metadata.parentGuid = fullMetadata.parentGuid
            }
            if metadata.guid == nil {
                metadata.guid = fullMetadata.guid
            }
            if metadata.Guid == nil || metadata.Guid?.isEmpty == true {
                metadata.Guid = fullMetadata.Guid
            }

            // Markers may be absent on the lightweight metadata the player
            // started with (hub items) — carry them over from the full fetch.
            if metadata.Marker == nil || metadata.Marker?.isEmpty == true {
                metadata.Marker = fullMetadata.Marker
            }

        } catch {
            print("🎬 [Metadata] Failed to fetch full metadata: \(error)")
        }
    }

    /// Adds IntroDB backup markers for kinds Plex didn't provide. Episodes
    /// only (the lookup keys on the show's IMDB id + season/episode). Plex is
    /// authoritative: a kind Plex already emitted is never replaced.
    private func backfillMarkersFromIntroDB() async {
        guard metadata.type == "episode",
              let season = metadata.parentIndex,
              let episode = metadata.index else { return }

        let presentKinds = Set((metadata.Marker ?? []).compactMap(\.type))
        let missingKinds = ["intro", "recap", "credits"].filter { !presentKinds.contains($0) }
        guard !missingKinds.isEmpty else { return }

        guard let imdbID = await showIMDBID() else {
            print("🎬 IntroDB: no IMDB id resolvable for show — skipping backup lookup")
            return
        }

        print("🎬 IntroDB: checking \(imdbID) S\(season)E\(episode) for missing \(missingKinds)")
        let generation = itemGeneration
        let backup = await IntroDBClient().markers(imdbID: imdbID, season: season, episode: episode)
        guard generation == itemGeneration else { return }  // item changed mid-fetch

        let extras = backup.filter { marker in
            guard let type = marker.type else { return false }
            return missingKinds.contains(type)
        }
        guard !extras.isEmpty else {
            print("🎬 IntroDB: no backup markers found (DBs returned \(backup.compactMap(\.type).sorted()))")
            return
        }
        metadata.Marker = (metadata.Marker ?? []) + extras
        print("🎬 IntroDB: added backup markers \(extras.compactMap(\.type).sorted()) for S\(season)E\(episode)")
    }

    /// The show's IMDB id (e.g. "tt0903747"), resolved from the show-level
    /// metadata's external guids.
    private func showIMDBID() async -> String? {
        guard let showKey = metadata.grandparentRatingKey else { return nil }
        guard let show = try? await PlexNetworkManager.shared.getMetadata(
            serverURL: serverURL,
            authToken: authToken,
            ratingKey: showKey,
            includeGuids: true
        ) else { return nil }
        return show.Guid?
            .compactMap(\.id)
            .first { $0.hasPrefix("imdb://") }?
            .replacingOccurrences(of: "imdb://", with: "")
    }

    /// Load the current season's episode list for the Up Next panel, sorted
    /// by index. When the current episode is the season finale, appends the
    /// next season's opener (via `fetchNextEpisode()`) so the panel still has
    /// an up-next row to show. No-ops (clears to []) for non-episode content
    /// or on any fetch failure.
    func loadUpNextEpisodes() async {
        let generation = itemGeneration
        guard metadata.type == "episode" else {
            upNextEpisodes = []
            return
        }
        if metadata.parentRatingKey == nil || metadata.index == nil {
            await fetchFullMetadataIfNeeded()
        }
        guard let seasonKey = metadata.parentRatingKey else {
            upNextEpisodes = []
            return
        }
        do {
            var episodes = try await PlexNetworkManager.shared.getChildren(
                serverURL: serverURL, authToken: authToken, ratingKey: seasonKey)
                .filter { $0.index != nil }
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            // Season finale: surface the next season's opener as the up-next row.
            // Skipped during shuffle play — fetchNextEpisode() advances the shuffle
            // queue index as a side effect, and the panel shows season order anyway.
            if !isShufflePlay,
               episodes.last?.ratingKey == metadata.ratingKey,
               let next = await fetchNextEpisode(),
               next.parentRatingKey != metadata.parentRatingKey {
                episodes.append(next)
            }
            guard generation == itemGeneration else { return }
            upNextEpisodes = episodes
        } catch {
            guard generation == itemGeneration else { return }
            upNextEpisodes = []
        }
    }

    /// Load cast for the Insights rail panel. TMDB credits are primary
    /// (headshots + character names) when the item resolves to a TMDB id;
    /// falls back to Plex `Role` data (own metadata, then the show's, for
    /// episodes) when TMDB has nothing. No-ops to [] if neither source
    /// has cast.
    func loadInsightsCast() async {
        let generation = itemGeneration
        let isMovie = metadata.type == "movie"
        // Episodes: use the SHOW's tmdb id, never the episode's own guid. Some
        // Plex agents put a per-episode tmdb:// id in the episode's Guid array,
        // which would resolve to the wrong id and silently drop TMDB cast.
        let tmdbId = metadata.type == "episode"
            ? (metadata.parentShowTmdbId ?? metadata.showTmdbId)
            : metadata.tmdbId

        var people: [MediaPerson] = []

        if let tmdbId {
            if metadata.type == "episode",
               let season = metadata.parentIndex, let episode = metadata.index,
               let episodeCast = await TMDBClient.shared.episodeCastCredits(
                   showTmdbId: tmdbId, season: season, episode: episode) {
                people = InsightsCastMapper.mediaPeople(fromTMDB: episodeCast, titleTmdbId: tmdbId, titleIsMovie: false)
            } else {
                let credits = await TMDBClient.shared.castCredits(tmdbId: tmdbId, type: isMovie ? .movie : .tv)
                people = InsightsCastMapper.mediaPeople(fromTMDB: credits, titleTmdbId: tmdbId, titleIsMovie: isMovie)
            }
        }

        // Plex Role fallback: item's own roles, then (episodes) the show's roles.
        if people.isEmpty {
            var roles = metadata.Role ?? []
            if roles.isEmpty, let key = metadata.ratingKey,
               let full = try? await PlexNetworkManager.shared.getFullMetadata(
                   serverURL: serverURL, authToken: authToken, ratingKey: key) {
                roles = full.Role ?? []
            }
            if roles.isEmpty, metadata.type == "episode", let showKey = metadata.grandparentRatingKey,
               let show = try? await PlexNetworkManager.shared.getFullMetadata(
                   serverURL: serverURL, authToken: authToken, ratingKey: showKey) {
                roles = show.Role ?? []
            }
            people = InsightsCastMapper.mediaPeople(
                fromPlexRoles: roles, serverURL: serverURL, authToken: authToken,
                titleTmdbId: tmdbId, titleIsMovie: isMovie)
        }

        guard generation == itemGeneration else { return }
        insightsCast = people
    }

    /// Load trivia for the Insights panel's Trivia section. Mirrors
    /// `loadInsightsCast()`'s tmdb-id resolution exactly (episodes use the
    /// SHOW's tmdb id, never the episode's own guid) so both sections agree
    /// on which title they're describing. All failures are soft — the
    /// client already returns nil/empty on 404/network/decode failure, so
    /// there is no error branch here, only "no trivia" (`insightsTrivia`
    /// stays nil and the panel shows no Trivia section).
    func loadInsightsTrivia() async {
        let generation = itemGeneration
        var tmdbId = metadata.type == "episode"
            ? (metadata.parentShowTmdbId ?? metadata.showTmdbId)
            : metadata.tmdbId

        // For episodes, Plex often gives a plex:// or tvdb:// grandparent guid
        // (not tmdb://), so the direct extraction above is nil. Resolve the
        // show TMDB id from the show's external ids (tvdb/imdb -> tmdb via the
        // proxy find route) so Insights can fetch/request generation instead of
        // silently bailing. Cached per show, so this is one lookup, not per
        // episode.
        if tmdbId == nil, metadata.type == "episode" {
            let externalIDs = await resolveShowExternalIDs()
            guard generation == itemGeneration else { return }
            tmdbId = await InsightsShowIDResolver.shared.resolve(externalIDs)
            guard generation == itemGeneration else { return }
        }

        guard let tmdbId else {
            guard generation == itemGeneration else { return }
            insightsTrivia = nil
            suppressedTriviaIDs = []
            return
        }

        let season = metadata.type == "episode" ? metadata.parentIndex : nil
        let episode = metadata.type == "episode" ? metadata.index : nil
        let requestType = (metadata.type == "episode" || metadata.type == "show" || metadata.type == "season")
            ? "tv" : "movie"

        // Resolve the primary result using the 404-vs-error-aware API so we can
        // tell "genuinely uncovered" (safe to trigger generation) apart from a
        // transient network hiccup (never trigger; just retry naturally later).
        var primary: TriviaFetchResult = .unavailable
        switch metadata.type {
        case "episode":
            if let season, let episode {
                primary = await InsightsTriviaClient.shared.episodeTriviaResult(
                    showTmdbId: tmdbId, season: season, episode: episode)
            }
        case "show", "season":
            primary = await InsightsTriviaClient.shared.showTriviaResult(showTmdbId: tmdbId)
        default:
            primary = await InsightsTriviaClient.shared.movieTriviaResult(tmdbId: tmdbId)
        }

        var trivia: TitleTrivia?
        if case .found(let t) = primary, !t.isTombstone {
            trivia = t
        } else {
            // Uncovered (tombstone) or genuinely missing. For episodes, fall
            // back to the show's overall trivia — production/casting facts
            // are still relevant to the viewer even without episode-specific
            // coverage yet.
            if metadata.type == "episode",
               case .found(let showTrivia) = await InsightsTriviaClient.shared.showTriviaResult(showTmdbId: tmdbId),
               !showTrivia.isTombstone {
                trivia = showTrivia
            }
            // Only a genuine 404 warrants asking the pipeline to generate —
            // a tombstone is a definitive "nothing to share" (never
            // re-request it) and a network failure should retry naturally
            // later, never fire a request (Global Constraints).
            if case .notFound = primary {
                triggerGenerationIfNeeded(type: requestType, tmdbId: tmdbId, season: season, episode: episode)
                scheduleInsightsRecheck(type: requestType, tmdbId: tmdbId, season: season, episode: episode)
            }
        }
        let suppressed = await InsightsTriviaClient.shared.suppressedFactIDs()

        guard generation == itemGeneration else { return }
        insightsTrivia = trivia
        suppressedTriviaIDs = suppressed
    }

    /// Gather the show's external ids for an episode. Uses guids already on the
    /// current metadata if present; otherwise fetches the show's metadata (by
    /// grandparentRatingKey, with includeGuids) so a lightweight episode payload
    /// (e.g. from a hub, which carries no guids) still resolves. Best-effort:
    /// returns whatever ids it can find, possibly empty.
    private func resolveShowExternalIDs() async -> ShowExternalIDs {
        let inHand = metadata.showExternalIDs
        if inHand.tmdb != nil || inHand.tvdb != nil || inHand.imdb != nil {
            return inHand
        }
        guard let showKey = metadata.grandparentRatingKey else { return inHand }
        guard let showMeta = try? await PlexNetworkManager.shared.getMetadata(
            serverURL: serverURL, authToken: authToken, ratingKey: showKey, includeGuids: true
        ) else { return inHand }
        // The show payload's own guid/Guid array carries the show's external ids.
        var tmdb = showMeta.guid.flatMap(PlexMetadata.extractTmdbId)
        var tvdb = showMeta.guid.flatMap(PlexMetadata.extractTvdbId)
        var imdb = showMeta.guid.flatMap(PlexMetadata.extractImdbId)
        for g in (showMeta.Guid?.compactMap { $0.id } ?? []) {
            if tmdb == nil { tmdb = PlexMetadata.extractTmdbId(from: g) }
            if tvdb == nil { tvdb = PlexMetadata.extractTvdbId(from: g) }
            if imdb == nil { imdb = PlexMetadata.extractImdbId(from: g) }
        }
        return ShowExternalIDs(tmdb: tmdb, tvdb: tvdb, imdb: imdb)
    }

    /// Fire a one-shot generation request to the pipeline for a title/episode
    /// that returned a genuine 404. Deduped per item-key for the life of this
    /// view model (session) — never re-fires for the same key even across
    /// multiple `loadInsightsTrivia()` calls (e.g. re-entering the panel).
    private func triggerGenerationIfNeeded(type: String, tmdbId: Int, season: Int?, episode: Int?) {
        let key = season != nil && episode != nil
            ? "tv:\(tmdbId):S\(season!)E\(episode!)"
            : "\(type == "movie" ? "movie" : "tv"):\(tmdbId)"
        guard !requestedInsightKeys.contains(key) else { return }
        requestedInsightKeys.insert(key)
        // For an episode the generation title must be the SHOW title, not the
        // episode name (the pipeline searches Wikipedia/Fandom by show). Use
        // grandparentTitle for episodes; fall back to the item title otherwise.
        let requestTitle = (metadata.type == "episode"
            ? (metadata.grandparentTitle ?? metadata.title)
            : metadata.title) ?? ""
        let req = InsightsGenerationRequest(
            type: type == "movie" ? "movie" : "tv", tmdbId: tmdbId,
            season: season, episode: episode,
            title: requestTitle, year: metadata.year)
        Task { await InsightsTriviaClient.shared.requestGeneration(req) }
    }

    /// Re-poll a few times so freshly-generated trivia populates the open
    /// panel before the episode ends. Stops on success or tombstone; cancelled
    /// on item swap / teardown. No visible "loading" state — the panel stays
    /// calm whether or not this ever finds something.
    /// Back-off for the mid-playback trivia re-check: a quick first probe (in
    /// case the title was already generated), then a steady ~2-min cadence out
    /// to ~20 min. Generation is on-demand and can wait behind an in-flight
    /// scheduled title on the box, so a cold title can take 10-15 min to land;
    /// the wide window lets the panel populate during THIS playback instead of
    /// only on the next play. Stops early the instant trivia (or a tombstone)
    /// arrives, and is cancelled on item swap / teardown.
    private static let insightsRecheckDelays: [Int] = [20] + Array(repeating: 120, count: 10)

    private func scheduleInsightsRecheck(type: String, tmdbId: Int, season: Int?, episode: Int?) {
        insightsRecheckTask?.cancel()
        let generation = itemGeneration
        insightsRecheckTask = Task { [weak self] in
            for delay in Self.insightsRecheckDelays {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.itemGeneration == generation else { return }
                let result: TriviaFetchResult
                if let season, let episode {
                    result = await InsightsTriviaClient.shared.episodeTriviaResult(
                        showTmdbId: tmdbId, season: season, episode: episode)
                } else if type == "tv" {
                    result = await InsightsTriviaClient.shared.showTriviaResult(showTmdbId: tmdbId)
                } else {
                    result = await InsightsTriviaClient.shared.movieTriviaResult(tmdbId: tmdbId)
                }
                if case .found(let t) = result {
                    await MainActor.run {
                        guard self.itemGeneration == generation else { return }
                        if !t.isTombstone { self.insightsTrivia = t }
                    }
                    return // covered or tombstone: done either way
                }
            }
        }
    }

    /// Fetch the next episode for TV shows
    func fetchNextEpisode() async -> PlexMetadata? {
        // Shuffled queue: return next shuffled episode instead of sequential
        if !shuffledQueue.isEmpty {
            shuffledQueueIndex += 1
            guard shuffledQueueIndex < shuffledQueue.count else { return nil }
            return shuffledQueue[shuffledQueueIndex]
        }

        // Check if next episode was prefetched
        if let ratingKey = metadata.ratingKey,
           let cached = await PlexDataStore.shared.getCachedNextEpisode(for: ratingKey) {
            return cached
        }

        guard let seasonKey = metadata.parentRatingKey,
              let currentIndex = metadata.index else {
            print("🎬 [PostVideo] FAILED: No season key or episode index")
            return nil
        }

        let networkManager = PlexNetworkManager.shared

        do {
            // Get all episodes in current season
            let episodes = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: seasonKey
            )

            // Sort episodes by index and find the next one after current
            let sortedEpisodes = episodes
                .filter { $0.index != nil }
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

            // Find episodes with index greater than current, take the first one
            if let nextEp = sortedEpisodes.first(where: { ($0.index ?? 0) > currentIndex }) {
                return nextEp
            }

            // Debug: show what episodes and indexes we have
            let episodeInfo = sortedEpisodes.map { "E\($0.index ?? -1): \($0.title ?? "?")" }

            // End of season - try next season
            guard let showKey = metadata.grandparentRatingKey,
                  let seasonIndex = metadata.parentIndex else {
                return nil
            }

            let seasons = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: showKey
            )

            // Sort seasons by index and find the next one after current
            let sortedSeasons = seasons
                .filter { $0.index != nil }
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

            guard let nextSeason = sortedSeasons.first(where: { ($0.index ?? 0) > seasonIndex }),
                  let nextSeasonKey = nextSeason.ratingKey else {
                let seasonIndexes = sortedSeasons.compactMap { $0.index }
                return nil
            }

            let nextSeasonEpisodes = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: nextSeasonKey
            )

            // Get first episode of next season (sorted by index)
            let sortedNextSeasonEps = nextSeasonEpisodes
                .filter { $0.index != nil }
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

            if let firstEp = sortedNextSeasonEps.first {
                return firstEp
            }

            return nil
        } catch {
            print("🎬 [PostVideo] Failed to fetch next episode: \(error)")
            return nil
        }
    }

    /// Fetch recommendations for movies
    func fetchRecommendations() async -> [PlexMetadata] {
        guard let ratingKey = metadata.ratingKey else { return [] }

        let networkManager = PlexNetworkManager.shared

        do {
            let related = try await networkManager.getRelatedItems(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey,
                limit: 10
            )
            return related
        } catch {
            print("🎬 [PostVideo] Failed to fetch recommendations: \(error)")
            return []
        }
    }

    /// Start autoplay countdown timer
    func startAutoplayCountdown() {
        // Default to 5 seconds if not set (key doesn't exist)
        // 0 explicitly means disabled
        let countdownSetting: Int
        if UserDefaults.standard.object(forKey: "autoplayCountdown") == nil {
            countdownSetting = 5  // Default: 5 seconds
        } else {
            countdownSetting = UserDefaults.standard.integer(forKey: "autoplayCountdown")
        }

        // 0 means disabled
        guard countdownSetting > 0 else {
            return
        }

        countdownSeconds = countdownSetting
        isCountdownPaused = false

        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard !self.isCountdownPaused else { return }

                self.countdownSeconds -= 1

                if self.countdownSeconds <= 0 {
                    self.countdownTimer?.invalidate()
                    await self.playNextEpisode()
                }
            }
        }
    }

    /// Preload the next episode's stream URL and metadata for instant playback
    private func preloadNextEpisode() async {
        guard let next = nextEpisode, let ratingKey = next.ratingKey else { return }

        let networkManager = PlexNetworkManager.shared

        // Fetch full metadata with markers
        do {
            let fullMetadata = try await networkManager.getFullMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )
            preloadedNextMetadata = fullMetadata
        } catch {
            print("🎬 [Preload] Failed to fetch metadata: \(error)")
            preloadedNextMetadata = next
        }

        // Build stream URL for next episode
        let metadata = preloadedNextMetadata ?? next
        if let partKey = metadata.Media?.first?.Part?.first?.key {
            preloadedNextStreamURL = networkManager.buildPlaybackDirectPlayURL(
                serverURL: serverURL,
                authToken: authToken,
                partKey: partKey
            )
            preloadedNextStreamHeaders = [
                "X-Plex-Token": authToken,
                "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
                "X-Plex-Platform": PlexAPI.platform,
                "X-Plex-Device": PlexAPI.deviceName,
                "X-Plex-Product": PlexAPI.productName
            ]
            if let preloadedURL = preloadedNextStreamURL {
                let headers = preloadedNextStreamHeaders
                Task(priority: .utility) {
                    await networkManager.warmDirectPlayStream(url: preloadedURL, headers: headers)
                }
            }
        }
    }

    /// Clear preloaded data
    private func clearPreloadedData() {
        preloadedNextStreamURL = nil
        preloadedNextStreamHeaders = [:]
        preloadedNextMetadata = nil
    }

    /// Cancel countdown but stay on summary
    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        isCountdownPaused = true
    }

    /// Play a specific episode from the Up Next panel. Reuses the full
    /// playNextEpisode() reset path (filmstrip/replay/marker/generation reset)
    /// by substituting the target as the resolved next episode. Note this
    /// still marks the CURRENT episode watched — same semantics as advancing
    /// normally, even when jumping ahead or back within the season.
    func playEpisode(_ episode: PlexMetadata) async {
        guard episode.ratingKey != metadata.ratingKey else { return }
        // Any in-flight preload was for the previously-resolved `nextEpisode`,
        // not this target — discard it so playNextEpisode() doesn't splice in
        // the wrong episode's metadata/stream URL.
        preloadedNextMetadata = nil
        preloadedNextStreamURL = nil
        preloadedNextStreamHeaders = [:]
        nextEpisode = episode
        await playNextEpisode()
    }

    /// Play the next episode
    func playNextEpisode() async {
        guard let next = nextEpisode else { return }

        // Mark current episode as watched BEFORE switching to next
        await markCurrentAsWatched()

        // Stop countdown and reset all countdown state
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownSeconds = 0
        isCountdownPaused = false

        // Reset post-video state with animation to return video to fullscreen
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            postVideoState = .hidden
            videoFrameState = .fullscreen
        }

        // Use preloaded metadata if available (has markers), otherwise use fetched next episode
        metadata = preloadedNextMetadata ?? next
        // metadata isn't @Published (its ratingKey is the only identity
        // signal), so bump this explicitly for anything that caches
        // per-item state and needs to reset across the swap.
        itemGeneration += 1
        // Clear stale Up Next rows from the outgoing episode's season; the
        // resolve-early hook repopulates them for the new episode.
        upNextEpisodes = []
        // Clear the outgoing item's cast; the container's $itemGeneration
        // sink reloads it for the new episode.
        insightsCast = []
        // Same for trivia — the container's $itemGeneration sink reloads
        // it for the new episode via loadInsightsTrivia().
        insightsTrivia = nil
        suppressedTriviaIDs = []
        // Cancel any in-flight re-check for the outgoing item; loadInsightsTrivia()
        // schedules a fresh one for the new item if needed.
        insightsRecheckTask?.cancel()
        insightsRecheckTask = nil

        // Re-resolve the title logo for the new episode.
        fetchTitleLogoIfNeeded()

        // Reset start offset so next episode starts from beginning (not resume position)
        startOffset = nil

        // Reset skip tracking for new episode — but keep hasTriggeredPostVideo = true
        // until after startPlayback() completes. The old time observer can emit stale
        // time values (from the previous episode's position) during the async transition.
        // If hasTriggeredPostVideo were false, checkMarkers could immediately re-trigger
        // post-video using the stale time against the new episode's credits markers.
        hasSkippedIntro = false
        skippedCreditsIds.removeAll()
        skippedCommercialIds.removeAll()
        skippedRecapIds.removeAll()
        skippedPreviewIds.removeAll()

        // Clear any replay window left open from the previous episode — its
        // invokedAt is a timestamp on episode N's timeline, meaningless (and
        // dangerously coincidental) on episode N+1's, and would otherwise
        // silently revert subtitles mid-scene with no relationship to any
        // action the user took in the new episode.
        clearReplayWindow()

        // Reset auto-skip countdown state
        cancelSkipCountdownTimer()
        userDeclinedAutoSkip = false
        nextEpisode = nil

        // New episode: allow the early next-episode resolve to run again.
        nextEpisodeResolvedEarly = false

        // Ensure next episode has required metadata for subsequent next-up detection
        if metadata.parentRatingKey == nil || metadata.index == nil {
            await fetchFullMetadataIfNeeded()
        }

        // New metadata requires a fresh route/URL plan unless a preloaded URL is provided.
        resetPreparedStreamContext()

        // Use preloaded stream URL if available, otherwise prepare fresh
        if let preloadedURL = preloadedNextStreamURL {
            streamURL = preloadedURL
            streamHeaders = preloadedNextStreamHeaders
        } else {
            await ensureStreamURLPrepared()
        }

        // Clear preloaded data
        clearPreloadedData()

        // Start playback — new time observer starts with time ≈ 0 after this returns
        await startPlayback()

        // Safe to allow post-video detection now: the old time observer has been
        // replaced and time values reflect the new episode's actual position.
        hasTriggeredPostVideo = false
    }

    /// Dismiss post-video overlay and return to fullscreen video
    /// Note: Does NOT reset hasTriggeredPostVideo - that prevents re-triggering while still in the credits.
    /// The flag is only reset when seeking backwards past the trigger point or starting new content.
    func dismissPostVideo() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        postVideoState = .hidden
        videoFrameState = .fullscreen
        nextEpisode = nil
        recommendations = []
        countdownSeconds = 0
        isCountdownPaused = false
        // Don't reset hasTriggeredPostVideo here - prevents immediate re-trigger
        clearPreloadedData()
    }

    // MARK: - Navigation

    /// Navigate to the current episode's season
    func navigateToSeason() {
        guard let seasonKey = metadata.parentRatingKey else { return }
        stopPlayback()
        dismissPostVideo()
        NotificationCenter.default.post(
            name: .navigateToContent,
            object: nil,
            userInfo: ["ratingKey": seasonKey, "type": "season"]
        )
    }

    /// Navigate to the current episode's show
    func navigateToShow() {
        guard let showKey = metadata.grandparentRatingKey else { return }
        stopPlayback()
        dismissPostVideo()
        NotificationCenter.default.post(
            name: .navigateToContent,
            object: nil,
            userInfo: ["ratingKey": showKey, "type": "show"]
        )
    }

    // MARK: - Progress Tracking

    /// Mark current content as watched (for use before transitioning to next episode)
    private func markCurrentAsWatched() async {
        guard let ratingKey = metadata.ratingKey, !ratingKey.isEmpty else { return }

        // Report stopped state
        await PlexProgressReporter.shared.reportProgress(
            ratingKey: ratingKey,
            time: currentTime,
            duration: duration,
            state: "stopped"
        )

        // Mark as watched (episode reached post-video, so it's effectively complete)
        await PlexProgressReporter.shared.markAsWatched(ratingKey: ratingKey)
    }

    // MARK: - Cleanup

    deinit {
        // Clean up AVPlayer time observer (must happen synchronously in deinit)
        if let timeObserver = _timeObserverForCleanup, let player = _playerForCleanup {
            player.removeTimeObserver(timeObserver)
        }
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)

        Task { @MainActor [subtitleClockSync] in
            subtitleClockSync.stop()
        }
        controlsTimer?.invalidate()
        scrubTimer?.invalidate()
        wheelScrubbingTimer?.invalidate()
        countdownTimer?.invalidate()
        seekIndicatorTimer?.invalidate()
        skipCountdownTimer?.invalidate()
        aetherStallWatchdogTask?.cancel()
        insightsRecheckTask?.cancel()
        if let observer = appBackgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appBecameActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // Clean up Siri user activity
        userActivity?.resignCurrent()
        userActivity?.invalidate()

        // Ensure screensaver is re-enabled when player is deallocated
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: - Navigation Notifications

extension Notification.Name {
    /// Posted when player requests navigation to a specific content item
    /// userInfo contains: "ratingKey" (String), "type" (String: "show", "season", "movie")
    static let navigateToContent = Notification.Name("navigateToContent")

    /// Posted when Plex data needs to be refreshed (e.g., after playback ends)
    /// Views showing Plex content should refresh their data when receiving this
    static let plexDataNeedsRefresh = Notification.Name("plexDataNeedsRefresh")

    /// Posted when a specific item's watched state changes via the detail-page
    /// Mark Watched / Unwatched button. Carries `ratingKey` (String) and
    /// `watched` (Bool) in userInfo. Parent MediaDetailViews (e.g. a show
    /// detail page hosting an episode carousel) listen for this so their
    /// in-memory episode arrays reflect the change without a full reload.
    static let episodeWatchedStatusChanged = Notification.Name("episodeWatchedStatusChanged")

    /// Posted when video playback starts (pauses hub polling)
    static let plexPlaybackStarted = Notification.Name("plexPlaybackStarted")

    /// Posted when video playback stops (resumes hub polling)
    static let plexPlaybackStopped = Notification.Name("plexPlaybackStopped")
}
