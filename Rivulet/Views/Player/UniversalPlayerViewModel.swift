// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

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
}

/// Seek indicator shown briefly when user taps left/right to skip
enum SeekIndicator: Equatable {
    case forward(Int)   // seconds skipped forward
    case backward(Int)  // seconds skipped backward

    var systemImage: String {
        let base: String
        switch self {
        case .forward: base = "goforward"
        case .backward: base = "gobackward"
        }
        // SF Symbols only ships numbered variants for these magnitudes; fall
        // back to the plain glyph for anything else so we never render a
        // missing-symbol box.
        let numbered: Set<Int> = [5, 10, 15, 30, 45, 60, 75, 90]
        let magnitude = abs(seconds)
        return numbered.contains(magnitude) ? "\(base).\(magnitude)" : base
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
    /// The scrub bar itself holds focus (a subset of `controlsFocusActive`).
    var scrubberOwnsFocus = false
    @Published var isScrubbing = false {
        didSet {
            guard isScrubbing != oldValue else { return }
            if isScrubbing {
                // Some entry paths hide the poster before setting this flag.
                cancelPausedPosterTimer()
            } else if playbackState == .paused {
                startPausedPosterTimer()
            }
        }
    }

    /// True while iPod-style circular clickpad rotation is actively
    /// driving the scrub (see `handleWheelScrub(by:)`). Distinct from
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
        artworkURL(
            plex: {
                guard let art = metadata.art,
                      var components = URLComponents(string: "\(serverURL)\(art)") else { return nil }
                components.queryItems = (components.queryItems ?? []) + [
                    URLQueryItem(name: "X-Plex-Token", value: authToken)
                ]
                return components.url
            },
            provider: { $0.item.artwork.backdrop ?? $0.item.grandparentArtwork?.backdrop }
        )
    }

    /// Every image the player loads picks its URL here. A Plex path is
    /// server-relative and needs the server and token; a provider's art is
    /// already absolute and never gets a Plex token.
    private func artworkURL(plex: () -> URL?, provider: (ProviderPlayback) -> URL?) -> URL? {
        switch source {
        case .plex: return plex()
        case .provider(let playback): return provider(playback)
        }
    }

    /// A Plex server-relative image path with the token.
    private func plexImageURL(_ path: String?) -> URL? {
        guard let path else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(authToken)")
    }

    /// Now Playing artwork: an episode shows its season or show poster.
    var nowPlayingArtworkURL: URL? {
        artworkURL(
            plex: {
                let path = metadata.type == "episode"
                    ? metadata.parentThumb ?? metadata.grandparentThumb ?? metadata.thumb
                    : metadata.thumb ?? metadata.art
                return plexImageURL(path)
            },
            provider: { $0.item.grandparentArtwork?.poster ?? $0.item.artwork.poster ?? $0.item.artwork.thumbnail }
        )
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
    /// A skip with the controls hidden shows AVKit's bar alone, for as long as its skip glyph.
    @Published private(set) var showsSkipBar = false

    // MARK: - Chapter Thumbnails
    private var chapterThumbnails: [Int: Data] = [:]  // index → image data

    /// Part whose BIF is currently held by PlexThumbnailService. Tracked so the
    /// outgoing item's BIF can be released on teardown and across episode swaps —
    /// a BIF holds every trickplay frame of the item, so a binge would otherwise
    /// accumulate them for the process lifetime.
    private(set) var preloadedThumbnailPartId: Int?

    /// Where scrub stills come from: the Plex server's BIF, or frames the
    /// engine decodes from the playing file.
    enum ScrubThumbnailSource { case server, engine }

    /// The engine decode loop. One decode runs at a time (each one seeks the
    /// file, a range request when it is remote); a scrub that moves meanwhile
    /// parks its time in `pendingEngineThumbnailTime`, the next decode.
    private var engineThumbnailTask: Task<Void, Never>?
    private var pendingEngineThumbnailTime: TimeInterval?

    // MARK: - Skip Marker State
    @Published private(set) var activeMarker: PlexMarker?
    @Published private(set) var showSkipButton = false
    private var hasSkippedIntro = false
    private var skippedCreditsIds: Set<Int> = []  // Track skipped credits by ID (can have multiple)
    private var skippedCommercialIds: Set<Int> = []  // Track skipped commercials by ID
    private var skippedRecapIds: Set<Int> = []  // Track skipped recaps by ID (IntroDB backup)
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
    @Published private(set) var nextEpisode: PlexMetadata?
    /// Set once the next episode has been RESOLVED EARLY for the current episode
    /// (driven by Aether's first non-nil currentAVPlayer). Guards the fetch so
    /// it runs once per episode even though currentAVPlayer re-emits on every
    /// Aether internal AVPlayer swap. Reset on episode change in playNextEpisode().
    private var nextEpisodeResolvedEarly = false
    /// Guards the Up Next panel list load so it runs once per item off the
    /// first `.playing` transition. Reset on item change alongside
    /// `nextEpisodeResolvedEarly`.
    private var upNextEpisodesLoaded = false
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
    #if DEBUG
    /// Stands in for the Worker's trivia, which the simulator can't fetch.
    func debugSetInsightsTrivia(_ trivia: TitleTrivia?) { insightsTrivia = trivia }
    #endif
    /// Fact ids the Worker has auto-hidden after enough user reports.
    /// Fetched alongside trivia; empty on any failure (fail-open — showing
    /// a fact is acceptable, failing closed is not required for this list).
    @Published private(set) var suppressedTriviaIDs: Set<String> = []
    /// Item keys we've already asked the pipeline to generate this session — fire once.
    private var requestedInsightKeys: Set<String> = []
    /// Cancels the mid-playback trivia re-check on item swaps or player teardown.
    private var insightsRecheckTask: Task<Void, Never>?
    @Published var countdownSeconds: Int = 0

    /// What `countdownSeconds` started at. The one resolved copy of the
    /// autoplay setting — read it, don't re-derive it from UserDefaults.
    @Published private(set) var countdownTotalSeconds: Int = 0
    @Published var isCountdownPaused: Bool = false
    private var countdownTimer: Timer?
    /// Episodes played since the remote last started one, counting that one.
    private var episodesInARow = 1
    @Published var scrubThumbnail: UIImage?
    @Published private(set) var scrubSpeed: Int = 0  // -8...8 shuttle level (0 = not shuttling); see ShuttleGrammar
    private var scrubStartTime: Date?  // When scrubbing started (for YouTube-style acceleration)
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var currentAudioTrackId: Int?
    @Published private(set) var currentSubtitleTrackId: Int?
    /// Active skip-back subtitle window, if the user is currently
    /// inside one. Cleared (without reverting) by any user-initiated
    /// absolute seek, manual subtitle-track change, or stopPlayback.
    private var replayWindow: ReplayWindowLogic?
    /// Subtitles turned on by tvOS's Show When Muted (aether route only).
    private var captionsOnMute = CaptionsOnMuteLogic()
    private lazy var systemCaptionsOnMute = SystemCaptionsOnMute { [weak self] in self?.updateCaptionsOnMute() }
    private var compatibilityNoticeTimer: Timer?
    private nonisolated(unsafe) var userActivity: NSUserActivity?

    // MARK: - Player Instance

    /// AVPlayer used for all playback paths (direct, remuxed HLS, Plex HLS)
    @Published private(set) var player: AVPlayer?

    /// HLS manifest enricher — injects audio/subtitle track labels into the master playlist.
    /// Must be retained for the lifetime of the AVURLAsset.
    private var hlsManifestEnricher: HLSManifestEnricher?
    /// Set while the HLS origin's certificate fails system trust; see `prepareHLSRelay`.
    private var hlsRelay: HLSTrustRelay?

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

    /// The playing item's presentation size, mirrored from `aetherPlayer` so
    /// SwiftUI actually observes it (see the subscription in the bind block).
    /// `.zero` before the first frame and on the AVPlayer/hls route.
    @Published private(set) var videoSize: CGSize = .zero

    /// Cue store for the subtitle overlay. Fed from AetherPlayer's cue/clock
    /// publishers in bindAetherPublishers(); rendered by `CaptionOverlayView`,
    /// which PlayerContainerViewController mounts above the video surface.
    let aetherSubtitleModel = SubtitleModel()
    /// The active ASS/SSA track's script, for the caption overlay's libass layer.
    @Published private(set) var assTrack: ASSTrackSource?

    /// Local content filter (VidAngel/ClearPlay-style). Mutes language found in
    /// the title's subtitle file or on screen, and skips scenes from imported
    /// MCF/EDL lists. VOD only. Fed time + active cue text from the observers
    /// below; its `isFilterMuting` output is mirrored onto the active player.
    let contentFilter = ContentFilterManager()
    /// The speech model's run over the player's audio, and the player it reads.
    private var speechTask: Task<Void, Never>?
    private weak var speechPlayer: AetherPlayer?
    /// Words the speech model heard this item, for generated subtitles.
    private var heardWords = SpokenWordStore()
    /// The engine's cues, kept while generated subtitles hold the overlay.
    private var engineCues: [AetherSubtitleCue] = []
    private var muteEdgeWork: DispatchWorkItem?
    /// Subtitles the speech model writes from the dialogue (aether route only). Never in `subtitleTracks`.
    static let generatedSubtitleId = -2
    var showsGeneratedSubtitles: Bool { currentSubtitleTrackId == Self.generatedSubtitleId }
    /// The item generated subtitles were picked on; later items keep them unless they have real ones.
    private var generatedSubtitlesPickedOn: String?
    /// The subtitle menu: the title's tracks, plus generated ones on the aether route.
    var subtitleMenuTracks: [MediaTrack] {
        let generated = MediaTrack(id: Self.generatedSubtitleId, name: "English (On Device)", language: Self.generatedSubtitleStatus)
        return subtitleTracks + (offersGeneratedSubtitles ? [generated] : [])
    }
    var offersGeneratedSubtitles: Bool { aetherPlayer != nil }
    /// What the menu's On turns on: the showing track, else the saved language's full track.
    var subtitleOnTrackId: Int? {
        if let currentSubtitleTrackId { return currentSubtitleTrackId }
        let language = TrackIntentStore.effectiveSubtitleIntent.language ?? TrackLanguage.device
        let full = SubtitleIntent.track(language: language, forced: false, hearingImpaired: false, codec: nil)
        return TrackIntentResolver.resolveSubtitle(intent: full, in: subtitleTracks)?.id
            ?? subtitleTracks.first { !$0.isForced }?.id
            ?? subtitleMenuTracks.first?.id
    }
    /// The generated row's second line: the model's download until it is on disk.
    static var generatedSubtitleStatus: String {
        switch SpeechModelStore.shared.state {
        case .ready: return "Generated on device"
        case .absent: return "On device · downloads 230 MB"
        case .downloading(let fraction): return "Downloading \(Int(fraction * 100))%"
        case .failed: return "Download failed, select to retry"
        }
    }
    /// Why the filter can't mute language on this title right now; nil when it can.
    @Published private(set) var contentFilterNotice: String?
    /// The subtitle track the filter is reading without showing it; the user's subtitles are off.
    @Published private(set) var silentSubtitleTrackId: Int?
    /// Reads image subtitle cues (PGS, VobSub) for the content filter.
    private let subtitleImageReader = SubtitleImageReader()
    /// False until the engine's load returns: its default-subtitle pick runs last and must not be pre-empted.
    private var aetherLoadReturned = false

    // MARK: - Subtitle delay (OSD stepper, sticky per item)

    /// Persistence key for this item's sticky subtitle adjustments (delay and
    /// height). Shared by both, so a title carries one identity.
    var subtitleMediaKey: String { "plex:\(metadata.ratingKey ?? "unknown")" }

    /// This item's height adjustment in stepper units. Published so both
    /// overlays re-render on a step, and reloaded per item like the delay.
    @Published private(set) var subtitleHeightUnits: Int = 0

    /// Steps the height and persists it for this ratingKey. Applied to BOTH
    /// routes, same as the delay stepper, so it survives a mid-playback route
    /// change.
    func adjustSubtitleHeight(bySteps steps: Int) {
        SubtitleAdjustments.setHeightUnits(subtitleHeightUnits + steps,
                                           forMediaKey: subtitleMediaKey)
        subtitleHeightUnits = SubtitleAdjustments.heightUnits(forMediaKey: subtitleMediaKey)
    }

    /// Current subtitle delay in seconds; positive = subtitles appear later.
    var subtitleDelaySeconds: Double { aetherSubtitleModel.delaySeconds }

    /// Steps the delay and persists it for this ratingKey, so the item reopens
    /// where the user left it. Applied to BOTH routes (the model drives the
    /// aether overlay, the manager the HLS overlay) so the stepper works
    /// wherever the item routed — and keeps working across a mid-playback
    /// route change.
    func adjustSubtitleDelay(bySteps steps: Int) {
        let raw = aetherSubtitleModel.delaySeconds + Double(steps) * SubtitleAdjustments.delayStep
        let value = SubtitleAdjustments.roundedDelay(raw)
        aetherSubtitleModel.delaySeconds = value
        SubtitleAdjustments.setDelay(value, forKey: subtitleMediaKey)
    }

    /// Loads this item's stored delay into both pipelines. Called on every
    /// playback setup, including next-episode swaps on this same instance.
    private func loadStoredSubtitleDelay() {
        let value = SubtitleAdjustments.delay(forKey: subtitleMediaKey)
        aetherSubtitleModel.delaySeconds = value
        subtitleHeightUnits = SubtitleAdjustments.heightUnits(forMediaKey: subtitleMediaKey)
    }

    // MARK: - Metadata

    private(set) var metadata: PlexMetadata
    /// Plex `Media.id` of the version playing, kept so a metadata refresh keeps it.
    private(set) var playingMediaID: String?
    /// That version's position in server order; Plex's transcoder picks by `mediaIndex`.
    private(set) var playingMediaServerIndex = 0
    /// True when the user picked a version; only then does Up Next hold a tier.
    private let pickedVersion: Bool
    /// This item's version rule before any quality cap: the explicit pick, or best / Up Next tier.
    private var baseVersionChoice: VersionChoice
    /// The picked file's tier, read once so Up Next can't step down episode by episode.
    private var upNextTier: Int?
    /// Bumped when `metadata` swaps to a different item (not on in-place field
    /// fills). UI caching per-item state observes this, since `metadata` is not published.
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

    /// AetherPlayer subscriptions, kept apart so a re-bind drops the previous set
    /// (the player is reused across episodes).
    private var aetherCancellables = Set<AnyCancellable>()

    /// True from `playNextEpisode()` committing until the next item plays. An
    /// `.ended` in this window belongs to the outgoing episode (the reused
    /// player's state subject replays on re-bind); acting on it double-autoplays.
    private var isSwappingItem = false

    /// Whether the loaded item has begun playing. The end funnel acts on
    /// `.ended` only when this is true, which rejects a stale `.ended` from the
    /// outgoing item. Cleared with `itemGeneration`.
    private var currentItemHasStarted = false
    private var controlsTimer: Timer?
    /// AVKit hides its controls 8s after the last press or focus move.
    private let controlsHideDelay: TimeInterval = 8
    private var scrubTimer: Timer?
    /// Holds the rail at a seek's target until the picture lands there. Fed by
    /// Aether's `seekEvents`; inert on the hls route, whose AVPlayer seek
    /// completion already means landed.
    private var seekHold = SeekHoldLogic()
    /// Target of a relative seek that has not returned yet, so a second quick
    /// skip builds on it instead of on a `currentTime` that has not moved.
    private var inFlightRelativeSeekTarget: TimeInterval?
    /// Bumped by every seek, so only the newest relative seek clears the
    /// in-flight target (two targets can be EQUAL when both clamp to an end).
    private var seekGeneration = 0
    private var wheelScrubbingTimer: Timer?
    private let wheelScrubbingIdleDelay: TimeInterval = 0.8
    private var appBecameActiveObserver: Any?
    private var appBackgroundObserver: Any?
    private var appResignActiveObserver: Any?
    /// Token for the block-based `.AVPlayerItemDidPlayToEndTime` observer.
    /// Block observers are keyed by the returned token, not by `self`, so this
    /// has to be stored to be removable.
    private var itemDidPlayToEndObserver: Any?
    private var pausedDueToAppInactive: Bool = false
    private let scrubUpdateInterval: TimeInterval = 0.1  // 100ms updates for smooth scrubbing
    private var seekIndicatorTimer: Timer?
    private var pausedPosterTimer: Timer?
    private let pausedPosterDelay: TimeInterval = 10.0
    private var pausedPosterDimTimer: Timer?
    private let pausedPosterDimDelay: TimeInterval = 120.0
    /// True while a rail panel is presented, so the ambient-pause backdrop
    /// stays off. Set by `PlayerContainerViewController`.
    var isRailPanelOpen = false {
        didSet {
            guard isRailPanelOpen != oldValue else { return }
            if isRailPanelOpen {
                cancelPausedPosterTimer()
            } else {
                // A panel suspends the controls-hide timer (see
                // `startControlsHideTimer`); closing it has to re-arm, or the
                // rail sits there forever after one Info visit.
                startControlsHideTimer()
                if playbackState == .paused { startPausedPosterTimer() }
            }
        }
    }
    private var aetherStallWatchdogTask: Task<Void, Never>?
    private let aetherStallRecoveryDelay: TimeInterval = 20
    private let aetherStallFailureDelay: TimeInterval = 20

    // MARK: - Playback Context

    let serverURL: String
    let authToken: String
    /// The item's own server, which may not be the selected one (#87).
    private var plexServer: PlexServerAddress { PlexServerAddress(address: serverURL, token: authToken) }
    private(set) var startOffset: TimeInterval?
    /// Where the item comes from. `.plex` is the legacy path; every
    /// `.provider` branch below returns before any Plex request is built.
    private(set) var source: PlaybackSource = .plex

    private var providerTimelineOffset: TimeInterval {
        guard case .provider(let playback) = source else { return 0 }
        return playback.stream.timelineOffset
    }

    private func sourcePosition(forPlayerTime time: TimeInterval) -> TimeInterval {
        time + providerTimelineOffset
    }

    private func playerPosition(forSourceTime time: TimeInterval) -> TimeInterval {
        max(0, time - providerTimelineOffset)
    }

    private var negotiatedPlayerStartTime: TimeInterval? {
        guard case .provider(let playback) = source else { return nil }
        return playback.stream.playerStartTime
    }

    private func setPlayerDuration(_ duration: TimeInterval) {
        if case .provider(let playback) = source, playback.stream.source.duration > 0 {
            self.duration = playback.stream.source.duration
        } else {
            self.duration = duration + providerTimelineOffset
        }
    }

    private var providerTracksRequireReplan: Bool {
        guard case .provider(let playback) = source else { return false }
        return !playback.stream.canSelectTracksLocally
    }

    private var nativeEngineAudioSelection = NativeAudioSelection()
    private var hasAppliedNativeEngineSubtitleSelection = false

    // MARK: - Progress Reporting

    private let reportingInterval: TimeInterval = 10
    private var lastReportedTime: TimeInterval = 0
    /// Paused timelines every `reportingInterval`, as Plex clients send, so the
    /// server can end a paused session (#403).
    private var pausedTimelineTask: Task<Void, Never>?
    /// `.provider` only: the play session's reporter. Recreated when the
    /// stream (and with it the play session) changes; nil once stopped.
    private var providerReporter: (any ProgressReporter)?
    private var providerReporterStarted = false
    private var providerInitialPosition: TimeInterval?
    private var providerSeekRequestGeneration = 0
    /// Latest transport intention while a provider load/replan is suspended.
    private var pendingProviderPlaybackIntent: Bool?
    /// Provider reports run in call order: a progress must never reach the
    /// server ahead of the start it follows.
    private var providerReportTail: Task<Void, Never>?
    let descriptionTranslationController = SiloDescriptionTranslationController()
    private var descriptionTranslationVisible = false

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
    /// The Plex stream whose transcode subtitle feeds the caption overlay (hls route).
    private var transcodeSubtitleTrackId: Int?
    private var transcodeSubtitleTask: Task<Void, Never>?
    private var transcodeSubtitleTimeObserver: Any?
    private var lastTranscodeSubtitleRestart = Date.distantPast
    /// Playback startup/fallback plan for Rivulet direct-play-first policy.
    private(set) var playbackPlan: PlaybackPlan?
    /// The route serving playback right now. Starts as the plan's primary and
    /// flips on HLS fallback; `playbackPlan.primary` is what was planned.
    private var activeRoute: PlaybackRoute?
    /// Optional prebuilt HLS fallback URL/headers to reduce fallback startup latency.
    private var rivuletFallbackURL: URL?
    private var rivuletFallbackHeaders: [String: String] = [:]
    /// One-shot direct-play -> HLS fallback guards (prevents loops).
    private var hasAttemptedRivuletHLSFallback = false
    /// One-shot: the enriched HLS asset failed and we rebuilt on the plain URL.
    private var hasRetriedWithoutEnrichment = false
    private var isAttemptingRivuletHLSFallback = false

    // MARK: - Streaming Quality State

    /// The quality picked in the player; nil follows the Home or Away setting. Lives for this player session.
    private var sessionQuality: StreamingQuality?
    private var siloRequestedQuality: MediaQualityPreference = .automatic
    private var siloManualQuality: MediaQualityPreference?
    private var siloBuffering = SiloBufferingQuality(policy: .ask)
    private var siloStallTask: Task<Void, Never>?
    private var siloSessionEventTask: Task<Void, Never>?
    var onSiloBufferingOffer: ((@escaping (Bool) -> Void) -> Void)?
    var onSiloBufferingCancel: (() -> Void)?
    var siloQualityChoices: [MediaQuality]? {
        guard case .provider(let playback) = source, playback.provider is SiloProvider else { return nil }
        return playback.stream.negotiatedStatus?.availableQualities
    }
    var siloActiveQualityID: String? {
        guard case .provider(let playback) = source else { return nil }
        return playback.stream.negotiatedStatus?.activeQualityID
    }
    var siloSelectedQuality: MediaQualityPreference { siloRequestedQuality }
    var canRestoreSiloQuality: Bool {
        guard case .provider(let playback) = source,
              let provider = playback.provider as? SiloProvider,
              let status = playback.stream.negotiatedStatus else { return false }
        return provider.supportsBufferingQuality(for: playback.stream)
            && siloBuffering.restore(status: status) != nil
    }
    var siloNegotiatedDetails: PlayerDetailsPaneView.Section? {
        guard case .provider(let playback) = source,
              let status = playback.stream.negotiatedStatus else { return nil }
        let delivery: String
        switch status.delivery {
        case .original: delivery = "Original"
        case .progressiveRemux: delivery = "Progressive remux"
        case .hlsRemux: delivery = "HLS remux"
        case .hlsTranscode: delivery = "HLS transcode"
        case .other(let name): delivery = name
        }
        var rows = [PlayerDetailsPaneView.Row(label: "Delivery", value: delivery)]
        let requested = siloRequestedQuality.serverValue
        if let active = status.activeQualityID, active != requested {
            rows.append(.init(label: "Requested", value: requested))
            rows.append(.init(label: "Playing", value: active))
        }
        if let recipe = status.effectiveRecipe {
            if let width = recipe.width, let height = recipe.height {
                rows.append(.init(label: "Output", value: "\(width) × \(height)"))
            }
            if let codec = recipe.videoCodec { rows.append(.init(label: "Video codec", value: codec)) }
            if let codec = recipe.audioCodec { rows.append(.init(label: "Audio codec", value: codec)) }
            if let range = recipe.dynamicRange { rows.append(.init(label: "Output range", value: range)) }
        }
        if let reason = status.decisionReason { rows.append(.init(label: "Decision", value: reason)) }
        for warning in status.degradationWarnings { rows.append(.init(label: "Adjustment", value: warning.message)) }
        if let limit = status.bandwidthLimit {
            rows.append(.init(label: "Connection limit", value: "\(limit.kbps) kbps (\(limit.source))"))
        }
        return .init(title: "SILO OUTPUT", rows: rows)
    }
    /// The quality in effect: the session pick, else the Home or Away setting.
    @Published private(set) var qualityChoice: StreamingQuality = .original
    /// What is playing: the untouched file, or a transcode at a step.
    @Published private(set) var activeStreamPlan: StreamPlan = .original
    private var isHomeLocation = true
    /// Last successful probe; Up Next and menu changes reuse it for 10 minutes.
    private var lastThroughput: (kbps: Int, at: Date)?
    private var stallTracker = StallTracker()
    private var longStallTask: Task<Void, Never>?
    /// Quality and track reloads run one at a time, in order.
    private var streamWorkTask: Task<Void, Never>?
    private var isReloadingStream = false
    private var trackReloadQueued = false
    private var pendingTrackReload: (tracks: PlexTrackIDs, item: MediaItemRef?, fileID: String?)?
    /// The picks a Plex transcode was started with, when Rivulet PUT them; seeds the HLS track ids.
    private var transcodeTrackIDs: PlexTrackIDs?
    /// `.provider`: the version the next quality reload plays, when the cap moved off the playing one.
    private var providerTargetSourceID: String?

    /// Causal-chain diagnostics for this playback session. Carries the ORIGINAL
    /// (primary-route) failure through to whatever error finally surfaces, so a
    /// fallback failure never reports itself as the root cause. See RIVULET-19.
    private let diagnostics = PlaybackDiagnostics()

    // MARK: - Play Queue

    /// The playlist being played, by position; nil plays one title with series Up Next.
    private(set) var playQueue: PlayQueue<PlaylistEntry>?
    /// Full Plex metadata for the next item, by ratingKey. Tests stub the server here.
    var plexMetadataFetch: (_ serverURL: String, _ authToken: String, _ ratingKey: String) async throws -> PlexMetadata = {
        try await PlexNetworkManager.shared.getFullMetadata(serverURL: $0, authToken: $1, ratingKey: $2)
    }

    // MARK: - Preloaded Next Episode Data

    private var preloadedNextStreamURL: URL?
    private var preloadedNextStreamHeaders: [String: String] = [:]
    private var preloadedNextMetadata: PlexMetadata?
    /// `.provider` only: the item behind each Up Next shim, by its ratingKey,
    /// so a chosen row plays its own `MediaItem`.
    private var providerEpisodeItems: [String: MediaItem] = [:]
    /// `.provider` only: this item's Up Next fetch, shared by every caller
    /// for one `itemGeneration`. A fetch that found nothing is dropped so the
    /// next caller asks again.
    private var providerUpNextFetch: (generation: Int, task: Task<(season: [MediaItem], next: MediaItem?), Never>)?
    /// `.provider` only: the next episode's prepare, keyed by its ratingKey,
    /// shared by the countdown-start prepare and the swap.
    private var nextProviderPrepare: (key: String, token: Int, task: Task<ProviderPlayback?, Never>)?
    private var nextProviderPreparationToken = 0
    /// Shown on the post-video page when the next episode can't be prepared.
    @Published private(set) var nextEpisodeError: String?
    /// Bumped by every `stopPlayback()`, so a swap that awaited its provider
    /// can tell the player was torn down meanwhile.
    private var stopCount = 0

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
        playQueue: PlayQueue<PlaylistEntry>? = nil,
        loadingArtImage: UIImage? = nil,
        loadingThumbImage: UIImage? = nil,
        initialAudioTrackId: Int? = nil,
        initialSubtitleSelection: InitialSubtitleSelection = .auto,
        preferredMediaID: String? = nil
    ) {
        // The chosen version goes first, so every `Media.first` read plays it.
        var metadata = metadata
        let selection = VersionRanking.select(preferredMediaID.map(VersionChoice.source) ?? .best,
                                              in: metadata.Media ?? [])
        if !selection.media.isEmpty { metadata.Media = selection.media }
        self.playingMediaID = selection.media.first.map { "\($0.id)" } ?? preferredMediaID
        self.playingMediaServerIndex = selection.serverIndex
        self.pickedVersion = preferredMediaID != nil
        self.baseVersionChoice = preferredMediaID.map(VersionChoice.source) ?? .best
        self.metadata = metadata
        self.serverURL = serverURL
        self.authToken = authToken
        self.startOffset = startOffset
        self.playQueue = playQueue
        self.loadingArtImage = loadingArtImage
        self.loadingThumbImage = loadingThumbImage
        self.initialAudioTrackId = initialAudioTrackId
        self.initialSubtitleSelection = initialSubtitleSelection
        // The server's duration until the engine reports its own, so the bar's
        // fill shows with the first times instead of a second after them.
        self.duration = Self.metadataDuration(metadata)

        let isAirPlayRoute = Self.isAirPlayOutput()
        let hasDolbyVision = metadata.hasDolbyVision

        // Get container format for logging
        let container = metadata.Media?.first?.Part?.first?.container?.lowercased() ?? ""

        let dvProfile = metadata.Media?.first?.Part?.first?.Stream?
            .first { $0.isVideo && (($0.DOVIProfile != nil) || ($0.DOVIPresent == true)) }?
            .DOVIProfile

        DiagLog.notice(.playback, "Selected: DV=\(hasDolbyVision) profile=\(dvProfile ?? -1) container=\(container) airPlay=\(isAirPlayRoute)")

        setupPlayer()

        addPlaybackSelectionBreadcrumb(reason: "init")
    }

    /// Play any `MediaProvider` item. The chrome reads a display-only
    /// `PlexMetadata` shim; stream, tracks and reporting come from the provider.
    convenience init(
        providerPlayback: ProviderPlayback,
        startOffset: TimeInterval?,
        playQueue: PlayQueue<PlaylistEntry>? = nil,
        loadingArtImage: UIImage? = nil,
        loadingThumbImage: UIImage? = nil,
        preferredMediaID: String? = nil
    ) {
        self.init(
            metadata: ProviderPlaybackMetadata.make(
                detail: providerPlayback.detail,
                source: providerPlayback.stream.source,
                extras: providerPlayback.extras
            ),
            serverURL: "",
            authToken: "",
            startOffset: startOffset,
            playQueue: playQueue,
            loadingArtImage: loadingArtImage,
            loadingThumbImage: loadingThumbImage,
            preferredMediaID: preferredMediaID
        )
        setProviderStream(providerPlayback, startPosition: startOffset)
        // Lets `preparedNextProviderPlayback` start any entry.
        for entry in playQueue?.entries ?? [] {
            providerEpisodeItems[entry.item.ref.itemID] = entry.item
        }
    }

    /// Store the provider's current stream and a reporter for its play
    /// session. A new stream is a new play session, so the reporter follows it.
    private func setProviderStream(_ playback: ProviderPlayback, startPosition: TimeInterval? = nil,
                                   preservingReporter: Bool = false) {
        siloSessionEventTask?.cancel()
        siloSessionEventTask = nil
        siloStallTask?.cancel()
        siloStallTask = nil
        onSiloBufferingCancel?()
        if siloBuffering.pendingOffer != nil { siloBuffering.cancelOffer() }
        if case .provider(let old) = source, old.item.ref != playback.item.ref {
            siloBuffering = SiloBufferingQuality(policy: playback.nativeBufferingPolicy ?? .ask,
                requestedQuality: playback.nativeRequestedQuality ?? .automatic)
        }
        if case .provider(let previous) = source,
           previous.item.ref != playback.item.ref || previous.stream.source.id != playback.stream.source.id {
            resetSiloSubtitleActions()
            Task { [weak self] in await self?.resolveSubtitleSearchAccess() }
        }
        source = .provider(playback)
        if let provider = playback.provider as? SiloProvider,
           playback.stream.playSessionID != nil {
            let stream = playback.stream
            let item = playback.item.ref
            let generation = itemGeneration
            let stops = stopCount
            siloSessionEventTask = Task { @MainActor [weak self] in
                let events = await provider.playbackSessionEvents(for: stream)
                for await event in events {
                    guard let self, !Task.isCancelled, self.stopCount == stops,
                          self.itemGeneration == generation,
                          case .provider(let current) = self.source,
                          current.item.ref == item,
                          current.stream.playSessionID == stream.playSessionID else { return }
                    self.handleSiloSessionEvent(event, provider: provider, stream: stream, item: item)
                }
            }
        }
        if let requested = playback.nativeRequestedQuality { siloRequestedQuality = requested }
        if playback.provider is SiloProvider, let status = playback.stream.negotiatedStatus {
            if siloBuffering.requestedQuality != siloRequestedQuality {
                siloBuffering.manualQualityChanged(to: siloRequestedQuality)
            }
            if let policy = playback.nativeBufferingPolicy {
                siloBuffering.setPolicy(policy)
            }
            siloBuffering.adopt(status: status)
        }
        if !preservingReporter || !providerReporterStarted {
            providerInitialPosition = startPosition ?? playback.stream.playerStartTime.map { $0 + playback.stream.timelineOffset }
        }
        if !playback.stream.canSelectTracksLocally {
            audioTracks = []
            subtitleTracks = []
            hasAppliedAudioPreference = false
            hasAppliedSubtitlePreference = false
            currentAudioTrackId = nil
            currentSubtitleTrackId = nil
        }
        if playback.provider is SiloProvider, let selection = playback.stream.authoritativeSubtitleSelection {
            switch selection {
            case .off:
                currentSubtitleTrackId = nil
                subtitlesPickedOff = true
            case .track(let id, _):
                let ordinal = playback.stream.source.subtitleTracks.firstIndex { $0.id == id }
                currentSubtitleTrackId = ordinal.flatMap { plexSubtitleTracksFromMetadata()[safe: $0]?.id }
                subtitlesPickedOff = false
            }
            hasAppliedSubtitlePreference = true
        }
        if !preservingReporter {
            providerReporter = playback.provider.progressReporter(
                for: playback.item.ref,
                sourceID: playback.stream.source.id,
                playSessionID: playback.stream.playSessionID
            )
            providerReporterStarted = false
        }
        if descriptionTranslationController.detail?.item.ref != playback.item.ref {
            configureDescriptionTranslation()
        }
    }

    var descriptionText: String? {
        guard case .provider(let playback) = source, playback.provider is SiloProvider,
              let detail = descriptionTranslationController.detail, detail.item.ref == playback.item.ref else {
            return metadata.summary
        }
        return detail.item.overview ?? metadata.summary
    }

    var descriptionOverviewIsMachineTranslated: Bool {
        guard descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              case .provider(let playback) = source, playback.provider is SiloProvider else { return false }
        if let detail = descriptionTranslationController.detail, detail.item.ref == playback.item.ref {
            return detail.item.overviewIsMachineTranslated == true
        }
        return playback.detail.item.overviewIsMachineTranslated == true
    }

    func beginDescriptionTranslation() {
        descriptionTranslationVisible = true
        configureDescriptionTranslation()
    }

    func endDescriptionTranslation() {
        descriptionTranslationVisible = false
        descriptionTranslationController.stop()
    }

    private func configureDescriptionTranslation() {
        guard case .provider(let playback) = source, let provider = playback.provider as? SiloProvider else {
            descriptionTranslationController.stop()
            return
        }
        let detail: MediaItemDetail
        if let current = descriptionTranslationController.detail, current.item.ref == playback.item.ref {
            detail = current
        } else {
            detail = playback.detail
        }
        descriptionTranslationController.configure(provider: provider, detail: detail,
                                                   allowAutomatic: descriptionTranslationVisible)
    }

    /// The provider stream's first route. A direct-play stream goes to Aether
    /// and can fall back to a provider transcode; a transcode plays on AVPlayer
    /// with nothing behind it. nil when the provider gave no URL.
    static func initialRoutes(for stream: StreamInfo) -> (primary: PlaybackRoute, hasTranscodeFallback: Bool)? {
        guard let url = stream.source.streamURL else { return nil }
        if stream.prefersAetherPlayback {
            return (.aether(url: url, headers: stream.httpHeaders),
                    stream.negotiatedStatus == nil && stream.source.streamKind != .hlsTranscode)
        }
        switch stream.source.streamKind {
        case .hlsTranscode:
            return (.hls(url: url, headers: stream.httpHeaders), false)
        case .directPlay, .progressiveTranscode:
            return (.aether(url: url, headers: stream.httpHeaders), true)
        }
    }

    private static func metadataDuration(_ metadata: PlexMetadata) -> TimeInterval {
        metadata.duration.map { TimeInterval($0) / 1000 } ?? 0
    }

    private func setupPlayer() {
        bindPlayerState()
        observeAppLifecycle()
        observeContentFilter()
    }

    /// Mirror the content filter's mute decision onto the active player. The
    /// filter is fed active subtitle text from `applyContentFilter(at:)` on the
    /// time tick (using the on-screen cue set for whichever route is active).
    private func observeContentFilter() {
        contentFilter.$isFilterMuting
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] muting in
                self?.applyContentFilterMute(muting)
            }
            .store(in: &cancellables)

        // An image cue's words arrive after the tick that asked for them.
        subtitleImageReader.onRead = { [weak self] in
            guard let self else { return }
            self.contentFilter.subtitleLinesDidChange(self.subtitleLinesForFilter(at: self.currentTime))
        }

        // On-device speech places muted words on the audio and writes generated subtitles (aether route only).
        $aetherPlayer
            .combineLatest(contentFilter.$isEnabled.combineLatest(contentFilter.$isPaused).map { $0 && !$1 },
                           $currentSubtitleTrackId, SpeechModelStore.shared.$state)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] player, filtering, subtitle, model in
                let captions = subtitle == Self.generatedSubtitleId
                self?.syncSpeechRecognition(player: player, wanted: (filtering || captions) && model == .ready)
            }
            .store(in: &cancellables)

        // Pausing, Settings, or a list or file arriving all change whether a track is read unseen.
        contentFilter.$isEnabled
            .combineLatest(contentFilter.$isPaused, contentFilter.$hasLanguageSource)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncSilentSubtitleRead() }
            .store(in: &cancellables)

        // A fresh player instance (e.g. the HLS fallback mid-item) starts
        // unmuted; re-assert the filter's current decision when either player
        // slot changes so a mute window survives the swap.
        $aetherPlayer.combineLatest($player)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] aether, avPlayer in
                guard let self, self.contentFilter.isFilterMuting else { return }
                aether?.setMuted(true)
                avPlayer?.isMuted = true
            }
            .store(in: &cancellables)
    }

    /// Silence (or restore) the active player's audio for the filter. Aether's
    /// `setMuted` persists across the engine's internal player swaps; the HLS
    /// route mutes the AVPlayer directly.
    private func applyContentFilterMute(_ muting: Bool) {
        aetherPlayer?.setMuted(muting)
        player?.isMuted = muting
    }

    /// Apply the content filter at the given playhead: seek past a scene-skip
    /// window when one is entered. Muting is handled reactively via the
    /// published `isFilterMuting`. Called from both time observers.
    private func applyContentFilter(at time: TimeInterval) {
        // Feed the currently on-screen dialogue so language cues mute in sync.
        // Cues resolve on the sourceTime axis, honoring the subtitle delay. On
        // the HLS route only a shown text track feeds this; otherwise language
        // muting comes from the subtitle file the filter reads itself (see
        // `contentFilterItem()`).
        readSubtitleImages(at: time)
        contentFilter.subtitleLinesDidChange(subtitleLinesForFilter(at: time))
        // The delay stepper only moves what's on screen on the aether route.
        contentFilter.displayedSubtitleDidChange(
            streamKey: aetherPlayer == nil
                ? nil
                : subtitleTracks.first(where: { $0.id == currentSubtitleTrackId })?.subtitleKey,
            delay: aetherSubtitleModel.delaySeconds)
        syncSilentSubtitleRead()
        // Only the aether route gives the filter cues to read.
        let tracks = aetherPlayer == nil ? [] : subtitleTracks
        // With nothing to read, the words the speech model hears are filtered directly.
        let speechOnly = speechTask != nil && !contentFilter.hasLanguageSource
            && !tracks.contains(where: ContentFilterSources.isReadable)
        contentFilter.setSpeechOnly(speechOnly)
        let notice = !contentFilter.isEnabled || speechOnly ? nil : ContentFilterSources.languageNotice(
            hasLanguageSource: contentFilter.hasLanguageSource,
            shown: tracks.first(where: { $0.id == currentSubtitleTrackId }),
            tracks: tracks)
        if notice != contentFilterNotice { contentFilterNotice = notice }

        let skipTarget = contentFilter.timeDidUpdate(time, allowSkip: !isScrubbing)
        scheduleMuteEdge(after: time)
        guard let skipTarget else { return }
        // A window that runs to (or past) the end of the item would otherwise
        // seek beyond EOF; land just short so playback ends normally instead.
        let target = duration > 0 ? min(skipTarget, max(0, duration - 0.25)) : skipTarget
        Task { [weak self] in
            await self?.seek(to: target, revealsControls: false)
        }
    }

    /// Start, move or end the filter's unseen read of an embedded subtitle track.
    /// Never saves a preference: the user's subtitles stay Off.
    private func syncSilentSubtitleRead() {
        guard aetherLoadReturned || aetherPlayer == nil else { return }
        let wanted = !contentFilter.isEnabled || contentFilter.isPaused || !contentFilter.readsSubtitleText
            ? nil : ContentFilterSources.silentTrack(
                in: aetherPlayer == nil ? [] : subtitleTracks,
                shownTrackId: showsGeneratedSubtitles ? nil : currentSubtitleTrackId,
                hasLanguageSource: contentFilter.hasLanguageSource)?.id
        guard wanted != silentSubtitleTrackId else { return }
        silentSubtitleTrackId = wanted
        // A track the user has on already holds the engine's one selection.
        if currentSubtitleTrackId == nil || showsGeneratedSubtitles { aetherPlayer?.selectSubtitleTrack(id: wanted) }
    }

    /// Have the image cues around the playhead read (PGS, VobSub), ahead of
    /// time so a line's words are known before it is spoken.
    private func readSubtitleImages(at time: TimeInterval) {
        let trackId = showsGeneratedSubtitles ? silentSubtitleTrackId : currentSubtitleTrackId ?? silentSubtitleTrackId
        guard contentFilter.isEnabled, !contentFilter.isPaused, !contentFilter.hasLanguageSource,
              contentFilter.readsSubtitleText,
              let track = subtitleTracks.first(where: { $0.id == trackId }),
              ContentFilterSources.isReadable(track), !ContentFilterSources.isTextSubtitle(codec: track.codec)
        else { return subtitleImageReader.read([]) }
        let now = time - aetherSubtitleModel.delaySeconds
        subtitleImageReader.read(filterCues.compactMap { cue in
            guard cue.endTime >= now, cue.startTime <= now + 30, case .image(let image, _) = cue.body else { return nil }
            return image
        })
    }

    /// What the content filter needs to know about the current item. The
    /// subtitle file is one of Plex's external streams, fetched with the same
    /// URL shape the engine registers them with (`aetherExternalSubtitles`).
    private func contentFilterItem() -> ContentFilterItem {
        let guids = metadata.Guid?.compactMap(\.id) ?? []
        let part = metadata.Media?.first?.Part?.first
        let transcript = contentFilterTranscript()

        return ContentFilterItem(
            ratingKey: metadata.ratingKey,
            imdbID: guids.lazy.compactMap { PlexMetadata.extractImdbId(from: $0) }.first,
            tmdbID: guids.lazy.compactMap { PlexMetadata.extractTmdbId(from: $0) }.first.map { String($0) },
            tvdbID: guids.lazy.compactMap { PlexMetadata.extractTvdbId(from: $0) }.first.map { String($0) },
            fileName: part?.file.flatMap { ContentFilterItem.baseName(ofPath: $0) },
            duration: metadata.duration.map { TimeInterval($0) / 1000 },
            transcript: transcript
        )
    }

    /// The subtitle file the content filter reads for language muting.
    var contentFilterTranscriptURL: URL? { contentFilterTranscript()?.url }

    /// A Plex stream key is server-relative and takes the token; a provider
    /// sidecar's key is its own URL (see `ProviderPlaybackMetadata`), used as is.
    private func contentFilterTranscript() -> ContentFilterItem.TranscriptSource? {
        let streams = metadata.Media?.first?.Part?.first?.Stream ?? []
        guard let stream = ContentFilterSources.transcriptStream(in: streams), let key = stream.key else { return nil }
        let url: URL?
        switch source {
        case .plex:
            guard var components = URLComponents(string: "\(serverURL)\(key)") else { return nil }
            components.queryItems = (components.queryItems ?? [])
                + [URLQueryItem(name: "X-Plex-Token", value: authToken)]
            url = components.url
        case .provider:
            url = URL(string: key)
        }
        return url.map { ContentFilterItem.TranscriptSource(url: $0, format: stream.codec ?? "", streamKey: key) }
    }

    /// The subtitle lines currently on screen, as plain text, for the content
    /// filter's language matching.
    /// Cue-axis time the video shows at `hostTime`, for the libass layer's
    /// display link. nil when there is no Aether presentation timebase.
    func subtitleSourceTime(atHostTime hostTime: CFTimeInterval) -> Double? {
        if let aetherPlayer { return aetherPlayer.sourceTime(atHostTime: hostTime) }
        // hls route: the AVPlayer item's clock is media time, as the transcode's cues are.
        guard transcodeSubtitleTrackId != nil, let timebase = player?.currentItem?.timebase else { return nil }
        let host = CMTime(seconds: hostTime, preferredTimescale: 1_000_000_000)
        let seconds = CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: timebase).seconds
        return seconds.isFinite ? seconds : nil
    }

    // MARK: - hls route text subtitles

    /// Starts reading the transcode's text subtitle into the caption overlay, or
    /// clears it when the session carries none. Cues of the same track survive a
    /// reload: their times are media time.
    private func startTranscodeSubtitles() {
        stopTranscodeSubtitleReader()
        let trackId = currentSubtitleTrackId
        let track = trackId.flatMap { id in plexSubtitleTracksFromMetadata().first { $0.id == id } }
        guard aetherPlayer == nil, case .plex = source, case .hls = activeRoute,
              let track, ContentFilterSources.isTextSubtitle(codec: track.codec),
              let hlsURL = streamURL, let url = PlexNetworkManager.transcodeSubtitlesURL(forHLS: hlsURL) else {
            clearTranscodeSubtitles()
            return
        }
        if transcodeSubtitleTrackId != track.id {
            clearTranscodeSubtitles()
            transcodeSubtitleTrackId = track.id
        }
        var request = URLRequest(url: url)
        for (key, value) in streamHeaders { request.setValue(value, forHTTPHeaderField: key) }
        if let player {
            transcodeSubtitleTimeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated { self?.aetherSubtitleModel.sourceTime = time.seconds }
            }
        }
        let sessionId = plexSessionId
        transcodeSubtitleTask = Task { [weak self] in
            let gotHeader = await TranscodeSubtitleStream.read(request, onHeader: { header in
                guard let self else { return }
                if self.assTrack?.trackId != track.id || self.assTrack?.header != header {
                    self.assTrack = ASSTrackSource(trackId: track.id, header: header, fonts: [])
                }
            }, onEvent: { event in
                // ponytail: one update per line re-walks the list in the libass feed; batch if long files show it.
                self?.appendTranscodeCue(AetherSubtitleCue(id: 0, startTime: event.start, endTime: event.end,
                                                           body: .assEvents(event.line)))
            })
            guard let self, !Task.isCancelled else { return }
            // PMS closes the stream when a seek past the transcoded range restarts
            // its transcoder, and asking again then starts a second session over the
            // first. Restarting the transcode at the playhead brings a fresh stream.
            guard gotHeader, self.plexSessionId == sessionId, self.duration - self.playheadForReload > 30,
                  Date().timeIntervalSince(self.lastTranscodeSubtitleRestart) > 15 else { return }
            self.lastTranscodeSubtitleRestart = Date()
            self.reloadTranscodeForTrackChange()
        }
    }

    private func appendTranscodeCue(_ cue: AetherSubtitleCue) {
        var cues = aetherSubtitleModel.cues
        // A reloaded transcode resends lines from its own start, so it can land mid-list.
        cues.insert(cue, at: cues.lastIndex { $0.startTime <= cue.startTime }.map { $0 + 1 } ?? 0)
        aetherSubtitleModel.update(cues: cues)
    }

    private func stopTranscodeSubtitleReader() {
        transcodeSubtitleTask?.cancel()
        transcodeSubtitleTask = nil
        if let transcodeSubtitleTimeObserver, let player { player.removeTimeObserver(transcodeSubtitleTimeObserver) }
        transcodeSubtitleTimeObserver = nil
    }

    private func clearTranscodeSubtitles() {
        guard transcodeSubtitleTrackId != nil else { return }
        transcodeSubtitleTrackId = nil
        aetherSubtitleModel.update(cues: [])
        assTrack = nil
    }

    /// The cues of the track the engine reads (the overlay may be showing generated ones).
    private var filterCues: [AetherSubtitleCue] { showsGeneratedSubtitles ? engineCues : aetherSubtitleModel.cues }

    /// Cues near the playhead from the track the engine reads, on the audio's
    /// axis, so the filter knows a muted line before it is spoken.
    private func subtitleLinesForFilter(at time: TimeInterval) -> [SubtitleLine] {
        let delay = aetherSubtitleModel.delaySeconds
        return filterCues.compactMap { cue in
            let start = cue.startTime + delay, end = cue.endTime + delay
            guard end > time - 1, start < time + 6, let text = filterText(for: cue) else { return nil }
            return SubtitleLine(id: cue.id, start: start, end: end, text: text)
        }
    }

    private func filterText(for cue: AetherSubtitleCue) -> String? {
        switch cue.body {
        case .text(let string): return string
        case .styledText(let runs): return runs.map(\.text).joined()
        case .image(let image, _): return subtitleImageReader.text(for: image)
        case .assEvents(let lines):
            // Words only: the Style, Name and Effect fields and the tag
            // names would otherwise reach the profanity matcher as words.
            let text = ASSEventLine.lines(in: lines)
                .filter { !$0.isDrawing }
                .map(\.plainText)
                .joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
    }

    /// Run the speech model on this player's audio while filtering wants it.
    private func syncSpeechRecognition(player: AetherPlayer?, wanted: Bool) {
        guard let player, wanted else {
            speechTask?.cancel()
            speechTask = nil
            speechPlayer = nil
            return
        }
        guard speechPlayer !== player || speechTask == nil else { return }
        speechTask?.cancel()
        speechPlayer = player
        let audio = player.playbackAudio()
        let filter = contentFilter
        speechTask = Task.detached(priority: .utility) { [weak self] in
            guard let models = await SpeechModelStore.load() else { return }
            await SpeechWordRecognizer.run(models: models, audio: audio) { [weak self] words, range in
                await filter.wordsHeard(words, covering: range)
                await self?.captionWordsHeard(words, covering: range)
            }
        }
    }

    /// On an item after the one they were picked on, generated subtitles give way to real English ones.
    private func preferRealSubtitlesOverGenerated() {
        if case .provider(let playback) = source,
           playback.stream.authoritativeSubtitleSelection != nil { return }
        guard showsGeneratedSubtitles, metadata.ratingKey != generatedSubtitlesPickedOn,
              let real = subtitleTracks.first(where: {
                  !$0.isForced && TrackLanguage.normalize($0.languageCode ?? $0.language) == "eng"
              }) else { return }
        selectSubtitleTrackWithoutSaving(id: real.id)
    }

    static let generatedSubtitlesFallbackKey = "generatedSubtitlesFallback"

    /// Settings → Generated Subtitles: subtitles set to Always, no track in that language, English or unlabeled audio.
    private func fallBackToGeneratedSubtitles() {
        guard SettingsStore.bool(Self.generatedSubtitlesFallbackKey, default: false),
              offersGeneratedSubtitles, currentSubtitleTrackId == nil, !subtitlesPickedOff,
              case .track(_, false, _, _) = TrackIntentStore.effectiveSubtitleIntent,
              playingAudioLanguage.map({ TrackLanguage.normalize($0) == "eng" }) ?? true else { return }
        if case .off = initialSubtitleSelection { return }
        selectSubtitleTrackWithoutSaving(id: Self.generatedSubtitleId)
    }

    private func captionWordsHeard(_ words: [SpokenWord], covering range: ClosedRange<Double>) {
        heardWords.add(words, covering: range)
        if showsGeneratedSubtitles { aetherSubtitleModel.update(cues: generatedCues()) }
    }

    private func generatedCues() -> [AetherSubtitleCue] {
        SpeechCaptions.lines(from: heardWords.words).map { line in
            AetherSubtitleCue(id: Int(line.start * 1000), startTime: line.start, endTime: line.end, body: .text(line.text))
        }
    }

    /// Act on a mute edge due before the next tick at the moment it is due,
    /// read from the player's own clock, so a word is cut on time.
    private func scheduleMuteEdge(after time: TimeInterval) {
        muteEdgeWork?.cancel()
        muteEdgeWork = nil
        guard playbackState == .playing,
              let edge = contentFilter.nextMuteEdge(after: time), edge - time < 0.25 else { return }
        let now = aetherPlayer?.sourceTime(atHostTime: CACurrentMediaTime()) ?? time
        let work = DispatchWorkItem { [weak self] in self?.contentFilter.clockDidReach(edge + 0.001) }
        muteEdgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, edge - now), execute: work)
    }

    /// Clear any prepared stream state so the next startup recomputes route + URLs.
    private func resetPreparedStreamContext() {
        streamPreparationTask?.cancel()
        streamPreparationTask = nil
        streamURL = nil
        streamHeaders = [:]
        playbackPlan = nil
        activeRoute = nil
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
            // Before the Aether early-return: a torn-down engine reports buffering
            // forever, and the watchdog must not wake it. Hopped because the
            // closure is not statically isolated.
            Task { @MainActor [weak self] in
                self?.cancelAetherStallWatchdog()
            }
            // HLS route only: AetherPlayer handles background itself, and pausing
            // here would make a watching user return paused.
            if self.aetherPlayer != nil { return }
            if self.playbackState == .playing {
                self.pausedDueToAppInactive = true
                print("[Player] App entering background — pausing")
                Task { @MainActor in
                    self.pause()
                }
            }
        }

        // The screensaver is a resign-active, not a background, so the handler
        // above misses it; stop the watchdog resuming a paused session (#247).
        appResignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Hopped onto the main actor for the same reason as the buffering
            // observer above: delivery is already on `.main`, but the closure
            // is not statically isolated. The capture is repeated on the Task
            // rather than reusing the enclosing closure's, which would be a
            // reference to a captured var from concurrently-executing code.
            Task { @MainActor [weak self] in
                self?.cancelAetherStallWatchdog()
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
            // The foreground reload rebuffers by design.
            Task { @MainActor [weak self] in
                self?.stallTracker.noteSeekOrLoad(at: Date())
            }
        }
    }

    func prepareStreamURL() async {
        let networkManager = PlexNetworkManager.shared

        guard metadata.ratingKey != nil else { return }

        // Sticky per-item subtitle delay (OSD stepper).
        loadStoredSubtitleDelay()

        // A provider item plays the stream its provider resolved. Returns
        // before the Plex metadata fetch and ContentRouter, both of which
        // would build Plex requests from the display shim.
        if case .provider(let playback) = source {
            prepareProviderStream(playback)
            return
        }

        // Fetch full metadata if Media array is missing (needed for info overlay display)
        // This happens when starting playback from Continue Watching or other hubs with minimal metadata
        if metadata.Media == nil || metadata.Media?.isEmpty == true {
            await fetchFullMetadataIfNeeded()
        }

        await decideStreamPlan()

        let routingContext = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: serverURL)!,
            authToken: authToken,
            playbackPolicy: .directPlayFirst,
            transcodeStep: activeStreamPlan.step
        )
        let plan = ContentRouter.plan(for: routingContext)
        playbackPlan = plan
        activeRoute = plan.primary
        rivuletFallbackURL = nil
        rivuletFallbackHeaders = [:]
        // Tag the chosen route for App Hang triage (RIVULET-41).
        AppHangContext.setPlaybackRoute(plan.primary.description)
        // Tag content shape on the global scope too, so an App Hang captured by
        // the watchdog is sliceable by resolution / HDR / codec — the dimensions
        // most correlated with mid-playback stalls. Coarse, low-cardinality.
        let hdrLabel: String
        switch metadata.hdrFormatDisplay {
        case "Dolby Vision": hdrLabel = "dolby_vision"
        case .some(let value) where !value.isEmpty: hdrLabel = "hdr"
        default: hdrLabel = "sdr"
        }
        AppHangContext.setContent(
            resolution: (metadata.Media?.first?.videoResolution ?? "unknown").lowercased(),
            hdr: hdrLabel,
            videoCodec: (metadata.primaryVideoStream?.codec ?? "unknown").lowercased()
        )
        // Seed the media fingerprint (codec / DV profile / audio / resume offset)
        // so EVERY playback error from here on is self-describing. Without this,
        // "playback failed" can't be told apart from "playback fails on DV P7".
        diagnostics.setMedia(
            metadata,
            route: plan.primary.description,
            startOffset: startOffset,
            isRelay: PlexRelay.isRelayURL(serverURL),
            quality: qualityChoice.rawValue,
            location: isHomeLocation ? "home" : "away"
        )
        diagnostics.step("route_selected", detail: plan.description)

        switch plan.primary {
        case .hls:
            let tracks = startingTrackSelection
            transcodeTrackIDs = tracks
            await putTrackSelection(tracks)
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
            if let ratingKey = metadata.ratingKey {
                let mediaIndex = playingMediaServerIndex, server = plexServer
                Task { await PlexProgressReporter.shared.beginDirectPlaySession(
                    ratingKey: ratingKey, mediaIndex: mediaIndex, server: server) }
            }

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

    /// `.provider` half of `prepareStreamURL`. The provider's URL carries
    /// its own auth, so no headers. A direct-play stream gets an `.hls`
    /// fallback in the plan so `planHasHLSFallback` arms the Aether-failure
    /// fallback; its URL is a placeholder nobody reads, because the transcode
    /// is only requested from the provider when the fallback actually fires.
    private func prepareProviderStream(_ playback: ProviderPlayback) {
        rivuletFallbackURL = nil
        rivuletFallbackHeaders = [:]
        let quality = playback.quality
        qualityChoice = quality.choice
        activeStreamPlan = quality.plan
        isHomeLocation = quality.isHome
        if let throughput = quality.throughput { lastThroughput = throughput }
        stallTracker = StallTracker()
        guard let plan = Self.providerPlan(for: playback.stream),
              let url = playback.stream.source.streamURL else { return }
        playbackPlan = plan
        activeRoute = plan.primary
        streamURL = url
        streamHeaders = playback.stream.httpHeaders
        AppHangContext.setPlaybackRoute(plan.primary.description)
        diagnostics.setMedia(metadata, route: plan.primary.description, startOffset: startOffset, isRelay: false,
                             quality: quality.choice.rawValue, location: quality.isHome ? "home" : "away")
        diagnostics.step("route_selected", detail: plan.description)
    }

    private static func providerPlan(for stream: StreamInfo) -> PlaybackPlan? {
        guard let routes = initialRoutes(for: stream), let url = stream.source.streamURL else { return nil }
        return PlaybackPlan(
            policy: .directPlayFirst,
            primary: routes.primary,
            fallbacks: routes.hasTranscodeFallback
                ? [.hls(url: url, headers: stream.httpHeaders.isEmpty ? nil : stream.httpHeaders)] : [],
            reasoning: ["provider stream: \(stream.source.streamKind)"]
        )
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

    /// Per-category delivery mode for the Info sheet. Branches on the route, not
    /// on whether `aetherPlayer` exists, which is nil around startup and teardown (#245).
    /// On aether nothing is Transcode; TrueHD and DTS-HD MA are Direct Stream
    /// because the engine re-encodes them to FLAC on device.
    var streamingModeInfo: StreamingModeInfo {
        if case .provider(let playback) = source, let status = playback.stream.negotiatedStatus {
            let video: StreamingModeInfo.Mode
            switch status.delivery {
            case .original: video = .directPlay
            case .progressiveRemux, .hlsRemux: video = .directStream
            case .hlsTranscode: video = .transcode
            case .other: video = .unknown
            }
            let audioCodec = metadata.Media?.first?.Part?.first?.Stream?.first(where: { $0.isAudio })?.codec
            let audio: StreamingModeInfo.Mode = video == .unknown ? .unknown : video == .transcode ? .transcode
                : AetherAudioDelivery.isReencoded(codec: audioCodec) ? .directStream : .directPlay
            return StreamingModeInfo(video: video, audio: audio,
                                     subtitles: .directPlay)
        }
        if case .aether = activeRoute {
            let audioCodec = metadata.Media?.first?.Part?.first?
                .Stream?.first(where: { $0.isAudio })?.codec
                ?? metadata.Media?.first?.audioCodec
            return StreamingModeInfo(
                video: .directPlay,
                audio: AetherAudioDelivery.isReencoded(codec: audioCodec) ? .directStream : .directPlay,
                subtitles: .directPlay
            )
        }
        return StreamingModeInfo(
            video: ContentRouter.requiresVideoTranscode(metadata: metadata) ? .transcode : .directStream,
            audio: Self.isAudioDirectStreamCapable(metadata) ? .directStream : .transcode,
            subtitles: .directPlay
        )
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
        NotificationCenter.default.publisher(for: .mediaProviderAccountsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, case .provider(let playback) = self.source,
                      !MediaProviderRegistry.shared.isCurrentAuthority(playback.provider) else { return }
                self.stopPlayback()
            }
            .store(in: &cancellables)
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
                        if dur.isFinite { self.setPlayerDuration(dur) }
                        self.updateTrackLists()
                        self.startTranscodeSubtitles()
                    case .failed:
                        let message = item.error?.localizedDescription ?? "Playback failed"
                        DiagLog.error(.playback, "HLS item failed: \(item.error.map(DiagLog.describe) ?? message)")
                        // Teardown races (session ending, transcode stopped
                        // server-side) land here as NSURLError -999 on
                        // `item.error`. That is not a playback failure — don't
                        // report it and don't burn the one-shot HLS fallback on
                        // an item nobody is watching any more (RIVULET-19).
                        if let itemError = item.error, isCancellationError(itemError) {
                            print("[Player] AVPlayerItem failed with cancellation — ignoring")
                            break
                        }
                        // Recorded even when the HLS fallback rescues it.
                        let itemError = item.error ?? PlayerError.loadFailed(message)
                        self.diagnostics.recordPrimaryFailure(
                            itemError,
                            kind: self.classifyDirectPlayFailure(PlayerError.loadFailed(message)),
                            route: self.activeRoute?.description.lowercased() ?? "unknown"
                        )
                        // The enriched asset is a custom scheme nothing else
                        // can load, so its failure is total. The plain URL
                        // behind it already passed preflight, so rebuild on it
                        // and keep the session instead of spending the one-shot
                        // HLS fallback (or ending playback) over track labels.
                        if self.retryWithoutEnrichment() { break }
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
            if let existing = itemDidPlayToEndObserver {
                NotificationCenter.default.removeObserver(existing)
            }
            itemDidPlayToEndObserver = NotificationCenter.default.addObserver(
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
                let sourceTime = self.sourcePosition(forPlayerTime: time.seconds)
                self.currentTime = sourceTime
                self.checkMarkers(at: sourceTime)
                self.tickReplayWindow(at: sourceTime)
                self.applyContentFilter(at: sourceTime)
            }
        }
        timeObserver = observer
        _timeObserverForCleanup = observer
    }

    /// Tear down AVPlayer observers.
    private func teardownAVPlayerObservers() {
        stopTranscodeSubtitleReader()
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
        if let itemDidPlayToEndObserver {
            NotificationCenter.default.removeObserver(itemDidPlayToEndObserver)
        }
        itemDidPlayToEndObserver = nil
    }

    /// Update playback state with side effects (controls, screensaver, post-video).
    /// When the current session last entered `.buffering`, for measuring how
    /// long a mid-playback stall lasted. nil while not buffering.
    private var bufferingStartedAt: Date?

    private func updatePlaybackState(_ state: UniversalPlaybackState) {
        updateSiloBuffering(from: playbackState, to: state)
        recordStallTransition(from: playbackState, to: state)
        trackQualityStall(from: playbackState, to: state)
        playbackState = state
        isBuffering = state == .buffering

        if state == .playing {
            // Not while swapping: the reused player's CurrentValueSubject
            // replays the OUTGOING episode's `.playing` into the re-bind, and
            // taking that as "the new item started" would re-arm the funnel for
            // the old stream's EOF.
            if !isSwappingItem { currentItemHasStarted = true }
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
                // Every pause path funnels through here, so this is the one
                // place that reliably disarms the stall watchdog when the user
                // stops asking for playback (issue #247).
                cancelAetherStallWatchdog()
            } else {
                cancelPausedPosterTimer()
            }
        }

        if state == .ended, currentItemHasStarted {
            Task { await finishPlayback() }
        }
    }

    /// Measure mid-playback rebuffering. A stall that the user waits through
    /// leaves no Sentry signal today unless it escalates to a watchdog hang;
    /// this drops a breadcrumb on buffering-exit carrying how long we stalled
    /// and at what position, so the trail before a later hang/crash shows
    /// whether playback was starving. Startup buffering (position ~0) is already
    /// covered by PlaybackDiagnostics' timeline, so it's skipped here.
    private func recordStallTransition(from previous: UniversalPlaybackState, to next: UniversalPlaybackState) {
        if next == .buffering, previous != .buffering {
            bufferingStartedAt = Date()
            return
        }
        guard previous == .buffering, next != .buffering, let startedAt = bufferingStartedAt else { return }
        bufferingStartedAt = nil

        let stallSeconds = Date().timeIntervalSince(startedAt)
        // Only report mid-playback stalls worth looking at; ignore startup and
        // sub-second rebuffers that are just normal pipeline breathing.
        guard currentTime > 1, stallSeconds >= 2 else { return }

        let crumb = Breadcrumb(level: stallSeconds >= 10 ? .warning : .info, category: "playback_stall")
        crumb.message = String(format: "Rebuffered %.1fs at %.0fs", stallSeconds, currentTime)
        crumb.data = [
            "stall_seconds": stallSeconds,
            "position_seconds": currentTime,
            "resolved_to": next.appHangLabel,
            "route": activeRoute?.description.lowercased() ?? "unknown"
        ]
        SentryBridge.addBreadcrumb(crumb)
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
        hasRetriedWithoutEnrichment = false
        isAttemptingRivuletHLSFallback = false

        // Stop existing player before retrying
        stopPlayback()
        resetPreparedStreamContext()

        await startPlayback()
    }

    func startPlayback() async {
        guard stopCount == 0 else { return }
        Task { await resolveSubtitleSearchAccess() }
        // Fetch detailed metadata if markers or chapters are missing
        let hasMarkers = !(metadata.Marker ?? []).isEmpty
        let hasChapters = !(metadata.Chapter ?? []).isEmpty
        let hasStreamDetails = metadata.Media?.first?.Part?.first?.Stream?.isEmpty == false
        if !hasMarkers || !hasChapters || !hasStreamDetails {
            await fetchMarkersIfNeeded()
        }
        // A Plex item's chapter images arrive with the fetch above; a provider
        // item's come from its detail.
        if case .provider = source, let chapters = metadata.Chapter {
            chapterThumbnails = [:]
            await fetchChapterThumbnails(chapters: chapters)
        }

        // Arm the local content filter for this item: reload settings, restore
        // any cached filter list, then refresh it and read the subtitle file.
        // After the fetch above, because both key off the file, the external
        // ids and the subtitle streams that hub items arrive without.
        contentFilter.beginItem(contentFilterItem())
        heardWords = SpokenWordStore()
        // A purged or never-finished speech model downloads again.
        if contentFilter.isEnabled { SpeechModelStore.shared.prepare() }

        // IntroDB backup markers (opt-in). Runs AFTER the Plex fetch above so
        // Plex stays authoritative — the backfill only adds kinds Plex didn't
        // provide. Detached so a slow/dead community DB can't delay start.
        // A provider item's markers come from its provider (in the shim).
        if case .plex = source, UserDefaults.standard.bool(forKey: "useIntroDB") {
            Task { [weak self] in
                await self?.backfillMarkersFromIntroDB()
            }
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
        guard stopCount == 0 else { return }
        let stops = stopCount
        if providerTracksRequireReplan { pendingProviderPlaybackIntent = true }
        defer { pendingProviderPlaybackIntent = nil }
        await ensureStreamURLPrepared()
        guard !Task.isCancelled, stops == stopCount else { return }

        guard let url = streamURL else {
            errorMessage = "No stream URL available"
            playbackState = .failed(.invalidURL)
            return
        }
        hasAttemptedRivuletHLSFallback = false
        hasRetriedWithoutEnrichment = false
        isAttemptingRivuletHLSFallback = false

        addPlaybackSelectionBreadcrumb(reason: "startAVPlayerPlayback")

        do {
            // Aether drives AVDisplayManager.preferredDisplayCriteria
            // itself, synchronously before AVPlayer.replaceCurrentItem, so
            // Rivulet's DisplayCriteriaManager stands down here to avoid
            // two writers fighting over the panel-mode handshake.

            if let startOffset { _ = try await prepareProviderSeek(to: startOffset) }
            let plan = playbackPlan ?? ContentRouter.plan(for: ContentRoutingContext(
                metadata: metadata,
                serverURL: URL(string: serverURL)!,
                authToken: authToken,
                playbackPolicy: .directPlayFirst,
                transcodeStep: activeStreamPlan.step
            ))
            try await startWithFallback(plan: plan, startTime: startOffset)
            guard !Task.isCancelled, stops == stopCount else { return }

            if let ap = aetherPlayer {
                // Aether kicks playback through its own internal AVPlayer;
                // Rivulet's `player` is nil on this path. Just call play()
                // on the adapter and let Aether's state machine drive.
                print("[Aether] play() — adapter")
                if pendingProviderPlaybackIntent == false { ap.pause() } else { ap.play() }
            } else {
                let itemStatus = player?.currentItem?.status.rawValue ?? -1
                let bufferEmpty = player?.currentItem?.isPlaybackBufferEmpty ?? true
                let bufferFull = player?.currentItem?.isPlaybackBufferFull ?? false
                let likelyKeepUp = player?.currentItem?.isPlaybackLikelyToKeepUp ?? false
                print("[Player] play() — status=\(itemStatus) bufferEmpty=\(bufferEmpty) bufferFull=\(bufferFull) likelyKeepUp=\(likelyKeepUp)")
                player?.play()
            }

            // Index for Siri Suggestions. The activity replays by Plex
            // ratingKey, so a provider item has none.
            if case .plex = source {
                let activity = NSUserActivity(activityType: "com.rivulet.playMedia")
                activity.title = metadata.title
                activity.isEligibleForSearch = true
                activity.userInfo = ["ratingKey": metadata.ratingKey ?? ""]
                activity.targetContentIdentifier = "rivulet://play?ratingKey=\(metadata.ratingKey ?? "")"
                self.userActivity = activity
                activity.becomeCurrent()
            }
            if let dur = player?.currentItem?.duration.seconds, dur.isFinite {
                self.setPlayerDuration(dur)
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
        // A provider URL carries its own auth; no Plex header may reach it.
        if case .provider = source { return [:] }
        return [
            "X-Plex-Token": authToken,
            "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
            "X-Plex-Platform": PlexAPI.platform,
            "X-Plex-Device": PlexAPI.deviceName,
            "X-Plex-Product": PlexAPI.productName
        ]
    }

    /// Build an HLS URL and headers for Rivulet fallback at the requested offset.
    private func buildRivuletHLSURL(offset: TimeInterval?) -> (url: URL, headers: [String: String], sessionId: String?)? {
        // Plex transcode only. A provider's transcode is requested from the
        // provider in `attemptRivuletHLSFallback`.
        guard case .plex = source, let ratingKey = metadata.ratingKey else { return nil }
        // Source video codec has no Apple TV decoder (e.g. MPEG-2): the
        // direct-play-shaped URL would hand back the raw file and the
        // local decoder would fail. Flip on forceVideoTranscode so the
        // URL becomes a real transcode request.
        let forceVideoTranscode = ContentRouter.requiresVideoTranscode(metadata: metadata)
        guard let result = PlexNetworkManager.shared.buildHLSDirectPlayURL(
            serverURL: serverURL,
            authToken: authToken,
            ratingKey: ratingKey,
            mediaIndex: playingMediaServerIndex,
            offsetMs: Int((offset ?? 0) * 1000),
            hasHDR: metadata.hasHDR,
            useDolbyVision: metadata.hasDolbyVision,
            forceVideoTranscode: forceVideoTranscode,
            allowAudioDirectStream: allowAudioDirectStreamDecision(reason: "rivulet_hls_fallback_build"),
            step: activeStreamPlan.step,
            clientRendersTextSubtitles: true
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
            case .unknown, .serverTerminated:
                return .unknown
            case .engineFailure(let kind, _):
                // The engine already classified this. Everything below is the
                // guess we make when nobody did.
                return DirectPlayFailureKind(engineKind: kind)
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

    func planHasHLSFallback(_ plan: PlaybackPlan?) -> Bool {
        guard let plan else { return false }
        return plan.fallbacks.contains { route in
            if case .hls = route { return true }
            return false
        }
    }

    /// Rebuild the current item on the plain URL after an enriched HLS asset
    /// failed. Returns true when it took over, so the caller stops.
    ///
    /// At most once per session, and only while the enricher is the active asset.
    private func retryWithoutEnrichment() -> Bool {
        guard let enricher = hlsManifestEnricher, !hasRetriedWithoutEnrichment else { return false }
        guard let url = streamURL else { return false }
        hasRetriedWithoutEnrichment = true

        diagnostics.step(
            "hls_enricher_retry_plain",
            detail: enricher.lastFailure ?? "item failed with enriched asset active"
        )
        do {
            try loadAVPlayer(url: url, headers: streamHeaders, allowEnrichment: false)
            player?.play()
            return true
        } catch {
            // Nothing recoverable left; fall through to the normal failure path.
            hlsManifestEnricher = nil
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
        stallTracker.noteSeekOrLoad(at: Date())
        defer { stallTracker.noteSeekOrLoad(at: Date()) }
        let playerStart = startTime.map { playerPosition(forSourceTime: $0) } ?? negotiatedPlayerStartTime
        switch plan.primary {
        case .hls:
            // Up Next can move a session from the file to a transcode.
            releaseAetherPlayer()
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

            if let playerStart, playerStart > 0 {
                await player?.seek(to: CMTime(seconds: playerStart, preferredTimescale: 600))
            }

        case .aether(let url, let headers):
            let aetherURL = streamURL ?? url
            let aetherHeaders = streamHeaders.isEmpty ? (headers ?? rivuletDirectPlayHeaders()) : streamHeaders
            // And from a transcode back to the file.
            releaseAVPlayer()
            if case .provider(let playback) = source, playback.stream.source.streamKind == .hlsTranscode {
                guard await waitForHLSTranscodeReady(url: aetherURL, headers: aetherHeaders) else {
                    throw PlayerError.loadFailed("The provider's HLS stream did not become ready")
                }
            }
            do {
                let ap = aetherPlayer ?? AetherPlayer()
                aetherPlayer = ap
                // A load drops the engine's selection; the unseen read is chosen again from its tracks.
                aetherSubtitleModel.update(cues: [])
                silentSubtitleTrackId = nil
                aetherLoadReturned = false
                bindAetherPublishers(ap)
                // Feed title/artwork/description to Aether's internal AVPlayerItem
                // (it makes its own item, so our native-path externalMetadata never
                // reaches it). Set before load so Aether stashes + replays it.
                ap.setExternalMetadata(buildExternalMetadata())
                // Raced against a deadline (#245): a load that never returns never
                // throws, so without one the HLS fallback never fires.
                try await runAetherLoadWithDeadline(
                    ap,
                    url: aetherURL,
                    headers: aetherHeaders,
                    startTime: playerStart
                )
                aetherLoadReturned = true
                // An item with no subtitles publishes nothing to replace the last item's list.
                if ap.subtitleTracks.isEmpty { subtitleTracks = [] }
                // Adopts the engine's own selection, then starts the unseen read if there is none.
                updateTrackLists()
                preferRealSubtitlesOverGenerated()
                fallBackToGeneratedSubtitles()
            } catch {
                // Cancellation is not a failure: return, since a rethrow fires a
                // second failure event. The deadline error is not a cancellation
                // and must get past this guard to reach the fallback.
                if isCancellationError(error) || Task.isCancelled { return }
                let kind = classifyDirectPlayFailure(error)
                // Record the original Aether failure first, so a failed fallback
                // cannot hide it (RIVULET-19).
                diagnostics.recordPrimaryFailure(
                    error,
                    kind: kind,
                    route: "aether",
                    engineKind: (error as? PlayerError)?.engineKind,
                    engineUnderlying: aetherPlayer?.lastEngineErrorUnderlying
                )
                // Not awaited: nothing may delay the HLS fallback.
                probeStreamBodyForDiagnostics(
                    url: aetherURL,
                    headers: aetherHeaders,
                    error: error,
                    kind: kind
                )
                guard planHasHLSFallback(plan), !isStacked else { throw error }
                // Separate reasons so a hang (#245) and a thrown error stay separate issues.
                let reason = error is AetherLoadTimeoutPolicy.TimedOut
                    ? AetherLoadTimeoutPolicy.fallbackReason
                    : "aether_startup_load_failed"
                try await attemptRivuletHLSFallback(
                    resumeTime: startTime ?? 0,
                    reason: reason,
                    failureKind: kind
                )
                return
            }
        }
    }

    /// Run `AetherPlayer.load` with a deadline, throwing
    /// `AetherLoadTimeoutPolicy.TimedOut` if the engine does not return in time.
    ///
    /// The task group reaps the losing child before returning. Engine teardown on
    /// timeout is left to `attemptRivuletHLSFallback`.
    private func runAetherLoadWithDeadline(
        _ ap: AetherPlayer,
        url: URL,
        headers: [String: String],
        startTime: TimeInterval?
    ) async throws {
        let deadline = AetherLoadTimeoutPolicy.startupLoadDeadline
        let hints = aetherSubtitleLanguageHintsByStreamIndex()
        let audioLanguages = aetherPreferredAudioLanguages()
        let subtitleLanguages = aetherPreferredSubtitleLanguages()
        let externalSubtitles = aetherExternalSubtitles()
        let stackedParts = stackedParts()
        let subtitleTimelineOffset = providerTimelineOffset

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await ap.load(
                    url: url,
                    headers: headers,
                    startTime: startTime,
                    subtitleLanguageHintsByStreamIndex: hints,
                    preferredAudioLanguages: audioLanguages,
                    preferredSubtitleLanguages: subtitleLanguages,
                    externalSubtitles: externalSubtitles,
                    externalSubtitleTimelineOffset: subtitleTimelineOffset,
                    stackedParts: stackedParts
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                // Reached only when the load is still in flight.
                DiagLog.error(.playback, "Aether load exceeded \(Int(deadline))s deadline, falling back to HLS")
                throw AetherLoadTimeoutPolicy.TimedOut(seconds: deadline)
            }

            do {
                // Waits for the first child to finish.
                try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
        }
    }

    /// True when Plex stacks the playing version from several files (#399).
    /// Only the Aether route plays those through; a transcode would play the first file.
    private var isStacked: Bool {
        guard case .plex = source else { return false }
        return (metadata.Media?.first?.Part?.count ?? 0) > 1
    }

    /// Every file of a stacked version with its sidecars, nil for one file.
    private func stackedParts() -> StackedParts<AetherPlayer.PartFile>? {
        guard isStacked, let parts = metadata.Media?.first?.Part, let base = URL(string: serverURL) else { return nil }
        var files: [(file: AetherPlayer.PartFile, duration: TimeInterval?)] = []
        for part in parts {
            guard let key = part.key,
                  let url = ContentRouter.directPlayURL(partKey: key, serverURL: base, authToken: authToken) else { return nil }
            files.append((AetherPlayer.PartFile(url: url, externalSubtitles: aetherExternalSubtitles(in: part)),
                          part.duration.map { TimeInterval($0) / 1000 }))
        }
        return StackedParts(files)
    }

    /// External (sidecar) subtitle streams, registered with the engine at load.
    /// Order matches metadata stream order, which `TrackMerge` pairs on.
    func aetherExternalSubtitles(in part: PlexPart? = nil) -> [AetherPlayer.SidecarSubtitle] {
        // A provider's sidecars are its external tracks, in source order (the
        // order the shim's subtitle streams carry, which TrackMerge pairs on).
        // Their URLs are absolute and carry the provider's own auth.
        if case .provider(let playback) = source {
            return playback.stream.source.subtitleTracks.filter { !$0.isEmbedded }.compactMap { track in
                guard let url = track.externalURL else { return nil }
                return AetherPlayer.SidecarSubtitle(
                    url: url,
                    name: track.extendedTitle ?? track.title,
                    language: track.language,
                    isForced: track.isForced,
                    isHearingImpaired: track.isHearingImpaired,
                    isDefault: track.isDefault,
                    formatHint: track.codec,
                    httpHeaders: track.externalHTTPHeaders
                )
            }
        }
        guard let streams = (part ?? metadata.Media?.first?.Part?.first)?.Stream else { return [] }
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
        if providerTracksRequireReplan { return [] }
        var languages: [String] = []

        if let id = initialAudioTrackId,
           let track = plexAudioTracksFromMetadata().first(where: { $0.id == id }) {
            languages.append(contentsOf: languageCandidates(for: track))
        }

        if let id = plexChosenAudioStreamId,
           let track = plexAudioTracksFromMetadata().first(where: { $0.id == id }) {
            languages.append(contentsOf: languageCandidates(for: track))
        }

        let audioIntent = TrackIntentStore.effectiveAudioIntent
        if audioIntent.language != TrackLanguage.original {
            languages.append(audioIntent.language)
        } else if let main = TrackIntentResolver.resolveAudio(intent: audioIntent, in: plexAudioTracksFromMetadata()) {
            languages.append(contentsOf: languageCandidates(for: main))
        }

        if let selected = plexAudioTracksFromMetadata().first(where: { $0.isDefault }) {
            languages.append(contentsOf: languageCandidates(for: selected))
        }

        return uniqueNonEmpty(languages)
    }

    private func aetherPreferredSubtitleLanguages() -> [String] {
        if providerTracksRequireReplan { return [] }
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

        switch TrackIntentStore.effectiveSubtitleIntent {
        case let .track(language, _, _, _) where !language.isEmpty:
            languages.append(language)
        case .off:
            break
        case .foreignAudio:
            let audio = TrackIntentResolver.resolveAudio(intent: TrackIntentStore.effectiveAudioIntent,
                                                         in: plexAudioTracksFromMetadata())
            if let track = TrackIntentResolver.resolveSubtitle(
                intent: TrackIntentStore.effectiveSubtitleIntent, in: plexSubtitleTracksFromMetadata(),
                audioLanguage: audio?.languageCode ?? audio?.language) {
                languages.append(contentsOf: languageCandidates(for: track))
            }
        case .track:
            // An intent with no usable language: fall back to the file's
            // forced/default subtitle stream.
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
        // Same instance on a next-episode swap, so drop the previous bind
        // before adding this one.
        aetherCancellables.removeAll()
        player.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                // `.ended` goes through `updatePlaybackState` so the end funnel runs.
                if state == .ended {
                    self.updatePlaybackState(.ended)
                } else if state == .playing, player.isBuffering {
                    self.updatePlaybackState(.buffering)
                } else {
                    self.updatePlaybackState(state)
                }
                // Load the Up Next panel list once playback starts. The aether
                // route never publishes a backing AVPlayer, so this can't hang
                // off `$currentAVPlayer` (that path serves the hls route only).
                // Driven off `.playing` — the decode-backend-independent signal.
                if state == .playing, !self.upNextEpisodesLoaded {
                    self.upNextEpisodesLoaded = true
                    Task { await self.loadUpNextEpisodes() }
                }
            }
            .store(in: &aetherCancellables)

        // Ids are monotonic per engine instance, so a fresh player starts over.
        seekHold = SeekHoldLogic()
        inFlightRelativeSeekTarget = nil
        seekGeneration += 1
        nativeEngineAudioSelection = NativeAudioSelection()
        hasAppliedNativeEngineSubtitleSelection = false
        player.seekEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                if let time = self.seekHold.apply(event) {
                    self.currentTime = self.sourcePosition(forPlayerTime: time)
                }
            }
            .store(in: &aetherCancellables)

        player.timePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                // A tick that predates the landing reports the position the
                // picture has already left: it would snap the rail back to
                // where the seek started, and hand markers and the content
                // filter a stale playhead to act on.
                guard !self.seekHold.isHolding else { return }
                let sourceTime = self.sourcePosition(forPlayerTime: time)
                self.currentTime = sourceTime
                // Drive marker handling for Aether (skip intro/credits/ad buttons,
                // auto-skip, and the real Plex credits-marker post-video trigger).
                // Mirrors the AVPlayer periodic observer (~line 979). Aether
                // ticks at 0.1s (native host)
                // or 0.25s (software host), both finer than checkMarkers' ~0.5s
                // assumption, so no throttle change is needed.
                self.checkMarkers(at: sourceTime)
                self.tickReplayWindow(at: sourceTime)
                self.applyContentFilter(at: sourceTime)
            }
            .store(in: &aetherCancellables)

        player.durationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dur in
                if dur > 0 { self?.setPlayerDuration(dur) }
            }
            .store(in: &aetherCancellables)

        player.errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] err in
                self?.errorMessage = err.userFacingDescription
            }
            .store(in: &aetherCancellables)

        // Subtitle overlay feed: Aether decodes cues (text and PGS/DVB
        // bitmap) and publishes them; the host renders via
        // CaptionOverlayView driven by this model. sourceTime shares
        // the engine clock tick so cue lookup can't drift from playback.
        // A reused player replays the last item's cues on subscribe.
        player.$subtitleCues
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                self.engineCues = cues
                if !self.showsGeneratedSubtitles { self.aetherSubtitleModel.update(cues: cues) }
            }
            .store(in: &aetherCancellables)

        player.$assTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in self?.assTrack = track }
            .store(in: &aetherCancellables)

        // Mirrored onto the view model because AetherPlayer is not an
        // ObservableObject: a SwiftUI view reading `aetherPlayer.videoSize`
        // directly would never re-render, since `$aetherPlayer` only fires
        // when the PLAYER changes, not its properties.
        player.$videoSize
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                self?.videoSize = size
            }
            .store(in: &aetherCancellables)

        player.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                self?.aetherSubtitleModel.sourceTime = t
            }
            .store(in: &aetherCancellables)

        // Up Next early resolve. The playhead must know the next episode
        // BEFORE the credits marker so the overlay can present without a
        // fetch stall. Guarded to run once per episode; the publisher
        // re-emits on every Aether AVPlayer swap.
        player.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avp in
                guard let self, avp != nil else { return }  // hls route (AVPlayer-backed) only
                Task { await self.resolveNextEpisodeEarlyIfNeeded() }
            }
            .store(in: &aetherCancellables)

        // Engine track lists. Both funnel through updateTrackLists(), which
        // merges them with Plex's streams into ONE list per type (engine index
        // as the id, Plex's forced/SDH/commentary labels folded on). Either
        // side can arrive first, so the merge re-runs on each.
        // A reused player replays the outgoing item's value; the load publishes this item's.
        player.$audioTracks
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                guard let self, !tracks.isEmpty else { return }
                self.updateTrackLists()
            }
            .store(in: &aetherCancellables)

        player.$subtitleTracks
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                guard let self, !tracks.isEmpty else { return }
                self.updateTrackLists()
            }
            .store(in: &aetherCancellables)

        player.$activeAudioTrackId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self, !self.providerTracksRequireReplan, let id else { return }
                self.currentAudioTrackId = id
            }
            .store(in: &aetherCancellables)

        player.$activeSubtitleTrackId
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                // Ignore engine nil: the engine clears it transiently while it
                // rebuilds the pipeline. A user turn-off does not come through here.
                // A track read unseen for the content filter is not the user's pick.
                guard let self, let id, self.silentSubtitleTrackId == nil else { return }
                // Generated subtitles are not an engine track: an engine re-activation (after a reload) is undone, not adopted.
                if self.showsGeneratedSubtitles {
                    self.aetherPlayer?.selectSubtitleTrack(id: nil)
                    return
                }
                // Provider tracks are server-authoritative and require a new stream plan.
                guard !self.providerTracksRequireReplan else { return }
                // Track ids ARE engine indices on this route (see TrackMerge) —
                // the engine's active index needs no translation.
                self.currentSubtitleTrackId = id
            }
            .store(in: &aetherCancellables)

        player.$isBuffering
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak player] buffering in
                guard let self, let player else { return }
                self.handleAetherBufferingChanged(buffering, player: player)
            }
            .store(in: &aetherCancellables)
    }

    // MARK: - HLS Manifest Debugging

    /// Fetch and log the HLS master manifest to inspect track labels and I-frame playlists.
    private func logHLSManifest(url: URL, headers: [String: String]) async {
        let url = avPlayerURL(url)
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
    /// - Parameter allowEnrichment: false skips `HLSManifestEnricher` and loads the
    ///   plain URL. A failure in the enricher's custom-scheme asset kills the whole
    ///   session (RIVULET-62), so `retryWithoutEnrichment` trades the labels for playback.
    private func loadAVPlayer(url: URL, headers: [String: String]?, allowEnrichment: Bool = true) throws {
        let url = avPlayerURL(url)
        teardownAVPlayerObservers()
        player?.pause()
        hlsManifestEnricher = nil

        let asset: AVURLAsset

        // For HLS URLs, use the manifest enricher to inject audio/subtitle track labels.
        // The enricher intercepts ONLY the master playlist (custom scheme), patches it,
        // and rewrites all sub-URLs to absolute HTTP so AVPlayer fetches them directly.
        // Plex only: the enricher is tuned to the PMS manifest and labels
        // tracks from Plex metadata, which a provider transcode need not match.
        if allowEnrichment,
           case .plex = source,
           url.path.contains("start.m3u8") || url.pathExtension == "m3u8",
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
        if let rating = metadata.displayContentRating {
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
        if metadata.type == "episode" || isLaterQueueItem {
            // Prefer season/show poster over episode screenshot for Now Playing
            if let poster = seasonPosterImage { return poster }
        }
        // The loading images are the first playlist entry's.
        return isLaterQueueItem ? nil : loadingThumbImage ?? loadingArtImage
    }

    /// A playlist item after the first: the swap replaced it, the loading images stayed.
    private var isLaterQueueItem: Bool { playQueue != nil && itemGeneration > 0 }

    /// Fetch the season or show poster for episode Now Playing artwork.
    /// Called before building external metadata so the image is ready.
    private func fetchSeasonPosterIfNeeded() async {
        let isEpisode = metadata.type == "episode"
        guard isEpisode || isLaterQueueItem else { return }
        // Never show the outgoing playlist item's poster.
        if isLaterQueueItem { seasonPosterImage = nil }

        // Try season poster first, then show poster; a later playlist movie uses its own
        let posterURL = artworkURL(
            plex: { plexImageURL(isEpisode ? metadata.parentThumb ?? metadata.grandparentThumb : metadata.thumb) },
            provider: { isEpisode ? $0.item.parentArtwork?.poster ?? $0.item.grandparentArtwork?.poster
                : $0.item.artwork.poster }
        )
        guard let url = posterURL else { return }

        // The app's image session trusts raw-IP Plex servers; URLSession.shared does not.
        let generation = itemGeneration
        guard let image = await ImageCacheManager.shared.image(for: url),
              generation == itemGeneration else { return }
        seasonPosterImage = image
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

        if let url = artworkURL(
            plex: { plexImageURL(metadata.clearLogoPath) },
            provider: { $0.item.artwork.logo ?? $0.item.grandparentArtwork?.logo }
        ) {
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
        // A provider episode's own ids are the episode's, so it asks for its show's.
        let providerEpisode = providerEpisode
        let knownTmdbID = providerEpisode == nil
            ? metadata.tmdbId ?? metadata.parentShowTmdbId ?? metadata.showTmdbId
            : nil
        guard providerEpisode != nil || knownTmdbID != nil else { return }
        let type: TMDBMediaType = metadata.type == "movie" ? .movie : .tv
        titleLogoResolveTask = Task { [weak self] in
            var tmdbID = knownTmdbID
            if let providerEpisode { tmdbID = await self?.providerShowTmdbID(providerEpisode) }
            guard let tmdbID, !Task.isCancelled,
                  let url = await TMDBLogoCache.shared.logoURL(tmdbId: tmdbID, type: type) else { return }
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
        let thumbChapters: [(index: Int, url: URL)] = chapters.compactMap { chapter in
            guard let index = chapter.index, let url = chapterThumbnailURL(chapter) else { return nil }
            return (index, url)
        }
        let thumbCount = thumbChapters.count
        guard thumbCount > 0 else { return }
        print("[Chapters] Fetching \(thumbCount) chapter thumbnails (max 3 concurrent)...")

        // Use a limited concurrency approach to avoid N+1 API call detection
        let maxConcurrency = 3

        await withTaskGroup(of: (Int, Data?).self) { group in
            var iterator = thumbChapters.makeIterator()
            var inFlight = 0

            // Seed initial batch
            while inFlight < maxConcurrency, let (index, url) = iterator.next() {
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
                if let (nextIndex, url) = iterator.next() {
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

    /// A Plex chapter's own thumb path; a provider chapter's image from its
    /// detail (the shim numbers chapters from 1 in detail order).
    func chapterThumbnailURL(_ chapter: PlexChapter) -> URL? {
        artworkURL(
            plex: { plexImageURL(chapter.thumb) },
            provider: { playback in
                guard let index = chapter.index, playback.detail.chapters.indices.contains(index - 1) else { return nil }
                return playback.detail.chapters[index - 1].thumbnailURL
            }
        )
    }

    /// A still for a chapter the server has no thumb for: the BIF frame, else an engine decode.
    func chapterStill(at time: TimeInterval) async -> UIImage? {
        if currentScrubThumbnailSource == .server, let partId = metadata.Media?.first?.Part?.first?.id,
           let image = await PlexThumbnailService.shared.getThumbnail(
               partId: partId, time: time, serverURL: serverURL, authToken: authToken) {
            return image
        }
        guard let frame = await aetherPlayer?.scrubFrame(atSeconds: time, maxWidth: 640) else { return nil }
        return UIImage(cgImage: frame)
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

        DiagLog.error(.playback, "Fallback to HLS: \(failureKind.rawValue), \(reason.prefix(200))")

        let fallback: (url: URL, headers: [String: String], sessionId: String?)?
        if case .provider = source {
            if let url = try await switchToProviderTranscode(resumeTime: resumeTime),
               case .provider(let playback) = source {
                if playback.stream.prefersAetherPlayback {
                    prepareProviderStream(playback)
                    guard let plan = playbackPlan else { throw MediaProviderError.notPlayable }
                    releaseAetherPlayer()
                    releaseAVPlayer()
                    try await startWithFallback(plan: plan, startTime: resumeTime)
                    return
                }
                fallback = (url, playback.stream.httpHeaders, nil)
            } else {
                fallback = nil
            }
        } else if resumeTime <= 0.5, let prebuiltURL = rivuletFallbackURL, !rivuletFallbackHeaders.isEmpty {
            let sessionId = URLComponents(url: prebuiltURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "session" })?.value
            fallback = (prebuiltURL, rivuletFallbackHeaders, sessionId)
        } else {
            fallback = buildRivuletHLSURL(offset: resumeTime)
        }

        guard let fallback else {
            throw PlayerError.loadFailed("Unable to build HLS fallback URL")
        }

        // The Aether session is torn down here, so this is the point the
        // session stops being the planned route. Tagged before the preflight:
        // a fallback that dies in preflight still died on HLS.
        transcodeTrackIDs = nil
        beginHLSSwitch(to: fallback)

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

        try await finishHLSSwitch(to: fallback, resumeTime: resumeTime)
    }

    /// First half of moving onto an HLS URL: stops the outgoing Plex transcode and any
    /// Aether session, and points the session at the new URL. The caller preflights.
    private func beginHLSSwitch(to hls: (url: URL, headers: [String: String], sessionId: String?)) {
        stopOutgoingTranscode()
        if case .plex = source, let ratingKey = metadata.ratingKey {
            let server = plexServer
            Task { await PlexProgressReporter.shared.endDirectPlaySession(ratingKey: ratingKey, server: server) }
        }
        cancelAetherStallWatchdog()
        // Left running, Aether keeps its audio under the AVPlayer and holds the
        // render surface (UniversalPlayerView switches surfaces on aetherPlayer == nil).
        releaseAetherPlayer()
        teardownAVPlayerObservers()
        player?.pause()
        streamURL = hls.url
        streamHeaders = hls.headers
        plexSessionId = hls.sessionId
        activeRoute = .hls(url: hls.url, headers: hls.headers)
        AppHangContext.setPlaybackRoute(activeRoute?.description)
        stallTracker.noteSeekOrLoad(at: Date())
    }

    /// Second half: load the preflighted URL and seek to where playback was.
    private func finishHLSSwitch(to hls: (url: URL, headers: [String: String], sessionId: String?),
                                 resumeTime: TimeInterval) async throws {
        try loadAVPlayer(url: hls.url, headers: hls.headers)
        if resumeTime > 0 {
            await player?.seek(to: CMTime(seconds: playerPosition(forSourceTime: resumeTime), preferredTimescale: 600))
        }
        stallTracker.noteSeekOrLoad(at: Date())
    }

    /// Callers move to HLS, whose track ids are Plex stream ids, so the engine-indexed lists go too.
    private func releaseAetherPlayer() {
        guard let ap = aetherPlayer else { return }
        // A released engine no longer owns universal state. In particular its
        // stop -> idle publication must not overwrite a terminal reload error.
        aetherCancellables.removeAll()
        ap.stop()
        aetherPlayer = nil
        aetherSubtitleModel.update(cues: [])
        assTrack = nil
        audioTracks = []
        subtitleTracks = []
    }

    private func releaseAVPlayer() {
        guard player != nil else { return }
        teardownAVPlayerObservers()
        clearTranscodeSubtitles()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        _playerForCleanup = nil
        hlsManifestEnricher = nil
        hlsRelay = nil
    }

    /// Frees the server transcode this session was playing, if any.
    private func stopOutgoingTranscode() {
        guard case .plex = source, let sessionId = plexSessionId else { return }
        plexSessionId = nil
        stopTranscode(sessionId: sessionId)
    }

    private func stopTranscode(sessionId: String) {
        let serverURL = serverURL
        let authToken = authToken
        Task {
            await PlexNetworkManager.shared.stopTranscodeSession(
                serverURL: serverURL,
                authToken: authToken,
                sessionId: sessionId
            )
        }
    }

    /// Negotiate a provider delivery at the source playhead. Native replans keep
    /// their session/reporter; backends without replanning use a new transcode.
    /// `maxBitrate` (bps) caps it; nil leaves the bitrate to the server.
    func switchToProviderTranscode(resumeTime: TimeInterval, maxBitrate: Int? = nil,
                                   tracks: PlexTrackIDs = PlexTrackIDs(), forceTranscode: Bool = true) async throws -> URL? {
        guard case .provider(var playback) = source else { return nil }
        let stops = stopCount
        let oldSessionID = playback.stream.playSessionID
        let explicitSource = providerTargetSourceID
        let retargetingNative = providerTracksRequireReplan && explicitSource != nil
        let audio = retargetingNative ? nil : providerAudioIndex(for: tracks.audio, source: playback.stream.source)
        let subtitle = retargetingNative ? nil : providerSubtitleIndex(for: tracks.subtitle, source: playback.stream.source)
        if let replacement = try await playback.provider.replaceStream(
            for: playback.item.ref, current: playback.stream, sourceID: explicitSource,
            position: resumeTime, maxBitrate: maxBitrate, audioStreamIndex: audio,
            subtitleStreamIndex: subtitle, forceTranscode: forceTranscode
        ) {
            playback.stream = replacement
        } else {
            playback.stream = try await playback.provider.transcodeStream(
                for: playback.item.ref, sourceID: explicitSource ?? playback.stream.source.id,
                startTime: resumeTime, maxBitrate: maxBitrate,
                audioStreamIndex: audio, subtitleStreamIndex: subtitle)
        }
        guard !Task.isCancelled, stops == stopCount else {
            await ProviderPlayback.discardUnplayedStream(playback.stream, provider: playback.provider)
            throw CancellationError()
        }
        providerTargetSourceID = nil
        playback.quality.choice = qualityChoice
        playback.quality.plan = activeStreamPlan
        let sameSession = oldSessionID != nil && oldSessionID == playback.stream.playSessionID
        if !sameSession { await stopProviderReporter(at: resumeTime) }
        guard !Task.isCancelled, stops == stopCount else {
            await ProviderPlayback.discardUnplayedStream(playback.stream, provider: playback.provider)
            throw CancellationError()
        }
        metadata = ProviderPlaybackMetadata.make(detail: playback.detail, source: playback.stream.source, extras: playback.extras)
        setProviderStream(playback, preservingReporter: sameSession)
        currentTime = resumeTime
        return playback.stream.source.streamURL
    }

    /// The playing version's uncapped stream as a new play session, or nil when the
    /// server would only transcode it (nothing changes then).
    private func resolveProviderOriginal(at time: TimeInterval) async throws -> PlaybackPlan? {
        guard case .provider(var playback) = source else { return nil }
        let stops = stopCount
        let oldSessionID = playback.stream.playSessionID
        let replacement = try await playback.provider.replaceStream(
            for: playback.item.ref, current: playback.stream, sourceID: providerTargetSourceID,
            position: time, maxBitrate: nil, audioStreamIndex: nil,
            subtitleStreamIndex: nil, forceTranscode: false)
        let stream: StreamInfo
        if let replacement {
            stream = replacement
        } else {
            stream = try await playback.provider.resolveStream(
                for: playback.item.ref, sourceID: providerTargetSourceID ?? playback.stream.source.id)
        }
        guard !Task.isCancelled, stops == stopCount else {
            await ProviderPlayback.discardUnplayedStream(stream, provider: playback.provider)
            throw CancellationError()
        }
        guard (replacement != nil || stream.source.streamKind != .hlsTranscode),
              let plan = Self.providerPlan(for: stream) else {
            if stream.playSessionID != oldSessionID {
                await ProviderPlayback.discardUnplayedStream(stream, provider: playback.provider)
            }
            return nil
        }
        providerTargetSourceID = nil
        playback.stream = stream
        playback.quality.choice = qualityChoice
        playback.quality.plan = .original
        let sameSession = oldSessionID != nil && oldSessionID == stream.playSessionID
        if !sameSession { await stopProviderReporter(at: time) }
        guard !Task.isCancelled, stops == stopCount else {
            await ProviderPlayback.discardUnplayedStream(stream, provider: playback.provider)
            throw CancellationError()
        }
        metadata = ProviderPlaybackMetadata.make(detail: playback.detail, source: stream.source, extras: playback.extras)
        setProviderStream(playback, preservingReporter: sameSession)
        currentTime = time
        return plan
    }

    // MARK: - Streaming Quality

    private func handleSiloSessionEvent(_ event: SiloPlaybackSessionEvent, provider: SiloProvider,
                                        stream: StreamInfo, item: MediaItemRef) {
        switch event {
        case .ended(let problem):
            stopPlayback()
            errorMessage = problem.localizedDescription
            updatePlaybackState(.failed(.loadFailed(problem.localizedDescription)))
        case .renewalRequired(let problem):
            enqueueStreamWork { vm in
                guard case .provider(var playback) = vm.source,
                      playback.item.ref == item,
                      playback.stream.playSessionID == stream.playSessionID else { return }
                let position = vm.playheadForReload
                let resume = vm.playbackState != .paused
                do {
                    let replacement = try await provider.renewPlaybackSession(for: item,
                        current: stream, position: position, after: problem)
                    guard !Task.isCancelled, case .provider(let current) = vm.source,
                          current.item.ref == item,
                          current.stream.playSessionID == stream.playSessionID else {
                        await ProviderPlayback.discardUnplayedStream(replacement, provider: provider)
                        return
                    }
                    playback.stream = replacement
                    vm.metadata = ProviderPlaybackMetadata.make(detail: playback.detail,
                        source: replacement.source, extras: playback.extras)
                    vm.setProviderStream(playback)
                    vm.prepareProviderStream(playback)
                    guard let plan = vm.playbackPlan else { throw MediaProviderError.notPlayable }
                    vm.releaseAetherPlayer()
                    vm.releaseAVPlayer()
                    try await vm.startWithFallback(plan: plan, startTime: position)
                    vm.updateTrackLists()
                    if resume { vm.activePlayer_play() }
                    else { vm.activePlayer_pause(); vm.updatePlaybackState(.paused) }
                } catch {
                    guard !isCancellationError(error) else { return }
                    vm.errorMessage = PlayerError.loadFailed(error.localizedDescription).userFacingDescription
                    vm.updatePlaybackState(.failed(.loadFailed(error.localizedDescription)))
                }
            }
        }
    }

    /// The in-player Quality menu. Holds for the rest of this player session, Up Next included.
    func selectSiloQuality(_ quality: MediaQualityPreference) {
        guard case .provider(let playback) = source, let provider = playback.provider as? SiloProvider,
              let status = playback.stream.negotiatedStatus else { return }
        if case .offered(let id) = quality,
           !status.availableQualities.contains(where: { $0.id == id }) { return }
        siloStallTask?.cancel()
        enqueueStreamWork { vm in
            guard case .provider(var active) = vm.source, active.item.ref == playback.item.ref,
                  active.stream.playSessionID == playback.stream.playSessionID else { return }
            let position = vm.playheadForReload
            let resume = vm.playbackState != .paused
            do {
                let replacement = try await provider.replaceStream(for: active.item.ref, current: active.stream,
                    sourceID: nil, position: position, quality: quality)
                guard !Task.isCancelled, case .provider(let current) = vm.source,
                      current.stream.playSessionID == active.stream.playSessionID else {
                    await ProviderPlayback.discardUnplayedStream(replacement, provider: provider)
                    return
                }
                active.stream = replacement
                active.nativeRequestedQuality = quality
                vm.siloManualQuality = quality
                vm.siloRequestedQuality = quality
                vm.siloBuffering.manualQualityChanged(to: quality)
                let sameSession = replacement.playSessionID == current.stream.playSessionID
                if !sameSession { await vm.stopProviderReporter(at: position) }
                guard !Task.isCancelled else {
                    await ProviderPlayback.discardUnplayedStream(replacement, provider: provider)
                    return
                }
                vm.metadata = ProviderPlaybackMetadata.make(detail: active.detail, source: replacement.source,
                    extras: active.extras)
                vm.setProviderStream(active, preservingReporter: sameSession)
                vm.prepareProviderStream(active)
                guard let plan = vm.playbackPlan else { throw MediaProviderError.notPlayable }
                vm.releaseAetherPlayer()
                vm.releaseAVPlayer()
                try await vm.startWithFallback(plan: plan, startTime: position)
                vm.updateTrackLists()
                if resume { vm.activePlayer_play() }
                else { vm.activePlayer_pause(); vm.updatePlaybackState(.paused) }
            } catch {
                guard !isCancellationError(error) else { return }
                vm.errorMessage = PlayerError.loadFailed(error.localizedDescription).userFacingDescription
            }
        }
    }

    func restoreSiloQuality() {
        guard canRestoreSiloQuality, case .provider(let playback) = source,
              let provider = playback.provider as? SiloProvider else { return }
        enqueueStreamWork { vm in
            guard case .provider(var active) = vm.source,
                  active.stream.playSessionID == playback.stream.playSessionID else { return }
            let position = vm.playheadForReload
            let resume = vm.playbackState != .paused
            do {
                let replacement = try await provider.restoreQuality(for: active.item.ref,
                    current: active.stream, position: position, quality: vm.siloRequestedQuality)
                guard !Task.isCancelled, case .provider(let current) = vm.source,
                      current.stream.playSessionID == active.stream.playSessionID else {
                    await ProviderPlayback.discardUnplayedStream(replacement, provider: provider)
                    return
                }
                active.stream = replacement
                let sameSession = replacement.playSessionID == current.stream.playSessionID
                if !sameSession { await vm.stopProviderReporter(at: position) }
                guard !Task.isCancelled else {
                    await ProviderPlayback.discardUnplayedStream(replacement, provider: provider)
                    return
                }
                vm.metadata = ProviderPlaybackMetadata.make(detail: active.detail, source: replacement.source,
                    extras: active.extras)
                vm.setProviderStream(active, preservingReporter: sameSession)
                vm.siloBuffering.didRequestRestore()
                vm.prepareProviderStream(active)
                guard let plan = vm.playbackPlan else { throw MediaProviderError.notPlayable }
                vm.releaseAetherPlayer()
                vm.releaseAVPlayer()
                try await vm.startWithFallback(plan: plan, startTime: position)
                vm.updateTrackLists()
                if resume { vm.activePlayer_play() }
                else { vm.activePlayer_pause(); vm.updatePlaybackState(.paused) }
            } catch {
                guard !isCancellationError(error) else { return }
                vm.errorMessage = PlayerError.loadFailed(error.localizedDescription).userFacingDescription
            }
        }
    }

    func selectQuality(_ quality: StreamingQuality) {
        guard !(source.isSilo) else { return }
        sessionQuality = quality
        enqueueStreamWork { vm in
            let before = vm.planSnapshot
            let tracks = vm.currentPlexTrackIDs()
            let picks = vm.currentTrackPicks
            await vm.decideStreamPlan()
            let sameVersion = vm.versionID == before.version
            guard vm.activeStreamPlan != before.plan || !sameVersion else { return }
            // Another version's stream ids mean nothing on this one, so the picks carry over by language.
            await vm.reloadStream(toOriginal: vm.activeStreamPlan == .original, reason: "quality_menu",
                                  tracks: sameVersion ? tracks : vm.plexTrackIDs(carrying: picks), restoring: before)
        }
    }

    /// Picks this item's version and plan. Probes only when Auto has no fresh measurement.
    private func decideStreamPlan() async {
        if case .provider(let playback) = source {
            await decideProviderPlan(probing: playback.quality.probeURL)
            return
        }
        let isRelay = PlexRelay.isRelayURL(serverURL)
        isHomeLocation = StreamingQuality.isHome(serverURL: serverURL)
        let setting = sessionQuality ?? StreamingQuality.setting(home: isHomeLocation)
        qualityChoice = setting
        stallTracker = StallTracker()
        let measured = QualityDecision.needsProbe(setting: setting, isRelay: isRelay) ? await throughputKbps() : nil
        let cap = QualityDecision.capKbps(setting: setting, measuredKbps: measured, isRelay: isRelay)
        applyVersion(baseVersionChoice, to: serverOrderedMedia, capKbps: cap)
        activeStreamPlan = QualityDecision.decide(setting: setting, sourceKbps: metadata.Media?.first?.sourceKbps,
                                                  measuredKbps: measured, isRelay: isRelay)
        if isStacked { activeStreamPlan = .original }
        diagnostics.step("quality_decided", detail: "setting=\(setting.rawValue) plan=\(activeStreamPlan.step?.kbps ?? 0)")
    }

    /// `.provider`: a new plan, re-picking the version under the cap the way `applyVersion` does for Plex.
    private func decideProviderPlan(probing url: URL?) async {
        guard case .provider(let playback) = source else { return }
        let setting = sessionQuality ?? StreamingQuality.setting(home: isHomeLocation)
        qualityChoice = setting
        stallTracker = StallTracker()
        var measured: Int?
        if QualityDecision.needsProbe(setting: setting, isRelay: false) {
            let throughput = await ProviderPlayback.measure(url, reusing: lastThroughput)
            if let throughput { lastThroughput = throughput }
            measured = throughput?.kbps
        }
        let cap = QualityDecision.capKbps(setting: setting, measuredKbps: measured, isRelay: false)
        let playing = playback.stream.source
        var target = VersionRanking.choose(baseVersionChoice, from: playback.detail.mediaSources, capKbps: cap) ?? playing
        if target.id == playing.id { target = playing }
        if target.id != versionID {
            metadata = ProviderPlaybackMetadata.make(detail: playback.detail, source: target, extras: playback.extras)
        }
        if case .source(let id) = baseVersionChoice {
            providerTargetSourceID = id
        } else {
            providerTargetSourceID = target.id == playing.id ? nil : target.id
        }
        // The detail's entry is the file itself, never a transcode's numbers.
        let file = playback.detail.mediaSources.first { $0.id == target.id } ?? target
        activeStreamPlan = QualityDecision.decide(setting: setting, sourceKbps: file.sourceKbps,
                                                  measuredKbps: measured, isRelay: false)
        diagnostics.step("quality_decided", detail: "setting=\(setting.rawValue) plan=\(activeStreamPlan.step?.kbps ?? 0)")
    }

    private var serverOrderedMedia: [PlexMedia] {
        Self.serverOrder(metadata.Media ?? [], playingIndex: playingMediaServerIndex)
    }

    /// Undoes `VersionRanking.select`, which moved the playing version first from `playingIndex`.
    nonisolated static func serverOrder(_ media: [PlexMedia], playingIndex: Int) -> [PlexMedia] {
        var media = media
        guard media.indices.contains(playingIndex) else { return media }
        media.insert(media.removeFirst(), at: playingIndex)
        return media
    }

    /// Link speed from a ranged read of the best version's file; nil when the probe fails.
    private func throughputKbps() async -> Int? {
        if let last = lastThroughput, Date().timeIntervalSince(last.at) < 600 { return last.kbps }
        var probe = metadata
        probe.Media = VersionRanking.select(baseVersionChoice, in: serverOrderedMedia).media
        guard let server = URL(string: serverURL),
              let direct = ContentRouter.buildDirectPlayURL(context: ContentRoutingContext(
                metadata: probe, serverURL: server, authToken: authToken)) else { return nil }
        let kbps = await ThroughputProbe.measure(url: direct.url, headers: rivuletDirectPlayHeaders())
        if let kbps { lastThroughput = (kbps, Date()) }
        diagnostics.step("throughput_probe", detail: kbps.map { "\($0) kbps" } ?? "failed")
        return kbps
    }

    /// Up Next may reuse a prewarmed direct URL only when nothing could turn the next item into a transcode.
    private var nextEpisodePlaysOriginal: Bool {
        guard !PlexRelay.isRelayURL(serverURL) else { return false }
        return (sessionQuality ?? StreamingQuality.setting(home: StreamingQuality.isHome(serverURL: serverURL))) == .original
    }

    /// Auto's step-down: two stalls within a minute, or one lasting 10 s. Seeks and loads never count.
    private func trackQualityStall(from previous: UniversalPlaybackState, to next: UniversalPlaybackState) {
        if source.isSilo { return }
        guard next == .buffering else {
            if previous == .buffering {
                longStallTask?.cancel()
                longStallTask = nil
            }
            return
        }
        guard previous != .buffering, qualityChoice == .auto, !isReloadingStream, !isSwappingItem else { return }
        switch stallTracker.bufferingStarted(at: Date()) {
        case .ignored:
            break
        case .stepDown:
            stepDownQuality(reason: "repeated_stalls")
        case .counted:
            longStallTask?.cancel()
            longStallTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(StallTracker.longStall))
                guard let self, !Task.isCancelled, self.playbackState == .buffering else { return }
                self.stepDownQuality(reason: "long_stall")
            }
        }
    }

    private func updateSiloBuffering(from previous: UniversalPlaybackState, to next: UniversalPlaybackState) {
        guard case .provider(let playback) = source,
              let provider = playback.provider as? SiloProvider,
              let status = playback.stream.negotiatedStatus,
              provider.supportsBufferingQuality(for: playback.stream) else { return }
        let now = Int(ProcessInfo.processInfo.systemUptime * 1_000)
        if next == .playing, previous != .playing { siloBuffering.playing(atMs: now) }
        if next == .buffering, previous == .playing, !isReloadingStream, !isSwappingItem {
            siloBuffering.stallBegan(atMs: now)
            siloStallTask?.cancel()
            guard let deadline = siloBuffering.continuousStallDeadlineMs else { return }
            let generation = itemGeneration
            let stops = stopCount
            siloStallTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(max(0, deadline - now)))
                guard let self, !Task.isCancelled, self.playbackState == .buffering,
                      self.itemGeneration == generation, self.stopCount == stops,
                      case .provider(let current) = self.source,
                      current.item.ref == playback.item.ref,
                      current.stream.source.id == playback.stream.source.id,
                      current.stream.playSessionID == playback.stream.playSessionID else { return }
                let decision = self.siloBuffering.stallContinues(
                    atMs: Int(ProcessInfo.processInfo.systemUptime * 1_000), status: status,
                    deliveredKbps: status.effectiveRecipe?.bitrateKbps)
                self.handleSiloBufferingDecision(decision, sessionID: playback.stream.playSessionID)
            }
        } else if previous == .buffering, next != .buffering {
            siloStallTask?.cancel()
            siloStallTask = nil
            let decision = siloBuffering.stallEnded(atMs: now, status: status,
                deliveredKbps: status.effectiveRecipe?.bitrateKbps)
            handleSiloBufferingDecision(decision, sessionID: playback.stream.playSessionID)
        }
    }

    private func handleSiloBufferingDecision(_ decision: SiloBufferingQuality.Decision, sessionID: String?) {
        switch decision {
        case .none: break
        case .lower(let request): applySiloBufferingReduction(request, sessionID: sessionID)
        case .ask:
            guard onSiloBufferingOffer != nil else { siloBuffering.cancelOffer(); return }
            let generation = itemGeneration
            onSiloBufferingOffer? { [weak self] accepted in
                guard let self, case .provider(let playback) = self.source,
                      playback.stream.playSessionID == sessionID,
                      self.itemGeneration == generation else { return }
                if case .lower(let request) = self.siloBuffering.answer(accept: accepted) {
                    self.applySiloBufferingReduction(request, sessionID: sessionID)
                }
            }
        }
    }

    private func applySiloBufferingReduction(_ request: SiloBufferingQuality.Lowering, sessionID: String?) {
        enqueueStreamWork { vm in
            guard case .provider(var playback) = vm.source,
                  let provider = playback.provider as? SiloProvider,
                  playback.stream.playSessionID == sessionID else { return }
            let position = vm.playheadForReload
            do {
                let replacement: StreamInfo
                switch request.quality {
                case .automatic:
                    guard let estimate = request.bandwidthEstimateKbps else { return }
                    let observation = try SiloBufferingObservation(estimateKbps: estimate,
                        source: .observedRebuffer, observedThroughputKbps: request.observedThroughputKbps)
                    replacement = try await provider.replanBufferingQuality(for: playback.item.ref,
                        current: playback.stream, position: position, observation: observation)
                case .offered:
                    replacement = try await provider.replaceStream(for: playback.item.ref,
                        current: playback.stream, sourceID: nil, position: position, quality: request.quality)
                }
                guard !Task.isCancelled, case .provider(let current) = vm.source,
                      current.stream.playSessionID == sessionID else {
                    await ProviderPlayback.discardUnplayedStream(replacement, provider: provider)
                    return
                }
                playback.stream = replacement
                let sameSession = replacement.playSessionID == current.stream.playSessionID
                if !sameSession { await vm.stopProviderReporter(at: position) }
                guard !Task.isCancelled else {
                    await ProviderPlayback.discardUnplayedStream(replacement, provider: provider)
                    return
                }
                vm.metadata = ProviderPlaybackMetadata.make(detail: playback.detail, source: replacement.source,
                    extras: playback.extras)
                vm.setProviderStream(playback, preservingReporter: sameSession)
                vm.prepareProviderStream(playback)
                guard let plan = vm.playbackPlan else { throw MediaProviderError.notPlayable }
                vm.releaseAetherPlayer()
                vm.releaseAVPlayer()
                try await vm.startWithFallback(plan: plan, startTime: position)
                vm.updateTrackLists()
                vm.activePlayer_play()
            } catch {
                vm.siloBuffering.reductionFailed()
                if !isCancellationError(error) {
                    vm.errorMessage = PlayerError.loadFailed(error.localizedDescription).userFacingDescription
                }
            }
        }
    }

    /// One ladder step below what plays, reloaded at the playhead. Never steps up.
    private func stepDownQuality(reason: String) {
        guard !isStacked else { return }
        longStallTask?.cancel()
        longStallTask = nil
        stallTracker.noteStepDown()
        // The watchdog's seek-and-kick would race the reload.
        cancelAetherStallWatchdog()
        enqueueStreamWork { vm in
            guard let step = QualityDecision.stepDown(from: vm.activeStreamPlan,
                                                      sourceKbps: vm.metadata.Media?.first?.sourceKbps) else { return }
            let before = vm.planSnapshot
            vm.activeStreamPlan = .transcode(step)
            let crumb = Breadcrumb(level: .info, category: "playback.quality")
            crumb.message = "Auto stepped down (\(reason))"
            crumb.data = ["step_kbps": step.kbps]
            SentryBridge.addBreadcrumb(crumb)
            await vm.reloadStream(toOriginal: false, reason: "quality_step_down", tracks: vm.currentPlexTrackIDs(),
                                  restoring: before)
        }
    }

    /// A transcode carries the server's selected audio and subtitle, so a new pick restarts it at the playhead.
    private func reloadTranscodeForTrackChange() {
        if !providerTracksRequireReplan {
            guard case .hls = activeRoute, player != nil else { return }
        }
        // A plan arriving from an earlier pick reseeds current*TrackId.
        // Keep the user's newer queued pick instead of rereading that plan.
        let tracks = currentPlexTrackIDs()
        if case .provider(let playback) = source {
            pendingTrackReload = (tracks, playback.item.ref, playback.stream.source.id)
        } else {
            pendingTrackReload = (tracks, nil, nil)
        }
        guard !trackReloadQueued else { return }
        trackReloadQueued = true
        enqueueStreamWork { vm in
            vm.trackReloadQueued = false
            guard let reload = vm.pendingTrackReload else { return }
            vm.pendingTrackReload = nil
            if let item = reload.item {
                guard case .provider(let playback) = vm.source,
                      playback.item.ref == item, playback.stream.source.id == reload.fileID else { return }
            }
            if !vm.providerTracksRequireReplan {
                guard vm.aetherPlayer == nil, case .hls = vm.activeRoute else { return }
            }
            await vm.reloadStream(toOriginal: false, reason: "track_change", tracks: reload.tracks,
                                  restoring: vm.planSnapshot)
        }
    }

    /// Cancelling the newest task cancels the whole chain. Work queued for an item that was swapped out never runs.
    @discardableResult
    private func enqueueStreamWork(_ work: @escaping @MainActor (UniversalPlayerViewModel) async -> Void) -> Task<Void, Never> {
        let previous = streamWorkTask
        let stops = stopCount
        let generation = itemGeneration
        let task = Task { @MainActor [weak self] in
            await withTaskCancellationHandler {
                await previous?.value
            } onCancel: {
                previous?.cancel()
            }
            guard let self, stops == self.stopCount, generation == self.itemGeneration,
                  !Task.isCancelled else { return }
            self.isReloadingStream = true
            defer { self.isReloadingStream = false }
            await work(self)
        }
        streamWorkTask = task
        return task
    }

    /// Reloads at the playhead on the file or on a transcode at `activeStreamPlan`'s step,
    /// keeping the paused state and the audio and subtitle picks.
    /// A provider that will not transcode leaves the old stream playing and the plan as `snapshot` had it.
    private func reloadStream(toOriginal: Bool, reason: String, tracks: PlexTrackIDs,
                              restoring snapshot: PlanSnapshot) async {
        let resumeTime = playheadForReload
        let resume = playbackState != .paused
        if providerTracksRequireReplan { pendingProviderPlaybackIntent = resume }
        defer { pendingProviderPlaybackIntent = nil }
        diagnostics.step("quality_reload", detail: "reason=\(reason) step=\(activeStreamPlan.step?.kbps ?? 0)")
        do {
            if toOriginal {
                try await reloadOriginal(at: resumeTime, tracks: tracks)
            } else {
                try await reloadTranscode(at: resumeTime, tracks: tracks)
            }
            guard !Task.isCancelled else { return }
            if pendingProviderPlaybackIntent ?? resume {
                activePlayer_play()
            } else {
                activePlayer_pause()
                updatePlaybackState(.paused)
            }
        } catch MediaProviderError.transcodeRequired {
            activeStreamPlan = snapshot.plan
            metadata = snapshot.metadata
            providerTargetSourceID = snapshot.providerTargetSourceID
            diagnostics.step("quality_reload_unsupported", detail: "reason=\(reason)")
        } catch {
            if isCancellationError(error) || Task.isCancelled { return }
            errorMessage = (error as? PlayerError)?.userFacingDescription
                ?? PlayerError.loadFailed(error.localizedDescription).userFacingDescription
            updatePlaybackState(.failed(.loadFailed(error.localizedDescription)))
            diagnostics.capture(error, event: "quality_reload_failed", extraTags: [
                "quality_reload_reason": reason,
                "player_type": toOriginal ? "aether" : "avplayer"
            ])
        }
    }

    /// The AVPlayer item's own clock; the periodic observer behind `currentTime` lags a fresh seek.
    private var playheadForReload: TimeInterval {
        if aetherPlayer == nil, let seconds = player?.currentTime().seconds, seconds.isFinite, seconds > 0 {
            return sourcePosition(forPlayerTime: seconds)
        }
        return currentTime
    }

    private func reloadTranscode(at time: TimeInterval, tracks: PlexTrackIDs) async throws {
        let hls: (url: URL, headers: [String: String], sessionId: String?)
        if case .provider(let previous) = source {
            guard let url = try await switchToProviderTranscode(
                resumeTime: time, maxBitrate: activeStreamPlan.step.map { $0.kbps * 1000 },
                tracks: tracks, forceTranscode: false) else {
                throw PlayerError.loadFailed("Unable to start the provider transcode")
            }
            transcodeTrackIDs = tracks
            guard case .provider(let playback) = source else { throw MediaProviderError.notPlayable }
            if playback.stream.prefersAetherPlayback {
                _ = try await applyProviderPlaybackReplacement(previous: previous.stream, at: time)
                return
            }
            hls = (url, playback.stream.httpHeaders, nil)
        } else {
            transcodeTrackIDs = tracks
            await putTrackSelection(tracks)
            guard let built = buildRivuletHLSURL(offset: time) else {
                throw PlayerError.loadFailed("Unable to build HLS URL")
            }
            hls = built
        }
        try Task.checkCancellation()
        beginHLSSwitch(to: hls)
        guard await waitForHLSTranscodeReady(url: hls.url, headers: hls.headers) else {
            throw PlayerError.loadFailed("HLS transcode session failed to start")
        }
        try Task.checkCancellation()
        try await finishHLSSwitch(to: hls, resumeTime: time)
        playbackPlan = PlaybackPlan(policy: .directPlayFirst, primary: .hls(url: hls.url, headers: hls.headers),
                                    fallbacks: [], reasoning: ["quality_reload"])
        // Reseeds in Plex stream ids from `transcodeTrackIDs`.
        audioTracks = []
        subtitleTracks = []
        updateTrackLists()
    }

    /// Adopt a negotiated plan without treating its rotating plan ID (or relay
    /// URL) as a new video. The provider must explicitly prove continuity;
    /// unsupported caption deliveries and actual transport changes still load.
    /// False means caption preparation failed and the prior local pick was restored.
    private func applyProviderPlaybackReplacement(previous: StreamInfo, at time: TimeInterval) async throws -> Bool {
        guard case .provider(let playback) = source else { throw MediaProviderError.notPlayable }
        try Task.checkCancellation()
        prepareProviderStream(playback)
        guard let plan = playbackPlan else { throw MediaProviderError.notPlayable }
        let generation = itemGeneration
        let stops = stopCount
        let subtitleID = currentSubtitleTrackId
        let transition = ProviderStreamTransition.between(previous, playback.stream)
        if transition == .cuesOnly, let ap = aetherPlayer {
            let ownsReplacement = { [weak self, weak ap] in
                guard let self, let ap, self.aetherPlayer === ap,
                      self.itemGeneration == generation, self.stopCount == stops,
                      self.currentSubtitleTrackId == subtitleID,
                      case .provider(let current) = self.source else { return false }
                return current.item.ref == playback.item.ref &&
                    current.stream.playSessionID == playback.stream.playSessionID &&
                    current.stream.source.id == playback.stream.source.id
            }
            do {
                if try await ap.replaceProviderSubtitle(
                    playback.stream.source.subtitleTracks.first(where: \.isSelected),
                    timelineOffset: playback.stream.timelineOffset, isCurrent: ownsReplacement) {
                    hasAppliedNativeEngineSubtitleSelection = true
                    updateTrackLists()
                    return true
                }
            } catch {
                guard ownsReplacement(), !isCancellationError(error), !Task.isCancelled else { throw CancellationError() }
                // The caption commit failed; the identical video and old cues
                // are still valid. Roll back the local pick, not the movie.
                var restored = playback
                restored.stream = previous
                metadata = ProviderPlaybackMetadata.make(
                    detail: restored.detail, source: previous.source, extras: restored.extras)
                setProviderStream(restored, startPosition: time, preservingReporter: true)
                prepareProviderStream(restored)
                currentSubtitleTrackId = metadata.Media?.first?.Part?.first?.Stream?
                    .first(where: { $0.isSubtitle && $0.selected == true })?.id
                hasAppliedSubtitlePreference = true
                hasAppliedNativeEngineSubtitleSelection = true
                updateTrackLists()
                subtitleOperation = .failed(error.localizedDescription)
                showCompatibilityNotice("Couldn't Load Subtitles")
                return false
            }
        }
        let retainedPlayer = transition != .reload ? aetherPlayer : nil
        if let retainedPlayer {
            // The engine derives the new mode; only its non-final teardown
            // retains display ownership during this proven-video replacement.
            retainedPlayer.prepareForItemReplacement()
        } else {
            releaseAetherPlayer()
        }
        releaseAVPlayer()
        do {
            try await startWithFallback(plan: plan, startTime: time)
            try Task.checkCancellation()
            updateTrackLists()
            return true
        } catch {
            if generation == itemGeneration, stops == stopCount,
               retainedPlayer == nil || aetherPlayer === retainedPlayer {
                releaseAetherPlayer()
            }
            throw error
        }
    }

    /// Back to the untouched file at `time`, through the same start a fresh play uses.
    private func reloadOriginal(at time: TimeInterval, tracks: PlexTrackIDs) async throws {
        let plan: PlaybackPlan?
        if case .provider = source {
            plan = try await resolveProviderOriginal(at: time)
        } else {
            plan = ContentRouter.plan(for: ContentRoutingContext(
                metadata: metadata, serverURL: URL(string: serverURL)!, authToken: authToken,
                playbackPolicy: .directPlayFirst))
        }
        try Task.checkCancellation()
        guard let plan, case .aether(let url, let headers) = plan.primary else {
            // A provider that won't direct play this file serves its uncapped transcode instead.
            if case .provider = source { return try await reloadTranscode(at: time, tracks: tracks) }
            throw PlayerError.loadFailed("No direct-play URL")
        }
        stopOutgoingTranscode()
        releaseAVPlayer()
        playbackPlan = plan
        activeRoute = plan.primary
        AppHangContext.setPlaybackRoute(plan.primary.description)
        streamURL = url
        streamHeaders = headers ?? rivuletDirectPlayHeaders()
        rivuletFallbackURL = nil
        rivuletFallbackHeaders = [:]
        hasAttemptedRivuletHLSFallback = false
        // Engine ids differ from Plex ids, so the picks re-apply once the engine lists its tracks.
        initialAudioTrackId = tracks.audio
        initialSubtitleSelection = tracks.subtitle.map { $0 == 0 ? .off : .track(id: $0) } ?? .auto
        hasAppliedAudioPreference = false
        hasAppliedSubtitlePreference = false
        subtitlesPickedOff = false
        audioTracks = []
        subtitleTracks = []
        aetherPlayer?.prepareForItemReplacement()
        try await startWithFallback(plan: plan, startTime: time)
    }

    /// Audio and subtitle picks as Plex stream ids, which survive a route change.
    /// `subtitle` 0 is off; nil leaves the server's choice alone.
    nonisolated struct PlexTrackIDs: Sendable {
        var audio: Int?
        var subtitle: Int?
    }

    private func providerAudioIndex(for shimID: Int?, source: MediaSource) -> Int? {
        guard let shimID, let ordinal = plexAudioTracksFromMetadata().firstIndex(where: { $0.id == shimID }),
              source.audioTracks.indices.contains(ordinal) else { return nil }
        return source.audioTracks[ordinal].index
    }

    private func providerSubtitleIndex(for shimID: Int?, source: MediaSource) -> Int? {
        guard let shimID else { return nil }
        if shimID == 0 { return -1 }
        guard let ordinal = plexSubtitleTracksFromMetadata().firstIndex(where: { $0.id == shimID }),
              source.subtitleTracks.indices.contains(ordinal) else { return nil }
        return source.subtitleTracks[ordinal].index
    }

    private func nativeSubtitleEngineID(for shimID: Int?) -> Int? {
        guard let shimID, case .provider(let playback) = source,
              let ordinal = plexSubtitleTracksFromMetadata().firstIndex(where: { $0.id == shimID }),
              let player = aetherPlayer else { return nil }
        return NativeSubtitleSelection.engineID(ordinal: ordinal, tracks: playback.stream.source.subtitleTracks,
                                               engine: player.subtitleTracks)
    }

    private func applyNativeEngineTrackSelection() {
        guard case .provider(let playback) = source, let player = aetherPlayer else { return }
        // A probe can publish tracks while load is still choosing/starting its
        // initial audio. Selecting then can race that load or be overwritten.
        // Resolve only after load returns; a later inventory publication can
        // still supply a track that was missing at that boundary.
        if playback.stream.source.streamKind == .directPlay,
           let id = nativeEngineAudioSelection.resolve(
               ordinal: playback.stream.source.audioTracks.firstIndex(where: \.isSelected),
               engine: player.audioTracks, loadReturned: aetherLoadReturned
           ) {
            player.selectAudioTrack(id: id)
        }
        if aetherLoadReturned, !hasAppliedNativeEngineSubtitleSelection {
            let selected = currentSubtitleTrackId.flatMap { nativeSubtitleEngineID(for: $0) }
            let waitingForDelivery = currentSubtitleTrackId != nil && selected == nil &&
                playback.stream.source.subtitleTracks.contains {
                    $0.isSelected && ($0.nativeStreamIndex != nil || $0.externalURL != nil)
                }
            if !waitingForDelivery {
                player.selectSubtitleTrack(id: selected)
                hasAppliedNativeEngineSubtitleSelection = true
            }
        }
    }

    private func currentPlexTrackIDs() -> PlexTrackIDs {
        if providerTracksRequireReplan {
            return PlexTrackIDs(audio: currentAudioTrackId, subtitle: showsGeneratedSubtitles ? 0 : currentSubtitleTrackId ?? 0)
        }
        guard aetherPlayer != nil else {
            return PlexTrackIDs(audio: currentAudioTrackId, subtitle: currentSubtitleTrackId ?? 0)
        }
        let audio = currentAudioTrackId
            .flatMap { id in audioTracks.first { $0.id == id }?.streamIndex }
            .flatMap { index in plexAudioTracksFromMetadata().first { $0.streamIndex == index }?.id }
        guard let subtitleId = currentSubtitleTrackId, subtitleId != Self.generatedSubtitleId else {
            return PlexTrackIDs(audio: audio, subtitle: 0)
        }
        guard let track = subtitleTracks.first(where: { $0.id == subtitleId }) else {
            return PlexTrackIDs(audio: audio, subtitle: nil)
        }
        let plexSubs = plexSubtitleTracksFromMetadata()
        let subtitle: Int?
        if track.isExternal {
            // Sidecars pair by registration order, as in `subtitleTrackMatchingPlexStreamId`.
            let ordinal = subtitleTracks.filter(\.isExternal).firstIndex { $0.id == subtitleId } ?? -1
            subtitle = plexSubs.filter { $0.subtitleKey != nil }[safe: ordinal]?.id
        } else {
            subtitle = track.streamIndex.flatMap { index in plexSubs.first { $0.streamIndex == index }?.id }
        }
        return PlexTrackIDs(audio: audio, subtitle: subtitle)
    }

    /// What `applyAudioPreference` and `applySubtitlePreference` will pick on the Plex list, so a
    /// transcode starts on those tracks instead of restarting once they load. nil leaves the server's choice.
    private var startingTrackSelection: PlexTrackIDs {
        let streams = metadata.Media?.first?.Part?.first?.Stream ?? []
        let audio = plexAudioTracksFromMetadata()
        let subs = plexSubtitleTracksFromMetadata()
        var ids = PlexTrackIDs()
        if let id = initialAudioTrackId, audio.contains(where: { $0.id == id }) {
            ids.audio = id
        } else if let selectedAudio = plexChosenAudioStreamId,
                  audio.contains(where: { $0.id == selectedAudio }) {
            ids.audio = selectedAudio
        } else {
            ids.audio = TrackIntentResolver.resolveAudio(intent: TrackIntentStore.effectiveAudioIntent, in: audio)?.id
        }
        switch initialSubtitleSelection {
        case .off:
            ids.subtitle = 0
            return ids
        case .track(let id) where subs.contains(where: { $0.id == id }):
            ids.subtitle = id
            return ids
        default:
            break
        }
        let intent = TrackIntentStore.effectiveSubtitleIntent
        if let selected = streams.first(where: { $0.isSubtitle && $0.selected == true })?.id,
           let track = subs.first(where: { $0.id == selected }), !track.isDefault, !track.isForced,
           TrackIntentResolver.plexSelectedSubtitleMayOverride(track, intent: intent) {
            ids.subtitle = selected
        } else {
            let playing = audio.first { $0.id == ids.audio }
            ids.subtitle = TrackIntentResolver.resolveSubtitle(
                intent: intent, in: subs, audioLanguage: playing?.languageCode ?? playing?.language)?.id ?? 0
        }
        return ids
    }

    /// The playing audio and subtitle tracks; a nil subtitle is off.
    private var currentTrackPicks: (audio: MediaTrack?, subtitle: MediaTrack?) {
        (audioTracks.first { $0.id == currentAudioTrackId },
         currentSubtitleTrackId.flatMap { id in subtitleTracks.first { $0.id == id } })
    }

    /// `picks` matched by language and kind onto the version `metadata` now carries.
    private func plexTrackIDs(carrying picks: (audio: MediaTrack?, subtitle: MediaTrack?)) -> PlexTrackIDs {
        let audio = picks.audio.flatMap {
            TrackIntentResolver.resolveAudio(intent: AudioIntent(from: $0), in: plexAudioTracksFromMetadata())?.id
        }
        let subtitle = picks.subtitle.map {
            TrackIntentResolver.resolveSubtitle(intent: SubtitleIntent(from: $0), in: plexSubtitleTracksFromMetadata())?.id ?? 0
        } ?? 0
        return PlexTrackIDs(audio: audio, subtitle: subtitle)
    }

    /// What a quality reload restores when a provider will not serve the new plan.
    struct PlanSnapshot {
        let plan: StreamPlan
        let metadata: PlexMetadata
        let providerTargetSourceID: String?
        let version: String?
    }

    private var planSnapshot: PlanSnapshot {
        PlanSnapshot(plan: activeStreamPlan, metadata: metadata,
                     providerTargetSourceID: providerTargetSourceID, version: versionID)
    }

    /// The version the next reload plays: the provider's source id, else the Plex media id.
    private var versionID: String? {
        if case .provider(let playback) = source { return providerTargetSourceID ?? playback.stream.source.id }
        return playingMediaID
    }

    /// Plex reads the part's selected streams when a transcode session starts.
    private func putTrackSelection(_ tracks: PlexTrackIDs) async {
        guard case .plex = source, let partId = metadata.Media?.first?.Part?.first?.id else { return }
        let network = PlexNetworkManager.shared
        if let audio = tracks.audio {
            await network.setSelectedAudioStream(serverURL: serverURL, authToken: authToken,
                                                 partId: partId, audioStreamID: audio)
        }
        if let subtitle = tracks.subtitle {
            await network.setSelectedSubtitleStream(serverURL: serverURL, authToken: authToken,
                                                    partId: partId, subtitleStreamID: subtitle)
        }
    }

    // MARK: - RIVULET-19 Failure Probe

    /// After an aether startup failure, fetch the first bytes of the stream and record
    /// what the server returned (RIVULET-19: AVERROR_INVALIDDATA, the body is not media).
    /// Diagnostic only: runs from the aether failure catch, never awaited, swallows every
    /// error. Do not move it onto the success path. `url` is never logged.
    private func probeStreamBodyForDiagnostics(
        url: URL,
        headers: [String: String],
        error: Error,
        kind: DirectPlayFailureKind
    ) {
        // A deadline expiry is a hang, not a bad body (#245): nothing to probe.
        if error is AetherLoadTimeoutPolicy.TimedOut { return }

        Task { @MainActor [weak self] in
            guard let self else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            // Short: a probe that outlives the session is useless.
            request.timeoutInterval = 5
            request.setValue(StreamBodyClassifier.probeRangeHeader, forHTTPHeaderField: "Range")
            for (key, value) in headers {
                request.addValue(value, forHTTPHeaderField: key)
            }

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else {
                return
            }

            let classification = StreamBodyClassifier.classify(data)
            let summary = StreamBodyClassifier.describe(
                status: http.statusCode,
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                classification: classification,
                byteCount: data.count
            )

            self.diagnostics.recordFailureBodyProbe(
                summary: summary,
                classification: classification.rawValue,
                status: http.statusCode,
                error: error,
                kind: kind
            )
        }
    }

    // MARK: - HLS Trust Relay

    /// AVPlayer and the preflight use system trust, so an origin the Plex API
    /// session accepts on its own rule is reached through a loopback relay (#337).
    private func prepareHLSRelay(for url: URL) async {
        if hlsRelay?.localURL(for: url) != nil { return }
        hlsRelay = nil
        guard await HLSTrustRelay.systemTrustRefuses(url) else { return }
        hlsRelay = await HLSTrustRelay.start(for: url)
        diagnostics.step("hls_trust_relay", detail: hlsRelay == nil ? "failed to start" : "started")
    }

    private func avPlayerURL(_ url: URL) -> URL {
        hlsRelay?.localURL(for: url) ?? url
    }

    // MARK: - HLS Transcode Preflight

    /// Wait until the transcode's manifest and at least one segment are served.
    /// Returns false if the transcode failed to start.
    private func waitForHLSTranscodeReady(url: URL, headers: [String: String]) async -> Bool {
        await prepareHLSRelay(for: url)
        let url = avPlayerURL(url)
        await PlexNetworkManager.shared.startTranscodeDecision(hlsURL: url, headers: headers)
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

        DiagLog.error(.playback, "HLS transcode failed to start after 8 attempts")
        return false
    }

    /// The first variant playlist a master names, resolved against `baseURL`.
    /// Matched on the path: a provider's variant line carries a query
    /// ("main.m3u8?ApiKey=..."); PMS's has none, so it is unaffected.
    static func firstVariantURL(inMaster masterContent: String, baseURL: URL) -> URL? {
        for line in masterContent.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // An empty line would resolve to the master itself.
            if !trimmed.isEmpty, !trimmed.hasPrefix("#"),
               let url = URL(string: trimmed, relativeTo: baseURL),
               url.path.hasSuffix(".m3u8") {
                return url.absoluteURL
            }
        }
        return nil
    }

    /// Check if a variant playlist has actual segments ready
    private func checkVariantPlaylist(masterContent: String, baseURL: URL, headers: [String: String]) async -> Bool? {
        guard let variant = Self.firstVariantURL(inMaster: masterContent, baseURL: baseURL) else {
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
        stopCount += 1
        siloSessionEventTask?.cancel()
        siloSessionEventTask = nil
        siloStallTask?.cancel()
        siloStallTask = nil
        onSiloBufferingCancel?()
        siloBuffering.cancelOffer()
        resetSiloSubtitleActions()
        endDescriptionTranslation()
        let finalPosition = currentTime
        Task { await self.stopProviderReporter(at: finalPosition) }
        clearPreloadedData()
        pausedTimelineTask?.cancel()
        pausedTimelineTask = nil
        streamPreparationTask?.cancel()
        streamPreparationTask = nil
        streamWorkTask?.cancel()
        longStallTask?.cancel()
        longStallTask = nil
        cancelAetherStallWatchdog()
        titleLogoResolveTask?.cancel()
        titleLogoResolveTask = nil
        clearReplayWindow()
        contentFilter.reset()
        muteEdgeWork?.cancel()
        muteEdgeWork = nil
        subtitleImageReader.read([])
        releaseThumbnailCache()
        cancelEngineThumbnail()

        // Clear the active playback route and content from the App Hang scope
        // (RIVULET-41) so a later hang off the player isn't tagged with a stale
        // route or content shape.
        AppHangContext.setPlaybackRoute(nil)
        AppHangContext.clearContent()
        bufferingStartedAt = nil

        // Stop AetherPlayer if active
        aetherPlayer?.stop()
        aetherPlayer = nil
        aetherSubtitleModel.update(cues: [])
        assTrack = nil

        teardownAVPlayerObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        _playerForCleanup = nil
        hlsManifestEnricher = nil
        hlsRelay = nil

        // Stop the Plex transcode session so the server frees resources immediately.
        // Without this, switching between DV files can timeout waiting for the init segment
        // because the server is still busy with the previous transcode.
        // A provider's reporter stops its own encoding on `stopped`.
        stopOutgoingTranscode()

        controlsTimer?.invalidate()
        wheelScrubbingTimer?.invalidate()
        wheelScrubbingTimer = nil
        wheelScrubbing = false
        hideCompatibilityNotice()

        // Reset display criteria to default (allows TV to return to normal mode)
        DisplayCriteriaManager.shared.reset()

        // Re-enable screensaver
        UIApplication.shared.isIdleTimerDisabled = false
        SiloThemeMusicController.shared.resume()
    }

    func togglePlayPause() {
        hidePausedPoster()
        let intendsToPlay = pendingProviderPlaybackIntent ?? isPlaying
        if pendingProviderPlaybackIntent != nil { pendingProviderPlaybackIntent = !intendsToPlay }
        if intendsToPlay {
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
        if pendingProviderPlaybackIntent != nil { pendingProviderPlaybackIntent = true }
        activePlayer_play()
        showControlsTemporarily()
    }

    /// Pause playback (used by remote commands)
    func pause() {
        if pendingProviderPlaybackIntent != nil { pendingProviderPlaybackIntent = false }
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
            cancelAetherStallWatchdog()
            if playbackState == .buffering {
                updatePlaybackState(player.isPlaying ? .playing : .paused)
            }
        }
    }

    private func cancelAetherStallWatchdog() {
        aetherStallWatchdogTask?.cancel()
        aetherStallWatchdogTask = nil
    }

    private func startAetherStallWatchdog(for player: AetherPlayer) {
        cancelAetherStallWatchdog()

        // A paused session isn't stalled, it's parked, so there is nothing to
        // recover and a recovery kick would be a restart the user never asked
        // for (issue #247).
        guard StallWatchdogPolicy.shouldArm(
            userIntendsToPlay: player.intendsToPlay,
            playbackState: playbackState
        ) else { return }

        let baselineTime = currentTime
        aetherStallWatchdogTask = Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }

            try? await Task.sleep(nanoseconds: UInt64(self.aetherStallRecoveryDelay * 1_000_000_000))
            guard !Task.isCancelled,
                  self.aetherPlayer === player,
                  player.isBuffering else { return }

            // Re-checked here, not just at arm time: the delay is 20s, and the
            // user can pause or the screensaver can take the display in that
            // window. `play()` below may rebuild the whole Aether session (it
            // runs any pending foreground reload), so this is the guard that
            // keeps a dimmed, paused Apple TV from bursting back into playback.
            guard StallWatchdogPolicy.shouldKick(
                userIntendsToPlay: player.intendsToPlay,
                playbackState: self.playbackState,
                applicationState: UIApplication.shared.applicationState
            ) else { return }

            let recoveryTime = self.currentTime
            guard recoveryTime <= baselineTime + 0.5 else { return }

            let kickTarget = min(max(0, recoveryTime + 0.1), max(self.duration, recoveryTime))
            if case .provider(let playback) = self.source, !playback.stream.canSeekAnywhere {
                await self.seek(to: kickTarget, revealsControls: false)
                return
            }
            await player.seek(to: self.playerPosition(forSourceTime: kickTarget))
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

    /// Reanchor restricted deliveries in their native protocol before installing the new URL.
    /// Same-session replans retain the reporter's monotonic sequence and do not send stop.
    private func prepareProviderSeek(to position: TimeInterval) async throws -> Bool {
        guard case .provider(var playback) = source, !playback.stream.canSeekAnywhere else { return false }
        let stops = stopCount
        guard let stream = try await playback.provider.seekStream(
            for: playback.item.ref, sourceID: playback.stream.source.id,
            playSessionID: playback.stream.playSessionID, position: position
        ) else { throw MediaProviderError.notPlayable }
        guard !Task.isCancelled, stops == stopCount else {
            await ProviderPlayback.discardUnplayedStream(stream, provider: playback.provider)
            throw CancellationError()
        }
        let sameSession = stream.playSessionID != nil && stream.playSessionID == playback.stream.playSessionID
        if !sameSession { await stopProviderReporter(at: currentTime) }
        guard !Task.isCancelled, stops == stopCount else {
            await ProviderPlayback.discardUnplayedStream(stream, provider: playback.provider)
            throw CancellationError()
        }
        releaseAVPlayer()
        releaseAetherPlayer()
        playback.stream = stream
        if sameSession {
            source = .provider(playback)
        } else {
            setProviderStream(playback)
        }
        metadata = ProviderPlaybackMetadata.make(detail: playback.detail, source: stream.source, extras: playback.extras)
        prepareProviderStream(playback)
        currentTime = sourcePosition(forPlayerTime: stream.playerStartTime ?? 0)
        if !providerReporterStarted { providerInitialPosition = currentTime }
        return true
    }

    private func seekProviderIfNeeded(to position: TimeInterval) async -> Bool {
        guard case .provider(let playback) = source, !playback.stream.canSeekAnywhere else { return false }
        providerSeekRequestGeneration += 1
        let request = providerSeekRequestGeneration
        await enqueueStreamWork { model in
            guard model.providerSeekRequestGeneration == request else { return }
            let wasPlaying = model.isPlaying
            model.pendingProviderPlaybackIntent = wasPlaying
            defer { model.pendingProviderPlaybackIntent = nil }
            do {
                if try await model.prepareProviderSeek(to: position) {
                    guard let plan = model.playbackPlan else { throw MediaProviderError.notPlayable }
                    try await model.startWithFallback(plan: plan, startTime: nil)
                    if model.pendingProviderPlaybackIntent ?? wasPlaying {
                        model.aetherPlayer?.play()
                        model.player?.play()
                    } else {
                        model.aetherPlayer?.pause()
                        model.player?.pause()
                    }
                } else if let player = model.aetherPlayer {
                    await player.seek(to: model.playerPosition(forSourceTime: position))
                } else {
                    await model.player?.seek(to: CMTime(seconds: model.playerPosition(forSourceTime: position),
                                                       preferredTimescale: 600))
                }
            } catch {
                guard !isCancellationError(error), !Task.isCancelled else { return }
                model.errorMessage = PlayerError.loadFailed(error.localizedDescription).userFacingDescription
                model.updatePlaybackState(.failed(.loadFailed(error.localizedDescription)))
            }
        }.value
        return true
    }

    /// - Parameter revealsControls: whether the seek should surface the
    ///   transport chrome (the normal reveal-the-scrubber affordance). A marker
    ///   skip taken while the chrome is hidden passes `false` so the jump
    ///   doesn't pop the rail open.
    func seek(to time: TimeInterval, revealsControls: Bool = true) async {
        // An absolute seek (scrub commit, marker skip) supersedes any relative
        // one still in flight; the next skip starts from where this lands.
        seekGeneration += 1
        inFlightRelativeSeekTarget = nil
        stallTracker.noteSeekOrLoad(at: Date())
        if await seekProviderIfNeeded(to: time) {
            if revealsControls { showControlsTemporarily() }
            return
        }
        if let ap = aetherPlayer {
            await ap.seek(to: playerPosition(forSourceTime: time))
        } else {
            await player?.seek(to: CMTime(seconds: playerPosition(forSourceTime: time), preferredTimescale: 600))
        }
        stallTracker.noteSeekOrLoad(at: Date())
        if revealsControls { showControlsTemporarily() }
    }

    func seekRelative(by seconds: TimeInterval) async {
        hidePausedPoster()
        // The skip glyph shows on the press, not after the seek lands.
        let intSeconds = Int(abs(seconds))
        showSeekIndicator(seconds >= 0 ? .forward(intSeconds) : .backward(intSeconds))
        let base = inFlightRelativeSeekTarget ?? currentTime
        let targetTime = max(0, min(base + seconds, duration))
        // tvOS Show on Skip Back covers skips back of up to 30s in total.
        if seconds < 0, (replayWindow?.invokedAt ?? base) - targetTime <= 30,
           Self.systemShowsSubtitlesOnSkipBack() {
            openCaptionWindow(until: base)
        }
        inFlightRelativeSeekTarget = targetTime
        seekGeneration += 1
        let generation = seekGeneration
        stallTracker.noteSeekOrLoad(at: Date())
        if await seekProviderIfNeeded(to: targetTime) {
            if seekGeneration == generation { inFlightRelativeSeekTarget = nil }
            if showControls { showControlsTemporarily() }
            return
        }
        if let ap = aetherPlayer {
            await ap.seek(to: playerPosition(forSourceTime: targetTime))
        } else {
            await player?.seek(to: CMTime(seconds: playerPosition(forSourceTime: targetTime), preferredTimescale: 600))
        }
        stallTracker.noteSeekOrLoad(at: Date())
        // Only the newest seek clears it; an older one returning late must not
        // drop the base a newer one is still building on.
        if seekGeneration == generation { inFlightRelativeSeekTarget = nil }
        // Refresh the auto-hide timer when the chrome is up; a skip never summons it.
        if showControls { showControlsTemporarily() }
    }

    /// tvOS Settings > Video and Audio > Automatic Subtitles > Show on Skip Back (default on).
    /// No public API: AVKit reads it through this libAccessibility function. Off if absent.
    private static let systemShowsSubtitlesOnSkipBack: () -> Bool = {
        guard let lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_LAZY),
              let sym = dlsym(lib, "_AXSAutomaticSubtitlesShowOnSkipBack") else { return { false } }
        let read = unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
        return { read() != 0 }
    }()

    /// Turns subtitles on until playback passes `point` (#329: also opened by
    /// a skip back when the system's Show on Skip Back is on). Extends an open window.
    private func openCaptionWindow(until point: TimeInterval) {
        if let window = replayWindow {
            replayWindow = window.extended(to: point)
        } else {
            replayWindow = ReplayWindowLogic(invokedAt: point, priorSubtitleTrackId: currentSubtitleTrackId)
            if currentSubtitleTrackId == nil, let track = preferredReplaySubtitleTrack() {
                selectSubtitleTrackWithoutSaving(id: track.id, reloadsTranscode: false)
            }
        }
    }

    /// A full (non-forced) track in the spoken language, else any non-forced
    /// track, else the first (better to show something than nothing).
    private func preferredReplaySubtitleTrack() -> MediaTrack? {
        let full = subtitleTracks.filter { !$0.isForced }
        if let audio = audioTracks.first(where: { $0.id == currentAudioTrackId }) {
            let spoken = Set(languageCandidates(for: audio).map { $0.lowercased() })
            if let match = full.first(where: { track in
                languageCandidates(for: track).contains { spoken.contains($0.lowercased()) }
            }) { return match }
        }
        return full.first ?? subtitleTracks.first
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
            selectSubtitleTrackWithoutSaving(id: nil, reloadsTranscode: false)
            updateCaptionsOnMute()
        }
    }

    /// Shows subtitles while tvOS's Show When Muted applies and puts the prior
    /// choice back after, unless the user picked meanwhile.
    private func updateCaptionsOnMute() {
        guard aetherPlayer != nil else { return }
        if systemCaptionsOnMute.isActive {
            let audio = audioTracks.first { $0.id == currentAudioTrackId }
            if let id = captionsOnMute.activate(
                current: subtitleTracks.first { $0.id == currentSubtitleTrackId },
                tracks: subtitleTracks,
                preferredLanguage: CaptionsOnMuteLogic.language(of: TrackIntentStore.subtitleIntent),
                audioLanguage: audio?.languageCode ?? audio?.language
            ) {
                selectSubtitleTrackWithoutSaving(id: id, reloadsTranscode: false)
            }
        } else if let restore = captionsOnMute.deactivate(currentTrackId: currentSubtitleTrackId) {
            selectSubtitleTrackWithoutSaving(id: restore, reloadsTranscode: false)
        }
    }

    /// Clears any active replay window without reverting subtitles, wherever
    /// playback or subtitle state moves out from under it. Internal for
    /// `UniversalPlayerView`'s `.seekAbsolute` handler.
    func clearReplayWindow() {
        replayWindow = nil
    }

    /// Publishes the skip for the bar's glyph; with the controls hidden the bar shows alone (AVKit, 3.3s).
    private func showSeekIndicator(_ indicator: SeekIndicator) {
        seekIndicatorTimer?.invalidate()
        if !showControls { showsSkipBar = true }
        seekIndicator = indicator
        seekIndicatorTimer = Timer.scheduledTimer(withTimeInterval: 3.3, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.seekIndicator = nil
                self?.showsSkipBar = false
            }
        }
    }

    // MARK: - Scrubbing

    /// Start or advance scrub speed in given direction via ShuttleGrammar:
    /// click-and-hold enters at level 1, same-direction clicks bump up to the
    /// level 8 cap, opposite-direction clicks step down then cancel. The bar
    /// shows the level as AVKit's scan glyph; rates run 8x to 1536x.
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

    /// Clickpad-ring rotation scrub; `seekDelta` is already converted from the rotation.
    func handleWheelScrub(by seekDelta: TimeInterval) {
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
                // A finger resting on the ring keeps it up, as AVKit's does.
                if RemoteInputHandler.isRingJogging { self?.startWheelScrubbingIdleTimer(); return }
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
            cancelEngineThumbnail()
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
        cancelEngineThumbnail()
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

    static func scrubThumbnailSource(hasServerThumbnails: Bool) -> ScrubThumbnailSource {
        hasServerThumbnails ? .server : .engine
    }

    /// A Plex part keeps its BIF unless the server answered that it has none;
    /// then the engine takes over for the rest of the item. A provider item
    /// never asks PlexThumbnailService (its Part is a placeholder).
    var currentScrubThumbnailSource: ScrubThumbnailSource {
        guard case .plex = source, !isStacked, let partId = metadata.Media?.first?.Part?.first?.id else { return .engine }
        return Self.scrubThumbnailSource(
            hasServerThumbnails: !PlexThumbnailService.shared.isUnavailable(partId: partId))
    }

    private func loadThumbnail(for time: TimeInterval) {
        guard currentScrubThumbnailSource == .server else {
            loadEngineThumbnail(for: time)
            return
        }
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
            // The BIF index just 404'd: this scrub, and every later one, decodes.
            if thumbnail == nil, self.currentScrubThumbnailSource == .engine {
                self.loadEngineThumbnail(for: time)
                return
            }
            self.scrubThumbnail = thumbnail
        }
    }

    /// Latest wins: while a decode runs, only the newest scrub time is kept,
    /// and the frame that comes back shows even if the scrub has moved on,
    /// since it is the nearest still there is.
    private func loadEngineThumbnail(for time: TimeInterval) {
        pendingEngineThumbnailTime = time
        guard engineThumbnailTask == nil, let player = aetherPlayer else { return }
        engineThumbnailTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.isScrubbing,
                  let wanted = self.pendingEngineThumbnailTime {
                self.pendingEngineThumbnailTime = nil
                let frame = await player.scrubFrame(atSeconds: wanted)
                if !Task.isCancelled, self.isScrubbing, let frame {
                    self.scrubThumbnail = UIImage(cgImage: frame)
                }
            }
            // A cancelled loop was already replaced by cancelEngineThumbnail.
            if !Task.isCancelled { self?.engineThumbnailTask = nil }
        }
    }

    private func cancelEngineThumbnail() {
        engineThumbnailTask?.cancel()
        engineThumbnailTask = nil
        pendingEngineThumbnailTime = nil
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
        // The engine caches its own decodes; prefetching would only pull bytes
        // over the playback link.
        guard currentScrubThumbnailSource == .server else { return }
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
        preloadedThumbnailPartId = partId
        PlexThumbnailService.shared.preloadBIF(
            partId: partId,
            serverURL: serverURL,
            authToken: authToken
        )
    }

    /// Drop the outgoing item's BIF. Safe to call when nothing is cached; a
    /// later scrub re-fetches on demand.
    private func releaseThumbnailCache() {
        guard let partId = preloadedThumbnailPartId else { return }
        preloadedThumbnailPartId = nil
        PlexThumbnailService.shared.clearCache(partId: partId)
    }

    // MARK: - Track Selection

    func selectAudioTrack(id: Int) {
        // Delegate the actual pipeline switch to the auto-selection helper,
        // then persist the user's explicit choice as the saved preference so
        // future playback sessions restore it.
        selectAudioTrackWithoutSaving(id: id)

        // Picking what the intent already chooses (Original's main track) leaves it alone.
        if let track = audioTracks.first(where: { $0.id == id }),
           TrackIntentResolver.resolveAudio(intent: TrackIntentStore.effectiveAudioIntent, in: audioTracks)?.id != id {
            TrackIntentStore.audioIntent = AudioIntent(from: track)
        }
        // Foreign Audio follows the new language, unless subtitles were turned off for this title.
        if case .foreignAudio = TrackIntentStore.effectiveSubtitleIntent, !subtitlesPickedOff {
            applyGlobalSubtitleIntent()
        }
    }

    /// Select audio track without saving preference (for auto-selection)
    private func selectAudioTrackWithoutSaving(id: Int) {
        if providerTracksRequireReplan {
            let changed = id != currentAudioTrackId
            currentAudioTrackId = id
            if changed { reloadTranscodeForTrackChange() }
            return
        }
        if let ap = aetherPlayer {
            ap.selectAudioTrack(id: id)
            currentAudioTrackId = id
            return
        }
        let changed = id != currentAudioTrackId
        currentAudioTrackId = id
        if changed { reloadTranscodeForTrackChange() }
    }

    func selectSubtitleTrack(id: Int?) {
        // User picked a track manually: their choice wins over any active
        // replay window (no later revert-to-prior-track).
        clearReplayWindow()
        // Off holds for this title even where the saved mode would show subtitles.
        subtitlesPickedOff = id == nil
        if aetherPlayer != nil, systemCaptionsOnMute.isActive { captionsOnMute.userPicked() }

        // Delegate the actual pipeline switch to the auto-selection helper,
        // then persist the user's explicit choice as the saved preference so
        // future playback sessions restore it.
        selectSubtitleTrackWithoutSaving(id: id)

        // Generated subtitles save no preference; they carry on through this session's next items.
        guard id != Self.generatedSubtitleId else {
            generatedSubtitlesPickedOn = metadata.ratingKey
            return
        }
        TrackIntentStore.subtitleIntent = .afterPick(
            id.flatMap { id in subtitleTracks.first { $0.id == id } },
            replacing: TrackIntentStore.effectiveSubtitleIntent, audioLanguage: playingAudioLanguage)
    }

    // MARK: - Subtitle Search

    @Published private(set) var canSearchSubtitles = false
    @Published private(set) var subtitleSearchWarning: String?
    @Published private(set) var subtitleOperation: PlayerSubtitleOperation = .idle
    @Published private(set) var siloSubtitleJobs: [SiloSubtitleAIJob] = []
    @Published private(set) var siloSubtitleSyncStatus: SiloSubtitleSyncStatus?
    @Published private(set) var siloSubtitleSyncState: SiloSubtitleSyncState?
    @Published private(set) var siloSubtitleSyncError: String?
    @Published private(set) var siloSubtitleSyncUpdating = false
    private var siloSubtitleSyncTask: Task<Void, Never>?
    private var siloSubtitleSyncMutation: Task<Void, Never>?
    private var siloSubtitleSyncTarget: SiloSubtitleSyncTarget?
    private var siloSubtitleSyncEpoch = 0
    private var siloSubtitleAppliedTiming: SiloSubtitleTiming?
    private var siloSubtitleAIStatus: SiloSubtitleAIStatus?
    private var siloSubtitleTask: Task<Void, Never>?
    private static var serverAdminAnswers: [String: Bool] = [:]

    var siloSubtitleGenerationOptions: [SiloSubtitleGenerationOption] {
        guard case .provider(let playback) = source, playback.provider is SiloProvider else { return [] }
        return siloSubtitleAIStatus?.generationOptions(for: playback.stream.source, targetLanguage: subtitleSearchLanguage) ?? []
    }

    var isSiloPlayback: Bool {
        guard case .provider(let playback) = source else { return false }
        return playback.provider is SiloProvider
    }

    var subtitleSearchLanguageName: String {
        Locale.current.localizedString(forLanguageCode: subtitleSearchLanguage) ?? subtitleSearchLanguage
    }

    private var selectedSiloSubtitleTrack: SubtitleTrack? {
        guard isSiloPlayback, case .provider(let playback) = source, let id = currentSubtitleTrackId,
              let ordinal = plexSubtitleTracksFromMetadata().firstIndex(where: { $0.id == id }),
              playback.stream.source.subtitleTracks.indices.contains(ordinal) else { return nil }
        return playback.stream.source.subtitleTracks[ordinal]
    }

    var canStartSiloSubtitleSync: Bool {
        guard let state = siloSubtitleSyncState,
              siloSubtitleSyncStatus?.canSync(state) == true else { return false }
        return state.target == selectedSiloSubtitleTrack?.siloSyncTarget &&
            !siloSubtitleSyncUpdating && state.sync?.isActive != true
    }

    var canResetSiloSubtitleTiming: Bool {
        canStartSiloSubtitleSync && siloSubtitleSyncState?.timing.isIdentity == false
    }

    var siloSubtitleSyncDetail: String {
        if let error = siloSubtitleSyncError { return error }
        if siloSubtitleSyncUpdating { return "Updating on Silo…" }
        guard let state = siloSubtitleSyncState else {
            return selectedSiloSubtitleTrack?.siloSyncTarget == nil
                ? "Choose a downloaded subtitle or sidecar in Language." : "Checking timing on Silo…"
        }
        let result = state.sync?.statusText ?? "Ready to align with this file's audio"
        return state.timing.isIdentity ? result : "\(result) · \(state.timing.detail)"
    }

    func refreshSubtitleActions() async { await resolveSubtitleSearchAccess() }

    private func resolveSubtitleSearchAccess() async {
        let generation = itemGeneration
        canSearchSubtitles = false
        if case .provider(let playback) = source, let provider = playback.provider as? SiloProvider {
            let fileID = playback.stream.source.id
            async let providers = try? provider.subtitleProviderStatus()
            async let ai = try? provider.subtitleAIStatus()
            async let sync = try? provider.subtitleSyncStatus()
            let (providerStatus, aiStatus, syncStatus) = await (providers, ai, sync)
            guard isCurrentSiloFile(fileID, generation: generation), stopCount == 0 else { return }
            canSearchSubtitles = providerStatus?.canSearch == true
            siloSubtitleAIStatus = aiStatus
            siloSubtitleSyncStatus = syncStatus
            refreshSiloSubtitleSyncSelection(force: true)
            if aiStatus?.canTranslate == true || aiStatus?.canTranscribe == true {
                let jobs = try? await provider.subtitleJobs(fileID: fileID)
                guard isCurrentSiloFile(fileID, generation: generation) else { return }
                siloSubtitleJobs = jobs ?? []
            }
            return
        }
        guard case .plex = source, metadata.ratingKey != nil,
              PlexUserProfileManager.shared.selectedUser?.restricted != true else { return }
        let key = serverURL + authToken
        if let known = Self.serverAdminAnswers[key] {
            canSearchSubtitles = known
            return
        }
        let isAdmin = await PlexNetworkManager.shared.canAdministerServer(serverURL: serverURL, authToken: authToken)
        Self.serverAdminAnswers[key] = isAdmin
        guard generation == itemGeneration, stopCount == 0, case .plex = source else { return }
        canSearchSubtitles = isAdmin
    }

    /// The subtitle preference's language, else the device's, as ISO 639-1.
    private var subtitleSearchLanguage: String {
        let device = Locale.current.language.languageCode?.identifier(.alpha2) ?? "en"
        guard let preferred = TrackIntentStore.effectiveSubtitleIntent.language else { return device }
        let code = TrackLanguage.normalize(preferred)
        return code.isEmpty ? device : Locale.LanguageCode(code).identifier(.alpha2) ?? device
    }

    func searchSubtitles() async throws -> [PlayerSubtitleSearchResult] {
        subtitleSearchWarning = nil
        let generation = itemGeneration
        if case .provider(let playback) = source, let provider = playback.provider as? SiloProvider {
            guard canSearchSubtitles else { throw MediaProviderError.backendSpecific(underlying: "Subtitle search is not enabled on Silo.") }
            let fileID = playback.stream.source.id
            let response = try await provider.searchSubtitles(fileID: fileID, language: subtitleSearchLanguage)
            guard isCurrentSiloFile(fileID, generation: generation) else { throw CancellationError() }
            subtitleSearchWarning = response.warnings.isEmpty ? nil : "Some Silo subtitle providers could not return results."
            return response.results.map { .silo($0, fileID: fileID, providerID: provider.id) }
        }
        guard case .plex = source, let ratingKey = metadata.ratingKey else { return [] }
        return try await PlexNetworkManager.shared.searchSubtitles(
            serverURL: serverURL, authToken: authToken, ratingKey: ratingKey, language: subtitleSearchLanguage)
            .map(PlayerSubtitleSearchResult.plex)
    }

    /// Downloads `result`, waits for the server to list it, then reloads at the
    /// playhead with it on. A reload re-registers every sidecar in Plex's order,
    /// which `TrackMerge` pairs on; adding one to the live engine would not.
    private func installPlexSubtitle(_ result: PlexStream) async {
        guard let ratingKey = metadata.ratingKey, let resultKey = result.key else { return }
        let network = PlexNetworkManager.shared
        let generation = itemGeneration
        let known = Set(plexSubtitleTracksFromMetadata().map(\.id))
        var tracks = currentPlexTrackIDs()
        showCompatibilityNotice("Downloading Subtitles…")
        do {
            try await network.downloadSubtitle(
                serverURL: serverURL, authToken: authToken, ratingKey: ratingKey, resultKey: resultKey)
            for _ in 0..<10 {
                try await Task.sleep(for: .seconds(1.5))
                let fresh = try await network.getMetadata(serverURL: serverURL, authToken: authToken, ratingKey: ratingKey)
                guard generation == itemGeneration else { return }
                let media = VersionRanking.select(playingMediaID.map(VersionChoice.source) ?? .best,
                                                  in: fresh.Media ?? []).media
                guard let added = media.first?.Part?.first?.Stream?.first(where: {
                    $0.isSubtitle && $0.key != nil && !known.contains($0.id)
                }) else { continue }
                metadata.Media = media
                TrackIntentStore.subtitleIntent = .afterPick(
                    MediaTrack(from: added), replacing: TrackIntentStore.effectiveSubtitleIntent,
                    audioLanguage: playingAudioLanguage)
                tracks.subtitle = added.id
                hideCompatibilityNotice()
                enqueueStreamWork { vm in
                    await vm.reloadStream(toOriginal: vm.aetherPlayer != nil, reason: "subtitle_download",
                                          tracks: tracks, restoring: vm.planSnapshot)
                }
                return
            }
            showCompatibilityNotice("Subtitles Didn't Arrive")
        } catch {
            if isCancellationError(error) || generation != itemGeneration { return }
            showCompatibilityNotice("Couldn't Download Subtitles")
        }
    }

    func installSubtitle(_ result: PlayerSubtitleSearchResult) async {
        switch result {
        case .plex(let result): await installPlexSubtitle(result)
        case .silo(let result, let resultFileID, let resultProviderID):
            guard case .provider(let playback) = source, let provider = playback.provider as? SiloProvider else { return }
            let generation = itemGeneration
            let fileID = playback.stream.source.id
            guard fileID == resultFileID, provider.id == resultProviderID else {
                subtitleOperation = .failed("These subtitle results belong to another file. Search again.")
                return
            }
            guard siloSubtitleTask == nil, !subtitleOperation.isBusy else {
                showCompatibilityNotice("Wait for the Silo subtitle operation, or cancel its job first.")
                return
            }
            subtitleOperation = .downloading
            do {
                let stored = try await provider.downloadSubtitle(result, fileID: fileID)
                guard isCurrentSiloFile(fileID, generation: generation) else { return }
                await activateSiloSubtitle(stored.id, fileID: fileID, generation: generation)
            } catch {
                guard isCurrentSiloFile(fileID, generation: generation), !isCancellationError(error) else { return }
                subtitleOperation = .failed(error.localizedDescription)
            }
        }
    }

    func generateSiloSubtitles(_ option: SiloSubtitleGenerationOption) {
        guard siloSubtitleTask == nil, !subtitleOperation.isBusy, case .provider(let playback) = source,
              let provider = playback.provider as? SiloProvider,
              option.fileID == playback.stream.source.id else { return }
        let generation = itemGeneration
        let fileID = playback.stream.source.id
        subtitleOperation = .starting
        siloSubtitleTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.isCurrentSiloFile(fileID, generation: generation) { self.siloSubtitleTask = nil } }
            do {
                try Task.checkCancellation()
                guard self.isCurrentSiloFile(fileID, generation: generation) else { return }
                if option.kind != .translate {
                    let quota = try await provider.subtitleQuota()
                    guard self.isCurrentSiloFile(fileID, generation: generation) else { return }
                    guard !quota.limited || quota.remaining > 0 else {
                        throw MediaProviderError.backendSpecific(underlying: "Silo's transcription quota is used up.")
                    }
                }
                try Task.checkCancellation()
                let job = try await provider.generateSubtitles(fileID: fileID, option: option)
                try await self.followSiloSubtitleJob(job, provider: provider, fileID: fileID, generation: generation)
            } catch {
                guard self.isCurrentSiloFile(fileID, generation: generation), !isCancellationError(error) else { return }
                self.subtitleOperation = .failed(error.localizedDescription)
            }
        }
    }

    func followSiloSubtitleJob(_ job: SiloSubtitleAIJob) {
        guard siloSubtitleTask == nil, !subtitleOperation.isBusy, case .provider(let playback) = source,
              let provider = playback.provider as? SiloProvider,
              job.mediaFileId == playback.stream.source.id else { return }
        let generation = itemGeneration
        let fileID = playback.stream.source.id
        siloSubtitleTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.isCurrentSiloFile(fileID, generation: generation) { self.siloSubtitleTask = nil } }
            do {
                try await self.followSiloSubtitleJob(job, provider: provider, fileID: fileID, generation: generation)
            } catch {
                guard self.isCurrentSiloFile(fileID, generation: generation), !isCancellationError(error) else { return }
                self.subtitleOperation = .failed(error.localizedDescription)
            }
        }
    }

    private func followSiloSubtitleJob(_ initial: SiloSubtitleAIJob, provider: SiloProvider,
                                       fileID: String, generation: Int) async throws {
        var job = initial
        while isCurrentSiloFile(fileID, generation: generation) {
            try Task.checkCancellation()
            guard job.mediaFileId == fileID else { throw MediaProviderError.notFound }
            subtitleOperation = .job(job)
            if let index = siloSubtitleJobs.firstIndex(where: { $0.id == job.id }) { siloSubtitleJobs[index] = job }
            else { siloSubtitleJobs.insert(job, at: 0) }
            if !job.isActive {
                if job.status == "completed" {
                    guard let storedID = job.resultSubtitleId else {
                        throw MediaProviderError.backendSpecific(underlying: "Silo completed the job without a subtitle file.")
                    }
                    await activateSiloSubtitle(storedID, fileID: fileID, generation: generation)
                } else if job.status == "failed" {
                    subtitleOperation = .failed(job.errorMessage ?? "Silo could not generate subtitles.")
                } else if job.status != "cancelled" {
                    throw MediaProviderError.backendSpecific(underlying: "Silo returned an unsupported subtitle job state.")
                }
                return
            }
            try await Task.sleep(for: .seconds(2))
            job = try await provider.subtitleJob(id: job.id)
        }
    }

    func cancelSiloSubtitleJob() async {
        guard let id = subtitleOperation.cancellableJobID, case .provider(let playback) = source,
              let provider = playback.provider as? SiloProvider else { return }
        let generation = itemGeneration
        let fileID = playback.stream.source.id
        do {
            try await provider.cancelSubtitleJob(id: id)
            let job = try await provider.subtitleJob(id: id)
            guard isCurrentSiloFile(fileID, generation: generation) else { return }
            subtitleOperation = .job(job)
        } catch {
            guard isCurrentSiloFile(fileID, generation: generation), !isCancellationError(error) else { return }
            showCompatibilityNotice("Silo couldn't cancel the subtitle job")
        }
    }

    private func isCurrentSiloFile(_ fileID: String, generation: Int) -> Bool {
        guard generation == itemGeneration, stopCount == 0, case .provider(let playback) = source,
              playback.provider is SiloProvider else { return false }
        return playback.stream.source.id == fileID
    }

    /// Follow only the selected canonical target. Reads also observe Silo's
    /// automatic sync; mutation requests are never retried by the poller.
    private func refreshSiloSubtitleSyncSelection(force: Bool = false) {
        let target = siloSubtitleSyncStatus?.isAvailable == true ? selectedSiloSubtitleTrack?.siloSyncTarget : nil
        let changed = target != siloSubtitleSyncTarget
        guard changed || force else { return }
        if !changed, siloSubtitleSyncMutation != nil { return }
        siloSubtitleSyncEpoch += 1
        siloSubtitleSyncTask?.cancel()
        siloSubtitleSyncTask = nil
        if changed {
            siloSubtitleSyncMutation?.cancel()
            siloSubtitleSyncMutation = nil
            siloSubtitleSyncUpdating = false
            siloSubtitleSyncTarget = target
            siloSubtitleSyncState = nil
            siloSubtitleSyncError = nil
            siloSubtitleAppliedTiming = nil
        }
        guard let target, siloSubtitleSyncMutation == nil, case .provider(let playback) = source,
              let provider = playback.provider as? SiloProvider else { return }
        startSiloSubtitleSyncPolling(provider: provider, target: target,
                                    generation: itemGeneration, epoch: siloSubtitleSyncEpoch)
    }

    private func ownsSiloSubtitleSync(_ target: SiloSubtitleSyncTarget, generation: Int, epoch: Int) -> Bool {
        isCurrentSiloFile(target.fileID, generation: generation) &&
            epoch == siloSubtitleSyncEpoch && target == siloSubtitleSyncTarget &&
            target == selectedSiloSubtitleTrack?.siloSyncTarget
    }

    private func startSiloSubtitleSyncPolling(provider: SiloProvider, target: SiloSubtitleSyncTarget,
                                            generation: Int, epoch: Int) {
        siloSubtitleSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let active = await self?.readSiloSubtitleSync(
                    provider: provider, target: target, generation: generation, epoch: epoch) else { return }
                do { try await Task.sleep(for: .seconds(active ? 2 : 10)) }
                catch { return }
            }
        }
    }

    private func readSiloSubtitleSync(provider: SiloProvider, target: SiloSubtitleSyncTarget,
                                     generation: Int, epoch: Int) async -> Bool? {
        guard ownsSiloSubtitleSync(target, generation: generation, epoch: epoch), !Task.isCancelled else { return nil }
        do {
            let read = try await provider.subtitleSyncState(target: target)
            guard ownsSiloSubtitleSync(target, generation: generation, epoch: epoch), !Task.isCancelled else { return nil }
            guard siloSubtitleSyncStatus?.canSync(read.subtitle) == true else {
                siloSubtitleSyncState = nil
                return nil
            }
            siloSubtitleSyncError = nil
            await acceptSiloSubtitleSync(read.subtitle, generation: generation, epoch: epoch)
            return read.subtitle.sync?.isActive == true
        } catch {
            guard ownsSiloSubtitleSync(target, generation: generation, epoch: epoch), !isCancellationError(error),
                  !Task.isCancelled else { return nil }
            siloSubtitleSyncError = error.localizedDescription
            return false
        }
    }

    private func acceptSiloSubtitleSync(_ state: SiloSubtitleSyncState, generation: Int, epoch: Int) async {
        guard ownsSiloSubtitleSync(state.target, generation: generation, epoch: epoch), !Task.isCancelled else { return }
        let needsReload = siloSubtitleAppliedTiming.map { $0 != state.timing } ?? !state.timing.isIdentity
        if needsReload, aetherLoadReturned, let player = aetherPlayer,
           case .provider(let playback) = source,
           let selected = playback.stream.source.subtitleTracks.first(where: \.isSelected),
           selected.siloSyncTarget == state.target {
            do {
                // Prepare before committing corrected bytes. No video restart,
                // clock change or acknowledgement of a failed artifact fetch.
                let replaced = try await player.replaceProviderSubtitle(selected,
                    timelineOffset: playback.stream.timelineOffset,
                    isCurrent: { [weak self, weak player] in
                        guard let self, let player else { return false }
                        return self.aetherPlayer === player && self.aetherLoadReturned &&
                            self.ownsSiloSubtitleSync(state.target, generation: generation, epoch: epoch)
                    })
                guard ownsSiloSubtitleSync(state.target, generation: generation, epoch: epoch),
                      !Task.isCancelled else { return }
                if replaced {
                    hasAppliedNativeEngineSubtitleSelection = true
                    siloSubtitleAppliedTiming = state.timing
                } else {
                    siloSubtitleSyncError = "Timing is saved on Silo, but this caption delivery cannot refresh during playback."
                }
            } catch {
                guard ownsSiloSubtitleSync(state.target, generation: generation, epoch: epoch),
                      !isCancellationError(error), !Task.isCancelled else { return }
                siloSubtitleSyncError = "Timing is saved on Silo, but subtitles could not refresh: \(error.localizedDescription)"
            }
        } else if !needsReload {
            siloSubtitleAppliedTiming = state.timing
        }
        guard ownsSiloSubtitleSync(state.target, generation: generation, epoch: epoch), !Task.isCancelled else { return }
        siloSubtitleSyncState = state
    }

    func startSiloSubtitleSync() { mutateSiloSubtitleSync(reset: false) }

    func resetSiloSubtitleTiming() { mutateSiloSubtitleSync(reset: true) }

    private func mutateSiloSubtitleSync(reset: Bool) {
        guard reset ? canResetSiloSubtitleTiming : canStartSiloSubtitleSync,
              let target = siloSubtitleSyncTarget, siloSubtitleSyncMutation == nil,
              case .provider(let playback) = source, let provider = playback.provider as? SiloProvider else { return }
        let generation = itemGeneration
        let epoch = siloSubtitleSyncEpoch
        siloSubtitleSyncTask?.cancel()
        siloSubtitleSyncTask = nil
        siloSubtitleSyncUpdating = true
        siloSubtitleSyncError = nil
        siloSubtitleSyncMutation = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.ownsSiloSubtitleSync(target, generation: generation, epoch: epoch) {
                    self.siloSubtitleSyncMutation = nil
                    self.siloSubtitleSyncUpdating = false
                    self.startSiloSubtitleSyncPolling(provider: provider, target: target, generation: generation, epoch: epoch)
                }
            }
            do {
                try Task.checkCancellation()
                let state: SiloSubtitleSyncState
                if reset { state = try await provider.resetSubtitleTiming(target: target).subtitle }
                else { state = try await provider.startSubtitleSync(target: target) }
                guard self.ownsSiloSubtitleSync(target, generation: generation, epoch: epoch),
                      !Task.isCancelled else { return }
                await self.acceptSiloSubtitleSync(state, generation: generation, epoch: epoch)
            } catch {
                guard self.ownsSiloSubtitleSync(target, generation: generation, epoch: epoch),
                      !isCancellationError(error), !Task.isCancelled else { return }
                self.siloSubtitleSyncError = error.localizedDescription
            }
        }
    }

    private func resetSiloSubtitleActions() {
        siloSubtitleTask?.cancel()
        siloSubtitleTask = nil
        siloSubtitleAIStatus = nil
        siloSubtitleJobs = []
        subtitleOperation = .idle
        siloSubtitleSyncEpoch += 1
        siloSubtitleSyncTask?.cancel()
        siloSubtitleSyncMutation?.cancel()
        siloSubtitleSyncTask = nil
        siloSubtitleSyncMutation = nil
        siloSubtitleSyncTarget = nil
        siloSubtitleAppliedTiming = nil
        siloSubtitleSyncStatus = nil
        siloSubtitleSyncState = nil
        siloSubtitleSyncError = nil
        siloSubtitleSyncUpdating = false
        subtitleSearchWarning = nil
        canSearchSubtitles = false
    }

    private func activateSiloSubtitle(_ storedID: String, fileID: String, generation: Int) async {
        subtitleOperation = .activating
        await enqueueStreamWork { vm in
            guard vm.isCurrentSiloFile(fileID, generation: generation), case .provider(var playback) = vm.source,
                  let provider = playback.provider as? SiloProvider else { return }
            let position = vm.playheadForReload
            let resume = vm.playbackState != .paused
            vm.pendingProviderPlaybackIntent = resume
            defer { vm.pendingProviderPlaybackIntent = nil }
            do {
                let previous = playback.stream
                playback.stream = try await provider.streamSelectingStoredSubtitle(storedID, current: playback.stream, position: position)
                guard vm.isCurrentSiloFile(fileID, generation: generation), !Task.isCancelled else { return }
                vm.metadata = ProviderPlaybackMetadata.make(detail: playback.detail, source: playback.stream.source, extras: playback.extras)
                vm.setProviderStream(playback, startPosition: position,
                                     preservingReporter: previous.playSessionID == playback.stream.playSessionID)
                guard try await vm.applyProviderPlaybackReplacement(previous: previous, at: position) else { return }
                if vm.pendingProviderPlaybackIntent ?? resume {
                    vm.activePlayer_play()
                } else {
                    vm.activePlayer_pause()
                    vm.updatePlaybackState(.paused)
                }
                if let selected = vm.subtitleTracks.first(where: { $0.id == vm.currentSubtitleTrackId }) {
                    TrackIntentStore.subtitleIntent = .afterPick(selected, replacing: TrackIntentStore.effectiveSubtitleIntent,
                                                               audioLanguage: vm.playingAudioLanguage)
                }
                vm.subtitleOperation = .completed
            } catch {
                guard vm.isCurrentSiloFile(fileID, generation: generation), !isCancellationError(error) else { return }
                vm.subtitleOperation = .failed(error.localizedDescription)
            }
        }.value
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
    /// Off was picked for this title, before or during play: the generated
    /// fallback and Foreign Audio's re-resolve stay away.
    private var subtitlesPickedOff = false
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
    /// On aether, `TrackMerge` folds Plex labels into the engine's tracks, so ids
    /// are engine indices. On hls, the tracks and ids are Plex's as-is.
    /// Called from the engine's track publishers too, since either side can arrive first.
    private func updateTrackLists() {
        let previousSubtitleCount = subtitleTracks.count
        let previousAudioCount = audioTracks.count
        // Fresh track ids: a mute session from the old list no longer applies.
        if previousSubtitleCount == 0 { captionsOnMute = CaptionsOnMuteLogic() }

        let plexStreams = metadata.Media?.first?.Part?.first?.Stream ?? []
        let plexAudio = plexStreams.filter { $0.isAudio }.map { MediaTrack(from: $0) }
        let plexSubs = plexStreams.filter { $0.isSubtitle }.map { MediaTrack(from: $0) }

        if providerTracksRequireReplan {
            audioTracks = plexAudio
            subtitleTracks = plexSubs
            if !hasAppliedAudioPreference {
                currentAudioTrackId = plexStreams.first { $0.isAudio && $0.selected == true }?.id
                hasAppliedAudioPreference = !audioTracks.isEmpty
            }
            if !hasAppliedSubtitlePreference {
                currentSubtitleTrackId = plexStreams.first { $0.isSubtitle && $0.selected == true }?.id
                hasAppliedSubtitlePreference = !subtitleTracks.isEmpty
            }
            applyNativeEngineTrackSelection()
            refreshSiloSubtitleSyncSelection()
            return
        }
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
            // Re-read every call: the engine renumbers its tracks mid-session
            // (an audio switch rebuilds them), so its active index is authoritative.
            if silentSubtitleTrackId == nil, !showsGeneratedSubtitles, let active = ap.activeSubtitleTrackId {
                currentSubtitleTrackId = active
            }
            if let active = ap.activeAudioTrackId {
                currentAudioTrackId = active
            }
        } else {
            audioTracks = plexAudio
            subtitleTracks = plexSubs

            // Plex route: seed the current ids from what the transcode was started
            // with, else from the server's stream flags.
            if previousAudioCount == 0 {
                currentAudioTrackId = transcodeTrackIDs?.audio
                    ?? plexStreams.first(where: { $0.isAudio && $0.selected == true })?.id
                    ?? plexAudio.first(where: { $0.isDefault })?.id
                    ?? plexAudio.first?.id
            }
            if previousSubtitleCount == 0 {
                if let subtitle = transcodeTrackIDs?.subtitle {
                    currentSubtitleTrackId = subtitle == 0 ? nil : subtitle
                } else {
                    currentSubtitleTrackId = plexStreams.first(where: { $0.isSubtitle && $0.selected == true })?.id
                        ?? plexSubs.first(where: { $0.isForced })?.id
                        ?? plexSubs.first(where: { $0.isDefault })?.id
                }
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
        syncSilentSubtitleRead()
        updateCaptionsOnMute()
    }

    /// Plex's `selected` audio stream when it outranks the global intent: a
    /// per-item pick (selected but not the file default), or, with no audio
    /// language set in Rivulet, the server's pick from the account's language (#382).
    private var plexChosenAudioStreamId: Int? {
        let streams = (metadata.Media?.first?.Part?.first?.Stream ?? []).filter { $0.isAudio }
        guard let selectedId = streams.first(where: { $0.selected == true })?.id else { return nil }
        if TrackIntentStore.audioIntent == nil { return selectedId }
        guard let defaultId = streams.first(where: { $0.default == true })?.id else { return nil }
        return selectedId != defaultId ? selectedId : nil
    }

    /// Apply saved audio preference, in the numbered priority below. Every tier
    /// selects explicitly, even when the id already matches: neither direct play
    /// nor Plex's HLS session reliably starts on the persisted selection.
    private func applyAudioPreference() {
        // 1. Pre-play picker (this session). Its id is a Plex stream id.
        if let id = initialAudioTrackId {
            initialAudioTrackId = nil
            if let track = audioTrackMatchingPlexStreamId(id) {
                selectAudioTrackWithoutSaving(id: track.id)
                return
            }
        }

        // 2. Plex's choice (see `plexChosenAudioStreamId`).
        if let selectedId = plexChosenAudioStreamId,
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
        if case .provider(let playback) = source,
           let selection = playback.stream.authoritativeSubtitleSelection {
            switch initialSubtitleSelection {
            case .off: initialSubtitleSelection = .auto; selectSubtitleTrackWithoutSaving(id: nil)
            case .track(let id): initialSubtitleSelection = .auto; selectSubtitleTrackWithoutSaving(id: id)
            case .auto:
                switch selection {
                case .off: selectSubtitleTrackWithoutSaving(id: nil)
                case .track(let selectedID, _):
                    let ordinal = playback.stream.source.subtitleTracks.firstIndex { $0.id == selectedID }
                    let id = ordinal.flatMap { plexSubtitleTracksFromMetadata()[safe: $0]?.id }
                    selectSubtitleTrackWithoutSaving(id: id)
                }
            }
            return
        }
        // 1. Pre-play picker selection (this session); `.auto` falls through.
        switch initialSubtitleSelection {
        case .off:
            initialSubtitleSelection = .auto
            subtitlesPickedOff = true
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
           !track.isDefault, !track.isForced,
           TrackIntentResolver.plexSelectedSubtitleMayOverride(
               track, intent: TrackIntentStore.effectiveSubtitleIntent
           ) {
            selectSubtitleTrackWithoutSaving(id: track.id)
            return
        }

        applyGlobalSubtitleIntent()
    }

    /// The playing audio track's language, for Foreign Audio.
    private var playingAudioLanguage: String? {
        let audio = audioTracks.first { $0.id == currentAudioTrackId }
        return audio?.languageCode ?? audio?.language
    }

    private func applyGlobalSubtitleIntent() {
        // 3. Global subtitle intent, read only: no match means off for this
        //    title, and the stored intent is kept. Only a user pick writes it.
        if let match = TrackIntentResolver.resolveSubtitle(intent: TrackIntentStore.effectiveSubtitleIntent,
                                                           in: subtitleTracks, audioLanguage: playingAudioLanguage) {
            selectSubtitleTrackWithoutSaving(id: match.id)
        } else {
            selectSubtitleTrackWithoutSaving(id: nil)
        }
    }

    /// Select a subtitle track without persisting intent (auto-selection).
    ///
    /// No id translation: on the aether route `subtitleTracks` ids ARE engine
    /// stream indices (see `TrackMerge`), so the id dispatches straight through.
    /// `reloadsTranscode` false keeps a transient change (the replay window) from restarting a transcode.
    private func selectSubtitleTrackWithoutSaving(id: Int?, reloadsTranscode: Bool = true) {
        let generated = id == Self.generatedSubtitleId
        let wasGenerated = showsGeneratedSubtitles
        let changed = id != currentSubtitleTrackId
        if changed { aetherPlayer?.invalidateProviderSubtitlePreparation() }
        if providerTracksRequireReplan {
            currentSubtitleTrackId = id
            if changed, reloadsTranscode {
                reloadTranscodeForTrackChange()
            } else if !reloadsTranscode {
                aetherPlayer?.selectSubtitleTrack(id: nativeSubtitleEngineID(for: id))
            }
        } else if generated || wasGenerated && id == nil {
            // The engine's one selection stays with the filter's unseen read; only a shown track leaves it.
            if !wasGenerated, currentSubtitleTrackId != nil { aetherPlayer?.selectSubtitleTrack(id: nil) }
        } else {
            aetherPlayer?.selectSubtitleTrack(id: id)
        }
        currentSubtitleTrackId = id
        refreshSiloSubtitleSyncSelection()
        if generated {
            SpeechModelStore.shared.prepare()
            aetherSubtitleModel.update(cues: generatedCues())
        } else if wasGenerated {
            aetherSubtitleModel.update(cues: engineCues)
        }
        syncSilentSubtitleRead()
        if changed, reloadsTranscode, aetherPlayer == nil, !providerTracksRequireReplan {
            // The old track's captions go now, not when the reloaded transcode is ready.
            stopTranscodeSubtitleReader()
            clearTranscodeSubtitles()
            reloadTranscodeForTrackChange()
        }
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
    // The pre-play picker and Plex's `selected` flag speak Plex stream ids. On
    // aether, join on the container stream index; sidecars pair by order.

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
        hidePausedPoster()
    }

    /// Enter transport-control focus mode. Called on every focus landing in the
    /// rail, so it also restarts the auto-hide timer.
    func enterControlsFocus() {
        guard showControls, !isScrubbing, postVideoState == .hidden else { return }
        controlsFocusActive = true
        startControlsHideTimer()
    }

    /// Leave transport-control focus mode; controls stay visible and
    /// the auto-hide timer restarts.
    func exitControlsFocus() {
        guard controlsFocusActive else { return }
        controlsFocusActive = false
        startControlsHideTimer()
    }

    private func startControlsHideTimer() {
        // Only an open rail panel suspends auto-hide. Do not gate on
        // `controlsFocusActive`: it is true whenever the rail is up (#277).
        guard !isRailPanelOpen else { return }
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: controlsHideDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            let isPlaying = self.playbackState == .playing
            Task { @MainActor [weak self] in
                guard let self, isPlaying else { return }
                // Re-check at FIRE time: a panel can open after the timer was
                // already armed. The arm-time guard alone leaves that timer running.
                guard !self.isRailPanelOpen else { return }
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
    /// `pausedPosterDimDelay` seconds paused. Scrubbing and open rail panels
    /// suspend both tiers so the backdrop cannot cover the transport controls.
    private func startPausedPosterTimer() {
        guard !isScrubbing, !isRailPanelOpen else { return }
        pausedPosterTimer?.invalidate()
        pausedPosterTimer = Timer.scheduledTimer(withTimeInterval: pausedPosterDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackState == .paused, !self.isScrubbing, !self.isRailPanelOpen else { return }
                withAnimation(.easeIn(duration: 1.0)) {
                    self.pausePresentation = .ambient
                }
                // The rail goes unfocusable under the poster; hand focus back to
                // the content anchor so arrows and Select still reach the player.
                self.controlsFocusActive = false
            }
        }

        pausedPosterDimTimer?.invalidate()
        pausedPosterDimTimer = Timer.scheduledTimer(withTimeInterval: pausedPosterDimDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackState == .paused, !self.isScrubbing, !self.isRailPanelOpen else { return }
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

    /// Any control input drops the paused poster; its timers restart unless scrubbing.
    func hidePausedPoster() {
        cancelPausedPosterTimer()
        if playbackState == .paused { startPausedPosterTimer() }
    }

    // MARK: - Marker Detection & Skipping

    /// How many seconds before a marker to show the skip button
    private let markerPreviewTime: TimeInterval = 5.0

    /// Check if current time is within a marker range (or approaching one)
    /// Also triggers post-video summary at credits marker or 45s before end
    private func checkMarkers(at time: TimeInterval) {
        // Don't check while scrubbing or if post-video already showing
        guard !isScrubbing, postVideoState == .hidden else { return }

        // Check recap markers first — a recap precedes the intro in an
        // episode. These exist only via the IntroDB backup (Plex never emits
        // recap), so this loop is a no-op unless the backfill added one.
        for recap in metadata.recapMarkers {
            guard let recapId = recap.id else { continue }
            guard recap.endTimeSeconds > recap.startTimeSeconds else { continue }

            let previewStart = max(0, recap.startTimeSeconds - markerPreviewTime)

            // Reset skip flag if the user rewound before the marker (same
            // starts-at-0 special case as the intro marker below).
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
        // Off in Settings: no pill and no auto-skip (#381).
        let mode = MarkerSkipMode.current(for: "intro")
        guard mode != .off else { return }
        let autoSkipIntro = mode == .automatic

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

        let mode = MarkerSkipMode.current(for: "credits")
        guard mode != .off else { return }
        let autoSkipCredits = mode == .automatic

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

    /// Handle when playback enters a recap marker range (or preview window).
    /// Recap markers come from the IntroDB backup; same behaviour as the
    /// other marker kinds.
    private func handleRecapMarkerActive(_ marker: PlexMarker, currentTime: TimeInterval) {
        guard let recapId = marker.id else { return }

        let mode = MarkerSkipMode.current(for: "recap")
        guard mode != .off else { return }
        let autoSkipRecap = mode == .automatic

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

    /// Handle when playback enters a commercial marker range (or preview window)
    /// Auto-skip only triggers when actually inside the marker (at or past startTimeSeconds).
    private func handleCommercialMarkerActive(_ marker: PlexMarker, currentTime: TimeInterval) {
        guard let commercialId = marker.id else { return }

        let mode = MarkerSkipMode.current(for: "commercial")
        guard mode != .off else { return }
        let autoSkipAds = mode == .automatic

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
        }

        // Marker skip (manual or auto) is a user-initiated seek that bypasses
        // commitScrub/.seekAbsolute: clear any active replay window so a
        // stale invocation point can't spuriously revert subtitles later,
        // disconnected from where playback actually landed post-skip.
        clearReplayWindow()

        switch MarkerSkipPolicy.outcome(
            isCredits: marker.isCredits,
            markerEnd: marker.endTimeSeconds,
            duration: duration
        ) {
        case .finish:
            // Credits run to the file end, so finish instead of seeking: the
            // engine turns a seek into its end epsilon into `.paused` and never
            // sends `.ended`, which would park the player on the last frame.
            activeMarker = nil
            showSkipButton = false
            await finishPlayback()

        case .seek(let target):
            // Intro / recap / ad, or a credits marker that ends mid-stream:
            // ordinary seek, clamped just inside the media.
            // Preserve the chrome state across the skip: if the controls were
            // hidden (the pill owned focus), the jump must NOT pop the rail open;
            // if they were already up, keep them up.
            await seek(to: target, revealsControls: showControls)

            // Hide button
            activeMarker = nil
            showSkipButton = false
        }
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
        }
        return "Skip"
    }

    /// Pill title. The auto-skip countdown is shown as a left-to-right fill
    /// sweep on the pill (SkipPillButton.beginFill, driven by
    /// PlayerContainerViewController from `skipCountdownSeconds`), not as a
    /// "· N" text suffix — so this is always just the base label.
    var skipButtonDisplayLabel: String {
        skipButtonLabel
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

    /// Puts the chosen version of a server-ordered `Media` array first and records it.
    private func applyVersion(_ choice: VersionChoice, to media: [PlexMedia]?, capKbps: Int? = nil) {
        guard let media, !media.isEmpty else { return }
        let selection = VersionRanking.select(choice, in: media, capKbps: capKbps)
        metadata.Media = selection.media
        playingMediaID = selection.media.first.map { "\($0.id)" }
        playingMediaServerIndex = selection.serverIndex
    }

    private var currentVersionChoice: VersionChoice {
        playingMediaID.map(VersionChoice.source) ?? upNextTier.map(VersionChoice.matchingTier) ?? .best
    }

    /// Up Next plays each episode's best file unless the user picked one; then it keeps that tier.
    func upNextVersionChoice() -> VersionChoice {
        guard pickedVersion else { return .best }
        if upNextTier == nil { upNextTier = playingTier }
        return upNextTier.map(VersionChoice.matchingTier) ?? .best
    }

    /// Resolution tier of the version playing, for Up Next.
    private var playingTier: Int {
        if case .provider(let playback) = source { return VersionRanking.key(playback.stream.source).tier }
        return metadata.Media?.first.map { VersionRanking.key($0).tier } ?? 0
    }

    /// Fetch detailed metadata with markers if not already present
    private func fetchMarkersIfNeeded() async {
        // A provider item's shim already carries markers, chapters and streams.
        guard case .plex = source, let ratingKey = metadata.ratingKey else {
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
                applyVersion(currentVersionChoice, to: media)
            }

            // Fill in missing display info (summary, genres, etc.)
            if metadata.summary == nil { metadata.summary = detailedMetadata.summary }
            if metadata.Genre == nil { metadata.Genre = detailedMetadata.Genre }
            if metadata.contentRating == nil { metadata.contentRating = detailedMetadata.contentRating }
            // External ids (imdb://, tmdb://): the content filter can key its
            // list lookup on them, and hub items arrive without them.
            if metadata.Guid == nil { metadata.Guid = detailedMetadata.Guid }
        } catch {
            print("⏭️ [Skip] Failed to fetch detailed metadata: \(error)")
        }
    }

    /// Adds IntroDB backup markers for kinds Plex didn't provide. Episodes
    /// only (the lookup keys on the show's IMDB id + season/episode). Plex is
    /// authoritative: a kind Plex already emitted is never replaced. Gated by
    /// the "useIntroDB" opt-in at the call site.
    private func backfillMarkersFromIntroDB() async {
        guard metadata.type == "episode",
              let season = metadata.parentIndex,
              let episode = metadata.index else { return }

        let presentKinds = Set((metadata.Marker ?? []).compactMap(\.type))
        let missingKinds = ["intro", "recap", "credits"].filter { !presentKinds.contains($0) }
        guard !missingKinds.isEmpty else { return }

        guard let imdbID = await showIMDBID() else { return }

        let generation = itemGeneration
        let backup = await IntroDBClient().markers(imdbID: imdbID, season: season, episode: episode)
        guard generation == itemGeneration else { return }  // item swapped mid-fetch

        let extras = backup.filter { marker in
            guard let type = marker.type else { return false }
            return missingKinds.contains(type)
        }
        guard !extras.isEmpty else { return }
        metadata.Marker = (metadata.Marker ?? []) + extras
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
        guard playQueue == nil, metadata.type == "episode" else { return }
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

    /// At the credits boundary (or 45s from the end): enter the Up Next flow,
    /// or, with the panel off for episodes, just mark the item watched.
    private func triggerPostVideoTransition() {
        let isEpisode = metadata.type == "episode"

        if playQueue != nil || showPostVideoUpNext || !isEpisode {
            Task { await handlePlaybackEnded() }
        } else {
            Task { await markCurrentAsWatched() }
        }
    }

    /// Playback is over for good: the stream reached its end, or a credits skip
    /// consumed everything left. Runs the end-of-playback funnel, then exits the
    /// player when nothing followed it (#264). Do not fold this into
    /// `handlePlaybackEnded()`: its other caller runs mid-credits and must not exit.
    func finishPlayback() async {
        await handlePlaybackEnded()
        if postVideoState == .hidden {
            shouldDismiss = true
        }
    }

    func handlePlaybackEnded() async {
        let isEpisode = metadata.type == "episode"
        // This funnel ends ONE item, and it awaits twice before it commits any
        // state. A swap landing in either gap would otherwise write the
        // outgoing episode's ending onto the incoming one — mark it watched at
        // ~0s and open Up Next for the episode after it.
        let generation = itemGeneration

        // Don't re-enter if already showing post-video
        guard postVideoState == .hidden else { return }

        // Mark as watched immediately when playback ends/reaches credits.
        // This runs exactly once whether the custom overlay or the native
        // card drives Up Next.
        await markCurrentAsWatched()
        guard generation == itemGeneration else { return }

        postVideoState = .loading

        // Per-user opt-out of the post-video "Up Next" chooser for TV
        // episodes. When disabled, episodes follow the same path movies
        // already take: credits play uninterrupted at full size.
        // Movies: No PostVideo - just let the video play through to the end.
        // A playlist's next entry follows any type, ahead of both gates.
        guard playQueue != nil || (isEpisode && showPostVideoUpNext) else {
            postVideoState = .hidden
            return
        }

        // TV Show: Only show PostVideo if there's a next episode

        // If parent metadata is missing (e.g., from Continue Watching), fetch full metadata first
        if playQueue == nil, metadata.parentRatingKey == nil || metadata.index == nil {
            await fetchFullMetadataIfNeeded()
        }

        // Fetch next episode
        let resolvedNext = await fetchNextEpisode()
        guard generation == itemGeneration else { return }
        nextEpisode = resolvedNext

        // No next episode: Skip PostVideo - just let the video play through
        guard nextEpisode != nil else {
            postVideoState = .hidden
            return
        }

        postVideoState = .showingEpisodeSummary

        // Start countdown and preload
        startAutoplayCountdown()
        // Preload next episode in background for instant playback. A provider
        // episode is prepared now, so a failure shows before the countdown fires.
        Task {
            if case .provider(let playback) = source, let next = nextEpisode {
                guard !playback.provider.reservesPlaybackOnResolve else { return }
                await preparedNextProviderPlayback(for: next)
            } else {
                await preloadNextEpisode()
            }
        }
    }

    /// Fetch full metadata if parent keys or Media info are missing (e.g., from Continue Watching)
    private func fetchFullMetadataIfNeeded() async {
        // Plex metadata endpoint; a provider item's ratingKey is not a Plex key.
        guard case .plex = source, let ratingKey = metadata.ratingKey else {
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
                applyVersion(currentVersionChoice, to: fullMetadata.Media)
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

        } catch {
            print("🎬 [Metadata] Failed to fetch full metadata: \(error)")
        }
    }

    /// Load the current season's episode list for the Up Next panel, sorted
    /// by index. When the current episode is the season finale, appends the
    /// next season's opener (via `fetchNextEpisode()`) so the panel still has
    /// an up-next row to show. No-ops (clears to []) for non-episode content
    /// or on any fetch failure.
    func loadUpNextEpisodes() async {
        let generation = itemGeneration
        guard playQueue == nil else { return }
        guard metadata.type == "episode" else {
            upNextEpisodes = []
            return
        }
        if case .provider(let playback) = source {
            let upNext = await providerUpNext(playback)
            guard generation == itemGeneration else { return }
            var episodes = upNext.season
            // Season finale: the next season's opener is the up-next row.
            if let next = upNext.next, next.parentRef != playback.detail.item.parentRef {
                episodes.append(next)
            }
            upNextEpisodes = episodes.map(ProviderPlaybackMetadata.listing(item:))
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
            if episodes.last?.ratingKey == metadata.ratingKey,
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
        let tmdbId = await insightsTmdbID()
        guard generation == itemGeneration else { return }

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
        if people.isEmpty, case .plex = source {
            // Hub items carry a truncated Role list (3 on Continue Watching).
            var roles = await insightsFullMetadata()?.Role ?? metadata.Role ?? []
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

    /// Load trivia for the Insights panel, with the same tmdb id resolution as
    /// `loadInsightsCast()`. Every failure reads as no trivia.
    func loadInsightsTrivia() async {
        let generation = itemGeneration
        let tmdbId = await insightsTmdbID()
        guard generation == itemGeneration else { return }

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

    /// The TMDB id both Insights sections describe: an episode's SHOW (never the
    /// episode's own guid, which some agents set wrongly), else the item. Hub
    /// items (Continue Watching) arrive without Guid, so a miss reads full metadata.
    private func insightsTmdbID() async -> Int? {
        if let providerEpisode { return await providerShowTmdbID(providerEpisode) }
        if metadata.type == "episode" {
            if let id = metadata.parentShowTmdbId ?? metadata.showTmdbId { return id }
            return await InsightsShowIDResolver.shared.resolve(await resolveShowExternalIDs())
        }
        if let id = metadata.tmdbId { return id }
        return await insightsFullMetadata()?.tmdbId
    }

    /// One full-metadata fetch per item, shared by the cast and trivia loads.
    private var insightsFullMetadataTask: (generation: Int, task: Task<PlexMetadata?, Never>)?

    private func insightsFullMetadata() async -> PlexMetadata? {
        guard case .plex = source, let key = metadata.ratingKey else { return nil }
        if let cached = insightsFullMetadataTask, cached.generation == itemGeneration {
            return await cached.task.value
        }
        let (url, token) = (serverURL, authToken)
        let task = Task {
            try? await PlexNetworkManager.shared.getFullMetadata(serverURL: url, authToken: token, ratingKey: key)
        }
        insightsFullMetadataTask = (itemGeneration, task)
        return await task.value
    }

    /// `.provider` episodes only: the playback, since an episode's own ids are
    /// the episode's and its show's come from the series.
    private var providerEpisode: ProviderPlayback? {
        guard case .provider(let playback) = source, metadata.type == "episode" else { return nil }
        return playback
    }

    /// `.provider` only: the series detail's ids, fetched once per show.
    private var providerShowIDs: (show: MediaItemRef, task: Task<[String: String], Never>)?

    /// A provider episode's show TMDB id: the series' own, else resolved from
    /// its tvdb or imdb id. nil when the episode has no show.
    func providerShowTmdbID(_ playback: ProviderPlayback) async -> Int? {
        guard let show = playback.item.grandparentRef else { return nil }
        let task: Task<[String: String], Never>
        if let cached = providerShowIDs, cached.show == show {
            task = cached.task
        } else {
            let provider = playback.provider
            task = Task { (try? await provider.fullDetail(for: show))?.externalIDs ?? [:] }
            providerShowIDs = (show, task)
        }
        let ids = await task.value
        return await InsightsShowIDResolver.shared.resolve(ShowExternalIDs(
            tmdb: ids["tmdb"].flatMap { Int($0) },
            tvdb: ids["tvdb"].flatMap { Int($0) },
            imdb: ids["imdb"]
        ))
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

    /// Back-off for the mid-playback trivia re-check: a quick first probe, then
    /// every ~2 min out to ~20 min, since a cold title can take 10 to 15 min to generate.
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

    /// The episode after `current`: the next by number in its season, else
    /// the first of the next season. Episodes without a number are skipped.
    static func nextEpisode(after current: MediaItem, in seasonEpisodes: [MediaItem],
                            nextSeasonEpisodes: [MediaItem]?) -> MediaItem? {
        guard let number = current.episodeNumber else { return nil }
        return byEpisodeNumber(seasonEpisodes).first { ($0.episodeNumber ?? 0) > number }
            ?? byEpisodeNumber(nextSeasonEpisodes ?? []).first
    }

    private static func byEpisodeNumber(_ episodes: [MediaItem]) -> [MediaItem] {
        episodes.filter { $0.episodeNumber != nil }
            .sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
    }

    /// `.provider` half of the next-episode lookup: the current season's
    /// episodes in order, and the episode after the current one. Every item
    /// returned is registered so its shim maps back to it.
    private func providerUpNext(_ playback: ProviderPlayback) async -> (season: [MediaItem], next: MediaItem?) {
        let generation = itemGeneration
        let task: Task<(season: [MediaItem], next: MediaItem?), Never>
        if let fetch = providerUpNextFetch, fetch.generation == generation {
            task = fetch.task
        } else {
            task = Task { await Self.fetchProviderUpNext(playback) }
            providerUpNextFetch = (generation, task)
        }
        let result = await task.value
        if result.season.isEmpty, providerUpNextFetch?.generation == generation {
            providerUpNextFetch = nil
        }
        for item in result.season + [result.next].compactMap({ $0 }) {
            providerEpisodeItems[item.ref.itemID] = item
        }
        return result
    }

    /// Specials a server lists inside a season carry their own season number
    /// and are left out, so they never become the next episode.
    private static func fetchProviderUpNext(_ playback: ProviderPlayback) async -> (season: [MediaItem], next: MediaItem?) {
        let current = playback.detail.item
        let provider = playback.provider
        guard current.kind == .episode, let seasonRef = current.parentRef,
              let children = try? await provider.children(of: seasonRef) else { return ([], nil) }
        let season = byEpisodeNumber(children.filter { $0.seasonNumber == current.seasonNumber })
        var nextSeasonEpisodes: [MediaItem]?
        if let number = current.episodeNumber, let seasonNumber = current.seasonNumber,
           !season.contains(where: { ($0.episodeNumber ?? 0) > number }),
           let showRef = current.grandparentRef,
           let seasons = try? await provider.children(of: showRef),
           let nextSeason = seasons
               .filter({ ($0.seasonNumber ?? Int.min) > seasonNumber })
               .min(by: { ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0) }) {
            nextSeasonEpisodes = try? await provider.children(of: nextSeason.ref)
                .filter { $0.seasonNumber == nextSeason.seasonNumber }
        }
        return (season, nextEpisode(after: current, in: season, nextSeasonEpisodes: nextSeasonEpisodes))
    }

    /// A playlist row's still: an episode's frame, otherwise the backdrop.
    static func queueThumbnailURL(for item: MediaItem) -> URL? {
        item.kind == .episode ? item.artwork.thumbnail ?? item.artwork.backdrop
            : item.artwork.backdrop ?? item.artwork.thumbnail
    }

    /// Up Next thumbnail for a provider episode's shim, from its own artwork.
    /// nil on the Plex path, where the views build the Plex URL.
    func providerThumbnailURL(for episode: PlexMetadata) -> URL? {
        // A playlist entry is a listing shell on both sources: its art is the item's.
        if let key = episode.ratingKey,
           let item = playQueue?.entries.first(where: { $0.item.ref.itemID == key })?.item {
            return Self.queueThumbnailURL(for: item)
        }
        guard case .provider = source, let key = episode.ratingKey,
              let item = providerEpisodeItems[key] else { return nil }
        return item.artwork.thumbnail ?? item.artwork.backdrop
    }

    /// Fetch the next episode for TV shows
    func fetchNextEpisode() async -> PlexMetadata? {
        // A playlist plays its next entry, any type. No side effects: the swap advances.
        if let playQueue {
            return playQueue.next.map { ProviderPlaybackMetadata.listing(item: $0.item) }
        }
        if case .provider(let playback) = source {
            return await providerUpNext(playback).next.map(ProviderPlaybackMetadata.listing(item:))
        }

        // Check if next episode was prefetched
        // The cache holds the selected server's ratingKeys; another server's can collide.
        if let ratingKey = metadata.ratingKey, PlexAuthManager.shared.selectedServerURL == serverURL,
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
        // Autoplay Limit: past it, Up Next waits for the remote.
        guard AutoplayLimit.current.allowsAutoplay(afterEpisodesInARow: episodesInARow) else { return }

        countdownSeconds = countdownSetting
        // The ring draws remaining/total, so it needs the RESOLVED setting.
        // Re-reading the raw default at the ring is what broke it:
        // `integer(forKey:)` answers 0 for a key nobody has written, and
        // nothing writes this one until the user visits the picker — so on a
        // default install the arc trimmed to zero and never moved.
        countdownTotalSeconds = countdownSetting
        isCountdownPaused = false

        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard !self.isCountdownPaused else { return }

                self.countdownSeconds -= 1

                if self.countdownSeconds <= 0 {
                    self.countdownTimer?.invalidate()
                    await self.playNextEpisode(autoplayed: true)
                }
            }
        }
    }

    /// Preload the next episode's stream URL and metadata for instant playback
    private func preloadNextEpisode() async {
        // Plex only: a provider episode is prepared from its provider at the
        // swap (`playNextEpisode`), never from a Plex URL built here.
        // ponytail: no provider preload; add one if the swap's start is slow.
        guard case .plex = source else { return }
        guard let next = nextEpisode, let ratingKey = next.ratingKey else { return }

        let networkManager = PlexNetworkManager.shared

        // Fetch full metadata with markers
        do {
            let fullMetadata = try await plexMetadataFetch(serverURL, authToken, ratingKey)
            preloadedNextMetadata = fullMetadata
        } catch {
            print("🎬 [Preload] Failed to fetch metadata: \(error)")
            preloadedNextMetadata = next
        }

        // A transcode would never read the warmed bytes.
        guard nextEpisodePlaysOriginal else { return }

        // Build stream URL for next episode, from the same choice the swap makes,
        // so the warmed URL is the file that plays.
        let metadata = preloadedNextMetadata ?? next
        let nextMedia = VersionRanking.select(upNextVersionChoice(), in: metadata.Media ?? []).media.first
        if let partKey = nextMedia?.Part?.first?.key {
            preloadedNextStreamURL = networkManager.buildPlaybackDirectPlayURL(
                serverURL: serverURL,
                authToken: authToken,
                partKey: partKey
            )
            // Must be the SAME builder the load uses: these headers are the
            // prewarm adoption key below, and a hand-copied duplicate that
            // drifts from `rivuletDirectPlayHeaders()` warms bytes the load
            // then refuses to take, silently and with no symptom but a slow
            // start.
            preloadedNextStreamHeaders = rivuletDirectPlayHeaders()
            if let preloadedURL = preloadedNextStreamURL {
                let headers = preloadedNextStreamHeaders
                Task(priority: .utility) {
                    // Warms the opening bytes; the next `load()` of this exact
                    // URL and headers reads them from memory.
                    await AetherPlayer.prewarm(url: preloadedURL, headers: headers)
                }
            }
        }
    }

    /// Clear preloaded data
    private func clearPreloadedData() {
        preloadedNextStreamURL = nil
        preloadedNextStreamHeaders = [:]
        preloadedNextMetadata = nil
        discardNextProviderPreparation()
        nextEpisodeError = nil
    }

    private func discardNextProviderPreparation() {
        guard let pending = nextProviderPrepare else { return }
        nextProviderPrepare = nil
        nextProviderPreparationToken += 1
        pending.task.cancel()
        Task { @MainActor [weak self] in
            guard let prepared = await pending.task.value else { return }
            if let self, case .provider(let current) = self.source,
               current.stream.playSessionID == prepared.stream.playSessionID { return }
            await ProviderPlayback.discardUnplayedStream(prepared.stream, provider: prepared.provider)
        }
    }

    /// `.provider` only: the next episode's playback. One prepare per target,
    /// shared by the countdown start and the swap; a failure is shown and
    /// forgotten, so Play Now asks again.
    @discardableResult
    private func preparedNextProviderPlayback(for next: PlexMetadata) async -> ProviderPlayback? {
        guard case .provider(let playback) = source else { return nil }
        let generation = itemGeneration
        let key = next.ratingKey ?? ""
        let task: Task<ProviderPlayback?, Never>
        let preparationToken: Int
        if let pending = nextProviderPrepare, pending.key == key {
            task = pending.task
            preparationToken = pending.token
        } else if let item = providerEpisodeItems[key] {
            discardNextProviderPreparation()
            nextProviderPreparationToken += 1
            preparationToken = nextProviderPreparationToken
            let provider = playback.provider
            let version = upNextVersionChoice()
            let quality = sessionQuality
            let nativeQuality = siloManualQuality
            let throughput = lastThroughput
            task = Task {
                do {
                    return try await ProviderPlayback.prepare(item: item, provider: provider, version: version,
                                                              quality: quality, throughput: throughput,
                                                              nativeQuality: nativeQuality)
                } catch {
                    print("🎬 [PostVideo] Next provider episode failed to prepare: \(error)")
                    return nil
                }
            }
            nextProviderPrepare = (key, preparationToken, task)
        } else {
            showNextEpisodeError()
            return nil
        }
        let prepared = await task.value
        guard generation == itemGeneration, preparationToken == nextProviderPreparationToken else { return nil }
        if prepared == nil {
            if nextProviderPrepare?.key == key { nextProviderPrepare = nil }
            showNextEpisodeError()
        }
        return prepared
    }

    /// Stops the countdown and says why. The post-video page shows it; with
    /// no page up (a pick from the Up Next panel) it shows as a notice.
    private func showNextEpisodeError() {
        let message = playQueue == nil ? "Couldn't load the next episode." : "Couldn't load the next item."
        nextEpisodeError = message
        cancelCountdown()
        if postVideoState == .hidden { showCompatibilityNotice(message) }
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
        // A playlist pick goes by position, through `playQueueEntry(at:)`.
        guard playQueue == nil, episode.ratingKey != metadata.ratingKey else { return }
        // Any in-flight preload was for the previously-resolved `nextEpisode`,
        // not this target — discard it so playNextEpisode() doesn't splice in
        // the wrong episode's metadata/stream URL.
        preloadedNextMetadata = nil
        preloadedNextStreamURL = nil
        preloadedNextStreamHeaders = [:]
        nextEpisode = episode
        await playNextEpisode()
    }

    /// Plays the playlist entry at `index`, by position, so a repeated title still plays.
    func playQueueEntry(at index: Int) async {
        guard let playQueue, playQueue.entries.indices.contains(index), index != playQueue.index else { return }
        preloadedNextMetadata = nil
        preloadedNextStreamURL = nil
        preloadedNextStreamHeaders = [:]
        nextEpisode = ProviderPlaybackMetadata.listing(item: playQueue.entries[index].item)
        await playNextEpisode(queueIndex: index)
    }

    /// Play the next episode. `autoplayed` is the countdown running out; any
    /// other start comes from the remote and begins a new run.
    /// `queueIndex` is a playlist jump; nil moves a playlist on by one.
    func playNextEpisode(autoplayed: Bool = false, queueIndex: Int? = nil) async {
        guard let next = nextEpisode else { return }
        // A provider swap awaits its provider first, so a second call (the
        // countdown and a Play Now press) must not start another one.
        if case .provider = source, isSwappingItem { return }
        if playQueue != nil, isSwappingItem { return }

        // Everything below runs while the OUTGOING episode is still playing.
        // See `isSwappingItem`.
        isSwappingItem = true
        defer { isSwappingItem = false }

        // Legacy providers prepare before teardown. A native planner reserves
        // admission during resolve, so its old session must close before handoff.
        var nextProviderPlayback: ProviderPlayback?
        let transitionStops = stopCount
        // Plex playlist target's metadata, held locally: a preload for another entry can land at any await.
        var queuePlexMetadata: PlexMetadata?
        if case .provider(let playback) = source {
            nextEpisodeError = nil
            let stops = stopCount
            if playback.provider.reservesPlaybackOnResolve {
                activePlayer_pause()
                await stopProviderReporter(at: currentTime)
                guard stops == stopCount else { return }
            }
            guard let prepared = await preparedNextProviderPlayback(for: next) else { return }
            // The player was closed while the provider answered.
            guard stops == stopCount else { return }
            nextProviderPlayback = prepared
            nextProviderPrepare = nil
        } else if playQueue != nil, let key = next.ratingKey {
            if let preloaded = preloadedNextMetadata, preloaded.ratingKey == key, preloaded.Media?.isEmpty == false {
                queuePlexMetadata = preloaded
            } else {
                let stops = stopCount
                let fetched = try? await plexMetadataFetch(serverURL, authToken, key)
                guard stops == stopCount else { return }
                guard let fetched, fetched.Media?.isEmpty == false else { return showNextEpisodeError() }
                queuePlexMetadata = fetched
            }
        }

        // A step-down or track reload for the outgoing episode must not land on the next one.
        streamWorkTask?.cancel()
        longStallTask?.cancel()
        longStallTask = nil

        // A playlist pick before the credits leaves the item resumable: stopped at the playhead, not watched.
        let reachedEnd = queueIndex == nil || hasTriggeredPostVideo || postVideoState != .hidden
        if reachedEnd {
            await markCurrentAsWatched()
        } else if case .plex = source, let ratingKey = metadata.ratingKey, !ratingKey.isEmpty {
            await PlexProgressReporter.shared.reportProgress(
                ratingKey: ratingKey, time: currentTime, duration: duration,
                state: "stopped", forceReport: true, server: plexServer)
        }
        // The outgoing item's play session ends here.
        if case .provider = source {
            await stopProviderReporter(at: currentTime)
        }
        guard transitionStops == stopCount else {
            if let prepared = nextProviderPlayback {
                await ProviderPlayback.discardUnplayedStream(prepared.stream, provider: prepared.provider)
            }
            return
        }

        // Stop countdown and reset all countdown state
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownSeconds = 0
        isCountdownPaused = false
        episodesInARow = autoplayed ? episodesInARow + 1 : 1

        postVideoState = .hidden

        if let nextProviderPlayback {
            // Source, display shim and reporter move together; the outgoing
            // reporter was stopped above.
            metadata = ProviderPlaybackMetadata.make(
                detail: nextProviderPlayback.detail,
                source: nextProviderPlayback.stream.source,
                extras: nextProviderPlayback.extras
            )
            setProviderStream(nextProviderPlayback)
        } else {
            // Preloaded metadata has markers. Choose before the swap: the choice may read the outgoing file.
            let version = upNextVersionChoice()
            metadata = queuePlexMetadata ?? preloadedNextMetadata ?? next
            playingMediaID = nil
            playingMediaServerIndex = 0
            baseVersionChoice = version
            applyVersion(version, to: metadata.Media)
        }
        duration = Self.metadataDuration(metadata)
        // metadata isn't @Published (its ratingKey is the only identity
        // signal), so bump this explicitly for anything that caches
        // per-item state and needs to reset across the swap.
        itemGeneration += 1
        resetSiloSubtitleActions()
        // An Off picked on the last title does not carry over (#432).
        subtitlesPickedOff = false
        if let queueIndex { playQueue?.jump(to: queueIndex) } else { playQueue?.advance() }
        providerTargetSourceID = nil
        // Work queued for the outgoing item never runs, so nothing else clears this.
        trackReloadQueued = false
        pendingTrackReload = nil
        // Nothing has played on the new item yet, so nothing can have ended.
        currentItemHasStarted = false
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
        // Release the outgoing episode's BIF; preloadThumbnails() loads the new
        // one. Without this a binge retains every episode's trickplay frames.
        releaseThumbnailCache()

        // Re-resolve the title logo for the new episode.
        fetchTitleLogoIfNeeded()

        // A series episode starts at 0; a playlist entry at its own resume point.
        startOffset = playQueue == nil ? nil : ProviderPlayer.plexStartOffset(metadata, fromBeginning: false)

        // Reset skip tracking for new episode — but keep hasTriggeredPostVideo = true
        // until after startPlayback() completes. The old time observer can emit stale
        // time values (from the previous episode's position) during the async transition.
        // If hasTriggeredPostVideo were false, checkMarkers could immediately re-trigger
        // post-video using the stale time against the new episode's credits markers.
        hasSkippedIntro = false
        skippedCreditsIds.removeAll()
        skippedCommercialIds.removeAll()
        skippedRecapIds.removeAll()

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
        upNextEpisodesLoaded = false

        // Ensure next episode has required metadata for subsequent next-up detection
        if metadata.parentRatingKey == nil || metadata.index == nil {
            await fetchFullMetadataIfNeeded()
        }

        // New metadata requires a fresh route/URL plan unless a preloaded URL is provided.
        resetPreparedStreamContext()
        // Stopped only once the new item has replaced it, so the old item never fails mid-swap.
        let outgoingTranscode = plexSessionId
        plexSessionId = nil

        // Use preloaded stream URL if available, otherwise prepare fresh
        // The warmed URL is written with its metadata, so a matching key means it is this item's file.
        if let preloadedURL = preloadedNextStreamURL, nextEpisodePlaysOriginal,
           preloadedNextMetadata?.ratingKey == metadata.ratingKey {
            streamURL = preloadedURL
            streamHeaders = preloadedNextStreamHeaders
            qualityChoice = .original
            activeStreamPlan = .original
            stallTracker = StallTracker()
        } else {
            await ensureStreamURLPrepared()
        }

        // Clear preloaded data
        clearPreloadedData()

        // The swap reuses this AetherPlayer, so the engine replaces the item on
        // a layer that is already on screen. Without this the outgoing item is
        // detached before the incoming one is ready and the viewer sees a black
        // frame between episodes. The request is consumed by the load inside
        // startPlayback().
        aetherPlayer?.prepareForItemReplacement()

        // Start playback — new time observer starts with time ≈ 0 after this returns
        await startPlayback()
        if let outgoingTranscode { stopTranscode(sessionId: outgoingTranscode) }

        // Safe to allow post-video detection now: the old time observer has been
        // replaced and time values reflect the new episode's actual position.
        hasTriggeredPostVideo = false
        // Arm the end funnel here: stale events from the outgoing episode are
        // already dropped, and a `.playing` lost in the swap window would leave it off.
        currentItemHasStarted = true
    }

    /// Dismiss post-video overlay and return to fullscreen video
    /// Note: Does NOT reset hasTriggeredPostVideo - that prevents re-triggering while still in the credits.
    /// The flag is only reset when seeking backwards past the trigger point or starting new content.
    func dismissPostVideo() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        postVideoState = .hidden
        nextEpisode = nil
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

    /// Periodic progress, throttled to `reportingInterval` unless `force`.
    func reportPlaybackProgress(time: TimeInterval, force: Bool) {
        // Report every 10 seconds
        guard force || abs(time - lastReportedTime) >= reportingInterval else { return }
        lastReportedTime = time

        if case .provider = source {
            guard providerReporterStarted, let reporter = providerReporter else { return }
            enqueueProviderReport { await reporter.progress(position: time) }
            return
        }

        sendTimeline(time: time, state: isPlaying ? "playing" : "paused", force: false)
    }

    /// One Plex timeline; ends playback if the reply says the server ended the session.
    private func sendTimeline(time: TimeInterval, state: String, force: Bool) {
        let stops = stopCount
        Task {
            let terminated = await PlexProgressReporter.shared.reportProgress(
                ratingKey: self.metadata.ratingKey ?? "",
                time: time,
                duration: self.duration,
                state: state,
                forceReport: force,
                server: plexServer
            )
            guard let terminated, stops == self.stopCount else { return }
            self.endForServerTermination(terminated)
        }
    }

    /// The server stopped this stream (dashboard Stop, paused too long): stop and show its reason (#403).
    private func endForServerTermination(_ reason: String) {
        if case .failed = playbackState { return }
        DiagLog.notice(.playback, "Plex server terminated the session")
        stopPlayback()
        errorMessage = reason
        updatePlaybackState(.failed(.serverTerminated(reason)))
    }

    /// Report a playback state change immediately.
    func reportPlaybackState(_ newState: UniversalPlaybackState) {
        if case .provider = source {
            reportProviderState(newState)
            return
        }

        // Only report significant state changes
        let plexState: String?
        switch newState {
        case .playing:
            plexState = "playing"
        case .paused:
            plexState = "paused"
        case .ended:
            plexState = "stopped"
        default:
            plexState = nil
        }

        pausedTimelineTask?.cancel()
        pausedTimelineTask = nil
        guard let state = plexState else { return }

        sendTimeline(time: currentTime, state: state, force: true)
        if state == "paused" {
            let interval = reportingInterval
            pausedTimelineTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard let self, !Task.isCancelled else { return }
                    self.sendTimeline(time: self.currentTime, state: "paused", force: true)
                }
            }
        }
    }

    /// Final report when the player goes away: stopped, watched past 90%,
    /// then a refresh so the surfaces repaint.
    func reportFinalProgress() async {
        await reportFinalProgress(time: currentTime, duration: duration)
    }

    func reportFinalProgress(time: TimeInterval, duration: TimeInterval) async {
        if case .provider(let playback) = source {
            await stopProviderReporter(at: time)
            if duration > 0 && time / duration > 0.9 {
                try? await playback.provider.markPlayed(playback.item.ref)
            }
            NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
            return
        }

        // 1. Report stopped state to Plex
        await PlexProgressReporter.shared.reportProgress(
            ratingKey: metadata.ratingKey ?? "",
            time: time,
            duration: duration,
            state: "stopped",
            forceReport: true,
            server: plexServer
        )

        // 2. Mark as watched if > 90% complete
        if duration > 0 && time / duration > 0.9 {
            await PlexProgressReporter.shared.markAsWatched(
                ratingKey: metadata.ratingKey ?? "",
                server: plexServer
            )
        }

        // 3. Wait for Plex server to process (2 seconds)
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // 4. Trigger refresh after progress is confirmed
        NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
    }

    private func reportProviderState(_ newState: UniversalPlaybackState) {
        guard let reporter = providerReporter else { return }
        let position = providerReporterStarted ? currentTime : providerInitialPosition ?? currentTime
        switch newState {
        case .playing:
            if providerReporterStarted {
                enqueueProviderReport { await reporter.progress(position: position) }
            } else {
                providerReporterStarted = true
                providerInitialPosition = nil
                enqueueProviderReport { await reporter.start(position: position) }
            }
        case .paused:
            guard providerReporterStarted else { return }
            enqueueProviderReport { await reporter.paused(at: position) }
        case .ended:
            Task { await self.stopProviderReporter(at: position) }
        default:
            break
        }
    }

    /// Retire the current session once. Unplayed native plans omit the final
    /// position sample so cancellation cannot reset an existing resume point.
    private func stopProviderReporter(at position: TimeInterval) async {
        guard let reporter = providerReporter else {
            await providerReportTail?.value
            return
        }
        let started = providerReporterStarted
        let playback: ProviderPlayback?
        if case .provider(let current) = source { playback = current } else { playback = nil }
        providerReporter = nil
        providerReporterStarted = false
        providerInitialPosition = nil
        if !started, let playback {
            await enqueueProviderReport {
                do {
                    if try await playback.provider.discardStream(playback.stream) { return }
                } catch {
                    DiagLog.error(.playback, "Unplayed provider session cleanup failed: \(DiagLog.describe(error))")
                    return
                }
                await reporter.stopped(at: position)
            }.value
            return
        }
        await enqueueProviderReport { await reporter.stopped(at: position) }.value
    }

    @discardableResult
    private func enqueueProviderReport(_ report: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = providerReportTail
        let task = Task {
            await previous?.value
            await report()
        }
        providerReportTail = task
        return task
    }

    /// Mark current content as watched (for use before transitioning to next episode)
    func markCurrentAsWatched() async {
        // A provider session stays open: this runs at the credits while the
        // video keeps playing, and `stopped` would end the server session
        // (and a transcode) under it. `.ended`, exit and the swap stop it.
        if case .provider(let playback) = source {
            try? await playback.provider.markPlayed(playback.item.ref)
            NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
            return
        }
        guard let ratingKey = metadata.ratingKey, !ratingKey.isEmpty else { return }

        // Report stopped state
        await PlexProgressReporter.shared.reportProgress(
            ratingKey: ratingKey,
            time: currentTime,
            duration: duration,
            state: "stopped",
            server: plexServer
        )

        // Mark as watched (episode reached post-video, so it's effectively complete)
        await PlexProgressReporter.shared.markAsWatched(ratingKey: ratingKey, server: plexServer)
    }

    // MARK: - Cleanup

    deinit {
        // Clean up AVPlayer time observer (must happen synchronously in deinit)
        if let timeObserver = _timeObserverForCleanup, let player = _playerForCleanup {
            player.removeTimeObserver(timeObserver)
        }

        controlsTimer?.invalidate()
        scrubTimer?.invalidate()
        wheelScrubbingTimer?.invalidate()
        countdownTimer?.invalidate()
        seekIndicatorTimer?.invalidate()
        skipCountdownTimer?.invalidate()
        aetherStallWatchdogTask?.cancel()
        insightsRecheckTask?.cancel()
        siloSubtitleSyncTask?.cancel()
        siloSubtitleSyncMutation?.cancel()
        if let observer = appBackgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appBecameActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appResignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = itemDidPlayToEndObserver {
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
    /// Native account/profile authority changed; consumers discard work owned by a removed provider.
    static let mediaProviderAccountsChanged = Notification.Name("mediaProviderAccountsChanged")
    /// Posted when player requests navigation to a specific content item
    /// userInfo contains: "ratingKey" (String), "type" (String: "show", "season", "movie")
    static let navigateToContent = Notification.Name("navigateToContent")

    /// Posted when Plex data needs to be refreshed (e.g., after playback ends)
    /// Views showing Plex content should refresh their data when receiving this
    static let plexDataNeedsRefresh = Notification.Name("plexDataNeedsRefresh")

    /// Posted when video playback starts (pauses hub polling)
    static let plexPlaybackStarted = Notification.Name("plexPlaybackStarted")

    /// Posted when video playback stops (resumes hub polling)
    static let plexPlaybackStopped = Notification.Name("plexPlaybackStopped")
}
