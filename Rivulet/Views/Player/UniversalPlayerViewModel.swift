//
//  UniversalPlayerViewModel.swift
//  Rivulet
//
//  ViewModel managing playback state with RivuletPlayer
//

import SwiftUI
import Combine
import UIKit
import Sentry
import AVFoundation
import AVKit

// MARK: - Subtitle Preference

/// Stores user's subtitle preference for auto-selection
struct SubtitlePreference: Codable, Equatable {
    /// Whether subtitles are enabled
    var enabled: Bool
    /// Preferred language code (e.g., "en", "es")
    var languageCode: String?
    /// Preferred codec (e.g., "srt", "ass", "pgs")
    var codec: String?
    /// Whether to prefer hearing impaired tracks
    var preferHearingImpaired: Bool

    static let off = SubtitlePreference(enabled: false, languageCode: nil, codec: nil, preferHearingImpaired: false)

    init(enabled: Bool, languageCode: String?, codec: String?, preferHearingImpaired: Bool) {
        self.enabled = enabled
        self.languageCode = languageCode
        self.codec = codec
        self.preferHearingImpaired = preferHearingImpaired
    }

    /// Create preference from a selected track
    init(from track: MediaTrack) {
        self.enabled = true
        self.languageCode = track.languageCode
        self.codec = track.codec
        self.preferHearingImpaired = track.isHearingImpaired
    }
}

/// Manages subtitle preference persistence
enum SubtitlePreferenceManager {
    // Individual keys for each preference field (more robust than JSON)
    private static let enabledKey = "subtitlePreferenceEnabled"
    private static let languageKey = "subtitlePreferenceLanguage"
    private static let codecKey = "subtitlePreferenceCodec"
    private static let hearingImpairedKey = "subtitlePreferenceHearingImpaired"

    // Migration from old JSON format
    private static let migrationKey = "subtitlePreferenceMigrated"

    static var current: SubtitlePreference {
        get {
            // Migrate from old JSON format if needed
            if !UserDefaults.standard.bool(forKey: migrationKey) {
                UserDefaults.standard.set(true, forKey: migrationKey)
                if let data = UserDefaults.standard.data(forKey: "subtitlePreference"),
                   let oldPref = try? JSONDecoder().decode(SubtitlePreference.self, from: data) {
                    // Migrate old values to new format
                    UserDefaults.standard.set(oldPref.enabled, forKey: enabledKey)
                    UserDefaults.standard.set(oldPref.languageCode, forKey: languageKey)
                    UserDefaults.standard.set(oldPref.codec, forKey: codecKey)
                    UserDefaults.standard.set(oldPref.preferHearingImpaired, forKey: hearingImpairedKey)
                    UserDefaults.standard.removeObject(forKey: "subtitlePreference")
                }
            }

            // Read from individual keys
            let enabled = UserDefaults.standard.bool(forKey: enabledKey)
            let languageCode = UserDefaults.standard.string(forKey: languageKey)
            let codec = UserDefaults.standard.string(forKey: codecKey)
            let preferHearingImpaired = UserDefaults.standard.bool(forKey: hearingImpairedKey)

            return SubtitlePreference(
                enabled: enabled,
                languageCode: languageCode,
                codec: codec,
                preferHearingImpaired: preferHearingImpaired
            )
        }
        set {
            UserDefaults.standard.set(newValue.enabled, forKey: enabledKey)
            UserDefaults.standard.set(newValue.languageCode, forKey: languageKey)
            UserDefaults.standard.set(newValue.codec, forKey: codecKey)
            UserDefaults.standard.set(newValue.preferHearingImpaired, forKey: hearingImpairedKey)
        }
    }

    /// Whether user has explicitly set subtitle preferences.
    /// If false, playback should honor stream defaults/forced tracks.
    static var hasStoredPreference: Bool {
        UserDefaults.standard.object(forKey: enabledKey) != nil ||
        UserDefaults.standard.object(forKey: languageKey) != nil ||
        UserDefaults.standard.object(forKey: codecKey) != nil ||
        UserDefaults.standard.object(forKey: hearingImpairedKey) != nil ||
        UserDefaults.standard.object(forKey: "subtitlePreference") != nil
    }

    /// Find best matching subtitle track based on preference
    static func findBestMatch(in tracks: [MediaTrack], preference: SubtitlePreference) -> MediaTrack? {
        guard preference.enabled, let preferredLang = preference.languageCode else {
            return nil
        }

        // Filter tracks by language
        let langMatches = tracks.filter { $0.languageCode == preferredLang }
        guard !langMatches.isEmpty else {
            // No tracks match preferred language - keep subtitles off
            return nil
        }

        // Try to find exact codec match
        if let preferredCodec = preference.codec {
            if let exactMatch = langMatches.first(where: {
                $0.codec == preferredCodec && $0.isHearingImpaired == preference.preferHearingImpaired
            }) {
                return exactMatch
            }
            // Try codec match without hearing impaired preference
            if let codecMatch = langMatches.first(where: { $0.codec == preferredCodec }) {
                return codecMatch
            }
        }

        // Fall back to first track of preferred language with matching HI preference
        if let hiMatch = langMatches.first(where: { $0.isHearingImpaired == preference.preferHearingImpaired }) {
            return hiMatch
        }

        // Fall back to first track of preferred language
        return langMatches.first
    }
}

// MARK: - Audio Preference

/// Stores user's audio preference for auto-selection
struct AudioPreference: Codable, Equatable {
    /// Preferred language code (e.g., "en", "es"). Nil means default to English.
    var languageCode: String?

    static let defaultEnglish = AudioPreference(languageCode: "eng")

    /// Create preference from a selected track
    init(from track: MediaTrack) {
        self.languageCode = track.languageCode
    }

    init(languageCode: String?) {
        self.languageCode = languageCode
    }
}

/// Manages audio preference persistence
enum AudioPreferenceManager {
    private static let languageKey = "audioPreferenceLanguage"

    // Migration: try to read old JSON format once
    private static let migrationKey = "audioPreferenceMigrated"

    static var current: AudioPreference {
        get {
            // Migrate from old JSON format if needed
            if !UserDefaults.standard.bool(forKey: migrationKey) {
                UserDefaults.standard.set(true, forKey: migrationKey)
                if let data = UserDefaults.standard.data(forKey: "audioPreference"),
                   let oldPref = try? JSONDecoder().decode(AudioPreference.self, from: data) {
                    // Migrate old value to new format
                    UserDefaults.standard.set(oldPref.languageCode, forKey: languageKey)
                    UserDefaults.standard.removeObject(forKey: "audioPreference")
                }
            }

            // Read from simple string storage
            let languageCode = UserDefaults.standard.string(forKey: languageKey)
            return AudioPreference(languageCode: languageCode ?? "eng")
        }
        set {
            UserDefaults.standard.set(newValue.languageCode, forKey: languageKey)
        }
    }

    /// Find best matching audio track based on preference
    /// Returns the highest quality track in the preferred language, falling back to English
    static func findBestMatch(in tracks: [MediaTrack], preference: AudioPreference) -> MediaTrack? {
        guard !tracks.isEmpty else { return nil }

        // Helper to find best track by quality (most channels = better)
        func bestTrack(in candidates: [MediaTrack]) -> MediaTrack? {
            candidates.max { ($0.channels ?? 0) < ($1.channels ?? 0) }
        }

        // Try preferred language first
        if let preferredLang = preference.languageCode {
            let langMatches = tracks.filter {
                $0.languageCode?.lowercased() == preferredLang.lowercased()
            }
            if let best = bestTrack(in: langMatches) {
                return best
            }
        }

        // Fall back to English tracks
        let englishMatches = tracks.filter {
            let code = $0.languageCode?.lowercased()
            return code == "eng" || code == "en" || code == "english"
        }
        if let best = bestTrack(in: englishMatches) {
            return best
        }

        // No English either - return the first track (usually default)
        return tracks.first(where: { $0.isDefault }) ?? tracks.first
    }
}

// MARK: - Post-Video State

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

    @Published private(set) var playbackState: UniversalPlaybackState = .idle
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var errorMessage: String?

    @Published var showControls = true
    @Published var showInfoPanel = false
    @Published var isScrubbing = false
    @Published var showPausedPoster = false
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
    private var hasTriggeredPostVideo = false

    // MARK: - Intro Skip Countdown State
    /// Current countdown value (5...4...3...2...1), 0 means no countdown active
    @Published var introSkipCountdownSeconds: Int = 0
    private var introSkipCountdownTimer: Timer?
    private let introSkipDelaySeconds: Int = 5
    /// Tracks if user cancelled auto-skip for current intro (prevents restarting countdown)
    private var userDeclinedIntroAutoSkip = false
    @Published var scrubTime: TimeInterval = 0

    // MARK: - Post-Video State
    @Published var postVideoState: PostVideoState = .hidden
    @Published var videoFrameState: VideoFrameState = .fullscreen
    @Published private(set) var nextEpisode: PlexMetadata?
    @Published private(set) var recommendations: [PlexMetadata] = []
    @Published var countdownSeconds: Int = 0
    @Published var isCountdownPaused: Bool = false
    private var countdownTimer: Timer?
    @Published var scrubThumbnail: UIImage?
    @Published private(set) var scrubSpeed: Int = 0  // -1, 0, or 1 (direction only)
    private var scrubStartTime: Date?  // When scrubbing started (for YouTube-style acceleration)
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var currentAudioTrackId: Int?
    @Published private(set) var currentSubtitleTrackId: Int?
    private var compatibilityNoticeTimer: Timer?
    private nonisolated(unsafe) var userActivity: NSUserActivity?

    // MARK: - Playback Settings Panel State (Column-based layout)

    /// Which column is focused: 0 = Subtitles, 1 = Audio (Media Info is not focusable)
    @Published var focusedColumn: Int = 0

    /// Which row within the focused column
    @Published var focusedRowIndex: Int = 0

    /// Number of rows in a given column
    func rowCount(forColumn column: Int) -> Int {
        switch column {
        case 0: return 1 + subtitleTracks.count  // "Off" + subtitle tracks
        case 1: return max(1, audioTracks.count)  // Audio tracks (at least 1)
        default: return 0
        }
    }

    /// Check if a specific setting is focused
    func isSettingFocused(column: Int, index: Int) -> Bool {
        return focusedColumn == column && focusedRowIndex == index
    }

    /// Navigate within settings panel
    func navigateSettings(direction: MoveCommandDirection) {
        switch direction {
        case .up:
            if focusedRowIndex > 0 {
                focusedRowIndex -= 1
            }
        case .down:
            let maxIndex = rowCount(forColumn: focusedColumn) - 1
            if focusedRowIndex < maxIndex {
                focusedRowIndex += 1
            }
        case .left:
            if focusedColumn > 0 {
                focusedColumn -= 1
                // Clamp row index to new column's range
                focusedRowIndex = min(focusedRowIndex, rowCount(forColumn: focusedColumn) - 1)
            }
        case .right:
            if focusedColumn < 1 {  // Only 2 focusable columns (0 and 1)
                focusedColumn += 1
                // Clamp row index to new column's range
                focusedRowIndex = min(focusedRowIndex, rowCount(forColumn: focusedColumn) - 1)
            }
        @unknown default:
            break
        }
    }

    /// Select the currently focused setting
    func selectFocusedSetting() {
        switch focusedColumn {
        case 0:  // Subtitles
            if focusedRowIndex == 0 {
                selectSubtitleTrack(id: nil)
            } else {
                let trackIndex = focusedRowIndex - 1
                if trackIndex < subtitleTracks.count {
                    selectSubtitleTrack(id: subtitleTracks[trackIndex].id)
                }
            }
        case 1:  // Audio
            if focusedRowIndex < audioTracks.count {
                selectAudioTrack(id: audioTracks[focusedRowIndex].id)
            }
        default:
            break
        }
    }

    // MARK: - Player Instance

    /// AVPlayer used for all playback paths (direct, remuxed HLS, Plex HLS)
    @Published private(set) var player: AVPlayer?

    /// Local remux server for MKV/DTS/DV content
    private var remuxServer: LocalRemuxServer?
    private var remuxSession: FFmpegRemuxSession?

    /// HLS manifest enricher — injects audio/subtitle track labels into the master playlist.
    /// Must be retained for the lifetime of the AVURLAsset.
    private var hlsManifestEnricher: HLSManifestEnricher?

    /// KVO observers
    private var rateObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var keepUpObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    // Non-isolated reference for cleanup in deinit
    private nonisolated(unsafe) var _playerForCleanup: AVPlayer?
    private nonisolated(unsafe) var _timeObserverForCleanup: Any?

    /// Whether DV profile conversion (P7/P8.6 → P8.1) is needed
    private var requiresProfileConversion = false

    /// Custom player using FFmpeg demux + AVSampleBufferDisplayLayer.
    /// Created when "Use Apple's Player" is off; nil when using AVPlayerViewController.
    private(set) var rivuletPlayer: RivuletPlayer?

    /// Subtitle manager for custom subtitle rendering.
    let subtitleManager = SubtitleManager()
    private let subtitleClockSync = SubtitleClockSyncController()

    // MARK: - Metadata

    private(set) var metadata: PlexMetadata
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
    private var appBecameActiveObserver: Any?
    private var appBackgroundObserver: Any?
    private var pausedDueToAppInactive: Bool = false
    private let scrubUpdateInterval: TimeInterval = 0.1  // 100ms updates for smooth scrubbing
    private var seekIndicatorTimer: Timer?
    private var pausedPosterTimer: Timer?
    private let pausedPosterDelay: TimeInterval = 5.0

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
        case auto              // No preselection — fall through to SubtitlePreferenceManager.
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

        // Identify DV stream (could be second video track in dual-layer profile 7)
        let videoStreams = metadata.Media?.first?.Part?.first?.Stream?.filter { $0.isVideo } ?? []
        let dvStream = videoStreams.first { ($0.DOVIProfile != nil) || ($0.DOVIPresent == true) }

        let dvProfile = dvStream?.DOVIProfile
        let doviBLCompatID = dvStream?.DOVIBLCompatID
        let requiresDVProfileConversion = hasDolbyVision &&
            ((dvProfile == 7) || (dvProfile == 8 && doviBLCompatID == 6))

        print("[PlayerSelect] settings: rivulet=true avDV=false avAll=false " +
              "content: DV=\(hasDolbyVision) profile=\(dvProfile ?? -1) blCompat=\(doviBLCompatID ?? -1) " +
              "container=\(container) airPlay=\(isAirPlayRoute) compatDV=\(!requiresDVProfileConversion)")

        self.requiresProfileConversion = requiresDVProfileConversion

        print("[PlayerSelect] → AVPlayer (primary)")

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
            if self.playbackState == .playing {
                self.pausedDueToAppInactive = true
                print("[Remux] App entering background — pausing")
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

        guard let ratingKey = metadata.ratingKey else { return }
        let cachedDirectPlay = StreamURLCache.shared.get(ratingKey: ratingKey)

        // Fetch full metadata if Media array is missing (needed for info overlay display)
        // This happens when starting playback from Continue Watching or other hubs with minimal metadata
        if metadata.Media == nil || metadata.Media?.isEmpty == true {
            await fetchFullMetadataIfNeeded()
        }

        let useApplePlayer = UserDefaults.standard.bool(forKey: "useApplePlayer")
        let routingContext = ContentRoutingContext(
            metadata: metadata,
            serverURL: URL(string: serverURL)!,
            authToken: authToken,
            requiresProfileConversion: requiresProfileConversion,
            playbackPolicy: .directPlayFirst,
            useLocalRemux: !useApplePlayer  // RivuletPlayer handles locally
        )
        let plan = ContentRouter.plan(for: routingContext)
        playbackPlan = plan
        rivuletFallbackURL = nil
        rivuletFallbackHeaders = [:]

        switch plan.primary {
        case .avPlayerDirect(let url, let headers):
            // AVPlayer direct — use the URL from the plan
            if let cached = cachedDirectPlay {
                streamURL = cached.url
                streamHeaders = cached.headers
                StreamURLCache.shared.remove(ratingKey: ratingKey)
                Task(priority: .utility) {
                    await networkManager.warmDirectPlayStream(url: cached.url, headers: cached.headers)
                }
            } else {
                streamURL = url
                streamHeaders = headers ?? rivuletDirectPlayHeaders()
                Task(priority: .utility) {
                    await networkManager.warmDirectPlayStream(url: url, headers: headers ?? [:])
                }
            }

            if plan.fallbacks.contains(where: { if case .hls = $0 { return true } else { return false } }),
               let preparedFallback = buildRivuletHLSURL(offset: startOffset) {
                rivuletFallbackURL = preparedFallback.url
                rivuletFallbackHeaders = preparedFallback.headers
            }

        case .localRemux(let url, let headers, _):
            // Local remux — use the raw file URL from the plan
            streamURL = url
            streamHeaders = headers ?? rivuletDirectPlayHeaders()

            if plan.fallbacks.contains(where: { if case .hls = $0 { return true } else { return false } }),
               let preparedFallback = buildRivuletHLSURL(offset: startOffset) {
                rivuletFallbackURL = preparedFallback.url
                rivuletFallbackHeaders = preparedFallback.headers
            }

        case .hls:
            if let result = buildRivuletHLSURL(offset: startOffset) {
                streamURL = result.url
                streamHeaders = result.headers
                plexSessionId = result.sessionId
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
                    print("[Remux] rate→0 (was playing) at \(time)s bufEmpty=\(bufEmpty) keepUp=\(keepUp) tcs=\(player.timeControlStatus.rawValue) loadedTo=\(loadedEnd)s")
                    self.updatePlaybackState(.paused)

                    // With automaticallyWaitsToMinimizeStalling=false, AVPlayer pauses
                    // on buffer underruns. Auto-resume after a short delay if buffer
                    // has data. The keepUp KVO can't help here because keepUp stays
                    // false while paused (chicken-and-egg).
                    if self.remuxServer != nil {
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            guard let self,
                                  self.remuxServer != nil,
                                  self.player?.rate == 0,
                                  self.player?.currentItem?.isPlaybackBufferEmpty == false,
                                  self.playbackState == .paused else { return }
                            print("[Remux] Auto-resuming after buffer underrun (500ms delay)")
                            self.player?.play()
                        }
                    }
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
                        print("[Remux] AVPlayer: waitingToPlay (reason=\(reason), rate=\(player.rate))")
                    }
                    self.updatePlaybackState(.buffering)
                case .playing:
                    print("[Remux] AVPlayer: playing (rate=\(player.rate))")
                    if self.playbackState == .buffering {
                        self.updatePlaybackState(.playing)
                    }
                case .paused:
                    print("[Remux] AVPlayer: paused (rate=\(player.rate))")
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

        // Buffer recovery for local remux. With automaticallyWaitsToMinimizeStalling=false,
        // AVPlayer pauses (rate=0) on buffer underruns instead of waiting. We detect when
        // the buffer refills and resume playback ourselves.
        if let item = player.currentItem {
            keepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.remuxServer != nil else { return }
                    if item.isPlaybackLikelyToKeepUp,
                       self.player?.rate == 0,
                       self.player?.currentItem?.status == .readyToPlay,
                       self.playbackState == .paused || self.playbackState == .buffering {
                        print("[Remux] Buffer recovered (keepUp=true), resuming playback")
                        self.player?.play()
                    }
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
        keepUpObservation?.invalidate()
        keepUpObservation = nil
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
        if let rp = rivuletPlayer {
            return rp.isPlaying
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

        let useApplePlayer = UserDefaults.standard.bool(forKey: "useApplePlayer")
        // RivuletPlayer's pipeline is direct-play / progressive-file
        // only — its loadHLS only works as a fallback against a
        // pre-built transcode URL stored on `streamURL`, and the
        // ContentRouter `.hls(url:)` route carries just the server
        // base. When the source video codec has no Apple TV decoder
        // (e.g. MPEG-2, VC-1) we must transcode, and only the
        // AVPlayer path consumes the resulting HLS stream end-to-end.
        let mustUseAVPlayer = ContentRouter.requiresVideoTranscode(metadata: metadata)

        if !useApplePlayer && !mustUseAVPlayer {
            await startRivuletPlayback()
        } else {
            await startAVPlayerPlayback()
        }
    }

    // MARK: - RivuletPlayer Startup

    private func startRivuletPlayback() async {
        // Fetch full metadata if Media array is missing
        if metadata.Media == nil || metadata.Media?.isEmpty == true {
            await fetchFullMetadataIfNeeded()
        }

        addPlaybackSelectionBreadcrumb(reason: "startRivuletPlayback")

        do {
            DisplayCriteriaManager.shared.configureForContent(
                videoStream: metadata.primaryVideoStream
            )

            let routingContext = ContentRoutingContext(
                metadata: metadata,
                serverURL: URL(string: serverURL)!,
                authToken: authToken,
                requiresProfileConversion: requiresProfileConversion,
                playbackPolicy: .directPlayFirst,
                useLocalRemux: true  // RivuletPlayer always handles locally
            )
            let plan = ContentRouter.plan(for: routingContext)
            playbackPlan = plan

            // Reuse existing RivuletPlayer when transitioning episodes so the
            // AVSampleBufferDisplayLayer stays in the view hierarchy. Creating a
            // new player orphans the old display layer (still showing credits)
            // while the new one is never attached — causing stale video on screen.
            let isReuse = rivuletPlayer != nil
            let rp = rivuletPlayer ?? RivuletPlayer()
            self.rivuletPlayer = rp

            // Wire up subtitle callbacks
            rp.onSubtitleCue = { [weak self] text, start, end in
                self?.subtitleManager.addCue(text: text, startTime: start, endTime: end)
            }
            rp.onBitmapSubtitleCue = { [weak self] cue in
                self?.subtitleManager.addBitmapCue(cue)
            }

            // Clear stale subtitle cues from previous episode
            subtitleManager.clear()

            try await rp.load(route: plan.primary, startTime: startOffset)
            rp.play()

            playbackState = .playing
            self.duration = rp.duration

            // Only subscribe to publishers on first creation — reuse keeps
            // existing subscriptions which continue to receive new events.
            if !isReuse {
                rp.playbackStatePublisher
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] state in
                        self?.handleRivuletStateChange(state)
                    }
                    .store(in: &cancellables)

                rp.timePublisher
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] time in
                        self?.currentTime = time
                        self?.checkMarkers(at: time)
                    }
                    .store(in: &cancellables)

                rp.errorPublisher
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] error in
                        self?.errorMessage = error.userFacingDescription
                        self?.playbackState = .failed(.loadFailed(error.localizedDescription))
                    }
                    .store(in: &cancellables)
            }

            updateTrackLists()
            preloadThumbnails()
            startControlsHideTimer()
            configureSubtitleClockSyncForCurrentPlayer()

            // Index for Siri Suggestions
            let activity = NSUserActivity(activityType: "com.rivulet.playMedia")
            activity.title = metadata.title
            activity.isEligibleForSearch = true
            activity.userInfo = ["ratingKey": metadata.ratingKey ?? ""]
            activity.targetContentIdentifier = "rivulet://play?ratingKey=\(metadata.ratingKey ?? "")"
            self.userActivity = activity
            activity.becomeCurrent()
        } catch {
            let technicalError = error.localizedDescription
            if let playerError = error as? PlayerError {
                errorMessage = playerError.userFacingDescription
            } else {
                errorMessage = "Something went wrong during playback. Please try again."
            }
            playbackState = .failed(.loadFailed(technicalError))

            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "playback", key: "component")
                scope.setTag(value: "rivulet", key: "player_type")
                scope.setExtra(value: self.metadata.title ?? "unknown", key: "media_title")
                scope.setExtra(value: self.metadata.type ?? "unknown", key: "media_type")
                scope.setExtra(value: self.metadata.ratingKey ?? "unknown", key: "rating_key")
                scope.setExtra(value: self.startOffset ?? 0, key: "start_offset")
            }
        }
    }

    private func handleRivuletStateChange(_ state: UniversalPlaybackState) {
        switch state {
        case .playing:
            playbackState = .playing
        case .paused:
            playbackState = .paused
        case .buffering:
            playbackState = .buffering
        case .ended:
            playbackState = .ended
        case .failed:
            // Error details come through errorPublisher
            break
        default:
            break
        }
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
            DisplayCriteriaManager.shared.configureForContent(
                videoStream: metadata.primaryVideoStream
            )

            let plan = playbackPlan ?? ContentRouter.plan(for: ContentRoutingContext(
                metadata: metadata,
                serverURL: URL(string: serverURL)!,
                authToken: authToken,
                requiresProfileConversion: requiresProfileConversion,
                playbackPolicy: .directPlayFirst,
                useLocalRemux: false
            ))
            try await startWithFallback(plan: plan, startTime: startOffset)

            let itemStatus = player?.currentItem?.status.rawValue ?? -1
            let bufferEmpty = player?.currentItem?.isPlaybackBufferEmpty ?? true
            let bufferFull = player?.currentItem?.isPlaybackBufferFull ?? false
            let likelyKeepUp = player?.currentItem?.isPlaybackLikelyToKeepUp ?? false
            print("[Remux] play() — status=\(itemStatus) bufferEmpty=\(bufferEmpty) bufferFull=\(bufferFull) likelyKeepUp=\(likelyKeepUp)")
            if remuxServer != nil {
                player?.playImmediately(atRate: 1.0)
            } else {
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

            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "playback", key: "component")
                scope.setTag(value: "avplayer", key: "player_type")
                scope.setExtra(value: url.absoluteString, key: "stream_url")
                scope.setExtra(value: self.metadata.title ?? "unknown", key: "media_title")
                scope.setExtra(value: self.metadata.type ?? "unknown", key: "media_type")
                scope.setExtra(value: self.metadata.ratingKey ?? "unknown", key: "rating_key")
                scope.setExtra(value: self.startOffset ?? 0, key: "start_offset")
            }
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
            print("[Remux] waitReady: no currentItem")
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
                    print("[Remux] waitReady: readyToPlay")
                    resume(with: true)
                case .failed:
                    print("[Remux] waitReady: FAILED — \(item.error?.localizedDescription ?? "unknown")")
                    resume(with: false)
                default:
                    break
                }
            }

            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                let s = item.status.rawValue
                print("[Remux] waitReady: TIMEOUT after \(Int(timeout))s — status=\(s) bufEmpty=\(item.isPlaybackBufferEmpty) keepUp=\(item.isPlaybackLikelyToKeepUp)")
                resume(with: false)
            }
        }
    }

    /// Load content using the appropriate path from the playback plan.
    ///
    /// Three paths:
    /// 1. **AVPlayer direct** — AVPlayer opens Plex URL directly (MP4/MOV + native audio)
    /// 2. **Local remux** — FFmpegRemuxSession → LocalRemuxServer → AVPlayer (MKV, DTS, DV P7)
    /// 3. **Plex HLS** — AVPlayer opens Plex HLS URL
    private func startWithFallback(plan: PlaybackPlan, startTime: TimeInterval?) async throws {
        switch plan.primary {
        case .avPlayerDirect(let url, let headers):
            let directURL = streamURL ?? url
            let directHeaders = streamHeaders.isEmpty ? (headers ?? rivuletDirectPlayHeaders()) : streamHeaders
            do {
                try loadAVPlayer(url: directURL, headers: directHeaders)
            } catch {
                guard planHasHLSFallback(plan) else { throw error }
                let kind = classifyDirectPlayFailure(error)
                try await attemptRivuletHLSFallback(
                    resumeTime: startTime ?? 0,
                    reason: "direct_startup_load_failed",
                    failureKind: kind
                )
                return
            }

            if let startTime, startTime > 0 {
                await player?.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
            }

        case .localRemux(let url, let headers, _):
            let remuxURL = streamURL ?? url
            let remuxHeaders = streamHeaders.isEmpty ? (headers ?? rivuletDirectPlayHeaders()) : streamHeaders
            do {
                let remuxStart = Date()
                // Prefetch init + target segment, then use EXT-X-START so AVPlayer
                // goes directly to the resume position. All data is instant cache hits.
                try await loadWithRemuxServer(sourceURL: remuxURL, headers: remuxHeaders, startTime: startTime)
                let becameReady = await waitForCurrentItemReady(timeout: 8.0)
                let readyMs = Int(Date().timeIntervalSince(remuxStart) * 1000)
                if !becameReady {
                    print("[Remux] TIMEOUT: not ready after \(readyMs)ms")
                    throw PlayerError.loadFailed("Local remux did not become ready in time")
                }
                print("[Remux] Ready in \(readyMs)ms")
            } catch {
                guard planHasHLSFallback(plan) else { throw error }
                let kind = classifyDirectPlayFailure(error)
                try await attemptRivuletHLSFallback(
                    resumeTime: startTime ?? 0,
                    reason: "local_remux_startup_failed",
                    failureKind: kind
                )
                return
            }

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
                throw PlayerError.loadFailed("HLS transcode session failed to start")
            }

            // Log the HLS master manifest for debugging track labels and I-frame playlists
            await logHLSManifest(url: hlsURL, headers: streamHeaders)

            try loadAVPlayer(url: hlsURL, headers: streamHeaders)

            if let startTime, startTime > 0 {
                await player?.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
            }
        }
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

        // Year
        if let year = metadata.year {
            items.append(makeMetadataItem(
                .commonIdentifierCreationDate,
                value: String(year)
            ))
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

    /// Fetch chapter thumbnail images from Plex in parallel.
    private func fetchChapterThumbnails(chapters: [PlexChapter]) async {
        let thumbCount = chapters.filter { $0.thumb != nil }.count
        print("[Chapters] Fetching \(thumbCount) chapter thumbnails...")

        await withTaskGroup(of: (Int, Data?).self) { group in
            for chapter in chapters {
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
            }

            for await (index, data) in group {
                if let data {
                    chapterThumbnails[index] = data
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

    /// Create remux session + local server, then point AVPlayer at localhost HLS.
    private func loadWithRemuxServer(sourceURL: URL, headers: [String: String]?, startTime: TimeInterval? = nil) async throws {
        // Stop previous remux infrastructure
        await stopRemuxServer()

        let session = FFmpegRemuxSession()
        self.remuxSession = session

        let sessionInfo = try await session.open(url: sourceURL, headers: headers)
        guard !sessionInfo.segments.isEmpty else {
            throw PlayerError.loadFailed("No remux segments available")
        }

        // Pre-generate init + the first segment AVPlayer will request so it gets
        // instant cache hits (Content-Length). With a start time, prefetch the target
        // segment and use EXT-X-START so AVPlayer goes directly there.
        let prefetchStart = Date()
        let initData = try await session.generateInitSegment()
        let targetSegIdx = startTime.map { max(0, Int($0 / sessionInfo.segments.first!.duration)) } ?? 0
        let clampedIdx = min(targetSegIdx, sessionInfo.segments.count - 1)
        let segData = try await session.generateSegment(index: clampedIdx)
        let prefetchDuration = await session.lastSegmentActualDuration
        let prefetchMs = Int(Date().timeIntervalSince(prefetchStart) * 1000)
        print("[Remux] Prefetch: init + segment \(clampedIdx) in \(prefetchMs)ms (actualDur=\(String(format: "%.3f", prefetchDuration ?? 0))s)")

        let server = LocalRemuxServer(
            session: session,
            sessionInfo: sessionInfo,
            prebuiltInitSegment: initData,
            prebuiltSegments: [clampedIdx: segData]
        )
        // Record the prefetched segment's actual duration
        if let dur = prefetchDuration {
            server.recordSegmentDuration(index: clampedIdx, duration: dur)
        }
        if let startTime, startTime > 0 {
            server.startOffset = startTime
        }
        self.remuxServer = server

        let localURL = try server.start()
        print("[Remux] Server started: \(localURL), segments=\(sessionInfo.segments.count), target=seg\(clampedIdx)")

        try loadAVPlayer(url: localURL, headers: nil)

        // Disable AVPlayer's stall minimization — it deadlocks on locally-generated
        // HLS because it can't evaluate the "network" throughput correctly.
        // We handle buffer recovery ourselves via isPlaybackLikelyToKeepUp KVO.
        player?.automaticallyWaitsToMinimizeStalling = false

        // If the keyframe index wasn't available at open time (HTTP source),
        // load it in the background. This triggers a seek to the MKV file tail
        // to read the Cue index, then rebuilds the segment list with accurate
        // durations. The server's playlist will reflect actual durations on
        // AVPlayer's next re-fetch.
        player?.currentItem?.preferredForwardBufferDuration = 6.0
    }

    /// Stop remux server and session.
    private func stopRemuxServer() async {
        remuxServer?.stop()
        remuxServer = nil
        if let session = remuxSession {
            // Abort in-progress FFmpeg I/O immediately so the actor becomes
            // available for cancel/close without waiting for generation to finish.
            session.interruptFlag.pointee = 1
            await session.cancel()
            await session.close()
        }
        remuxSession = nil
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

        // Stop current player
        teardownAVPlayerObservers()
        player?.pause()
        await stopRemuxServer()

        streamURL = fallback.url
        streamHeaders = fallback.headers
        plexSessionId = fallback.sessionId

        let transcodeReady = await waitForHLSTranscodeReady(url: fallback.url, headers: fallback.headers)
        if !transcodeReady {
            throw PlayerError.loadFailed("HLS transcode session failed to start")
        }

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
                                    return true
                                } else {
                                }
                            } else if hasHeader && hasSegments {
                                // This is already a media playlist with segments
                                return true
                            } else if hasHeader {
                                // Has header but no content yet
                            } else {
                                print("🎬 [HLSPreflight] Invalid manifest content")
                            }
                        }
                    } else if httpResponse.statusCode == 404 || httpResponse.statusCode == 503 {
                        // Transcode not started yet
                    } else {
                        print("🎬 [HLSPreflight] Unexpected status \(httpResponse.statusCode)")
                    }
                }
            } catch {
                print("🎬 [HLSPreflight] Error: \(error.localizedDescription)")
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
        subtitleClockSync.stop()

        // Stop RivuletPlayer if active
        rivuletPlayer?.stop()
        rivuletPlayer = nil

        teardownAVPlayerObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        _playerForCleanup = nil
        // Abort any in-progress FFmpeg I/O immediately (bypasses actor queue),
        // then cancel/close the session asynchronously.
        if let session = remuxSession {
            session.interruptFlag.pointee = 1
            Task { await session.cancel(); await session.close() }
        }
        remuxServer?.stop()
        remuxServer = nil
        remuxSession = nil
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
        if let rp = rivuletPlayer {
            rp.play()
        } else {
            player?.play()
        }
    }

    private func activePlayer_pause() {
        if let rp = rivuletPlayer {
            rp.pause()
        } else {
            if remuxServer != nil {
                print("[Remux] activePlayer_pause() called")
            }
            player?.pause()
        }
    }

    // MARK: - Info Panel Navigation

    /// Reset settings panel state when opening
    func resetSettingsPanel() {
        // Refresh track lists when panel opens
        updateTrackLists()
        focusedColumn = 0
        focusedRowIndex = 0
    }

    func seek(to time: TimeInterval) async {
        if let rp = rivuletPlayer {
            await rp.seek(to: time)
        } else {
            await player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        }
        subtitleClockSync.didSeek()
        showControlsTemporarily()
    }

    func seekRelative(by seconds: TimeInterval) async {
        hidePausedPoster()
        let targetTime = max(0, min(currentTime + seconds, duration))
        if let rp = rivuletPlayer {
            await rp.seek(to: targetTime)
        } else {
            await player?.seek(to: CMTime(seconds: targetTime, preferredTimescale: 600))
        }
        subtitleClockSync.didSeek()
        showControlsTemporarily()

        // Show seek indicator for tap-to-skip
        let intSeconds = Int(abs(seconds))
        showSeekIndicator(seconds >= 0 ? .forward(intSeconds) : .backward(intSeconds))
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

    /// Speed multipliers for each level (seconds per 100ms tick)
    private static let scrubSpeeds: [Int: TimeInterval] = [
        1: 1.0,    // 1x = 10 seconds per second
        2: 2.0,    // 2x = 20 seconds per second
        3: 4.0,    // 3x = 40 seconds per second
        4: 8.0,    // 4x = 80 seconds per second
        5: 15.0,   // 5x = 150 seconds per second
        6: 30.0,   // 6x = 300 seconds per second (5 min/sec)
        7: 45.0,   // 7x = 450 seconds per second (7.5 min/sec)
        8: 60.0    // 8x = 600 seconds per second (10 min/sec)
    ]

    /// Human-readable label for current scrub speed
    var scrubStepLabel: String? {
        guard scrubSpeed != 0 else { return nil }
        let magnitude = abs(scrubSpeed)
        let arrow = scrubSpeed > 0 ? "▶▶" : "◀◀"
        return "\(arrow) \(magnitude)×"
    }

    /// Start or increase scrub speed in given direction
    /// Each click increases speed up to 8x
    /// - Parameter forward: true for forward, false for backward
    func scrubInDirection(forward: Bool) {
        hidePausedPoster()
        let direction = forward ? 1 : -1

        if !isScrubbing {
            // Start scrubbing
            isScrubbing = true
            scrubTime = currentTime
            scrubSpeed = direction  // Start at 1x
            controlsTimer?.invalidate()
            startScrubTimer()
            loadThumbnail(for: scrubTime)
        } else if (scrubSpeed > 0) == forward {
            // Same direction - increase speed up to 8x
            let newSpeed = min(8, abs(scrubSpeed) + 1) * direction
            scrubSpeed = newSpeed
        } else {
            // Opposite direction - decelerate first, then reverse
            if abs(scrubSpeed) > 1 {
                // Slow down by 1 level, keep same direction
                let currentDirection = scrubSpeed > 0 ? 1 : -1
                scrubSpeed = (abs(scrubSpeed) - 1) * currentDirection
            } else {
                // At 1x, switch to opposite direction at 1x
                scrubSpeed = direction
            }
        }

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
        }

        scrubTime = max(0, min(duration, scrubTime + seekDelta))
        loadThumbnail(for: scrubTime)
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
        if isScrubbing {
            await seek(to: scrubTime)
            isScrubbing = false
            scrubSpeed = 0
            scrubStartTime = nil
            scrubThumbnail = nil
        }
    }

    func cancelScrub() {
        stopScrubTimer()
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

        let speedMagnitude = abs(scrubSpeed)
        let direction: TimeInterval = scrubSpeed > 0 ? 1 : -1
        let secondsPerTick = Self.scrubSpeeds[speedMagnitude] ?? 1.0

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
        // TODO: AVPlayer path still needs AVMediaSelectionGroup wiring; this
        // fix only covers the RivuletPlayer pipeline (custom player).
        selectAudioTrackWithoutSaving(id: id)

        if let track = audioTracks.first(where: { $0.id == id }) {
            AudioPreferenceManager.current = AudioPreference(from: track)
        }
    }

    /// Switch audio track for RivuletPlayer HLS path by rebuilding the Plex transcode session.
    /// Sets the preferred audio stream on the Plex server, then starts a fresh transcode session.
    private func switchHLSAudioTrack(plexStreamId: Int) async {
        guard let rp = rivuletPlayer, rp.activePipeline == .hls else { return }

        let resumeTime = currentTime
        let wasPlaying = rp.isPlaying

        print("🎬 [AudioSwitch] Switching HLS audio to stream \(plexStreamId) at \(String(format: "%.1f", resumeTime))s")

        // Stop the current Plex transcode session
        rp.stop()
        if let sessionId = plexSessionId {
            await PlexNetworkManager.shared.stopTranscodeSession(
                serverURL: serverURL, authToken: authToken, sessionId: sessionId
            )
            plexSessionId = nil
        }

        guard let ratingKey = metadata.ratingKey else { return }
        let networkManager = PlexNetworkManager.shared

        // Tell Plex which audio stream to use BEFORE starting the new transcode.
        // Plex reads this preference when building the transcode session.
        if let partId = metadata.Media?.first?.Part?.first?.id {
            await networkManager.setSelectedAudioStream(
                serverURL: serverURL,
                authToken: authToken,
                partId: partId,
                audioStreamID: plexStreamId
            )
        }

        // Build new HLS URL (Plex will use the audio stream we just set)
        let forceVideoTranscode = ContentRouter.requiresVideoTranscode(metadata: metadata)
        guard let result = networkManager.buildHLSDirectPlayURL(
            serverURL: serverURL,
            authToken: authToken,
            ratingKey: ratingKey,
            offsetMs: Int(resumeTime * 1000),
            hasHDR: metadata.hasHDR,
            useDolbyVision: metadata.hasDolbyVision,
            forceVideoTranscode: forceVideoTranscode,
            allowAudioDirectStream: allowAudioDirectStreamDecision(reason: "rivulet_hls_audio_switch")
        ) else {
            print("🎬 [AudioSwitch] Failed to build HLS URL")
            return
        }

        streamURL = result.url
        streamHeaders = result.headers
        plexSessionId = URLComponents(url: result.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "session" })?.value

        // Wait for the new transcode to be ready
        let transcodeReady = await waitForHLSTranscodeReady(url: result.url, headers: result.headers)
        if !transcodeReady {
            print("🎬 [AudioSwitch] New transcode session failed to start")
            errorMessage = "Failed to switch audio track"
            return
        }

        // Reload with new URL
        do {
            try await rp.loadHLSWithConversion(
                url: result.url,
                headers: result.headers,
                startTime: resumeTime,
                requiresProfileConversion: requiresProfileConversion
            )
            if wasPlaying {
                rp.play()
            }
            self.duration = rp.duration
            print("🎬 [AudioSwitch] Switched to audio stream \(plexStreamId) successfully")
        } catch {
            print("🎬 [AudioSwitch] Failed to reload with new audio: \(error)")
            errorMessage = "Failed to switch audio track"
        }
    }

    /// Select audio track without saving preference (for auto-selection)
    private func selectAudioTrackWithoutSaving(id: Int) {
        if let rp = rivuletPlayer {
            rp.selectAudioTrack(plexTrackId: id, plexAudioTracks: audioTracks)
            if rp.activePipeline == .hls {
                Task { await switchHLSAudioTrack(plexStreamId: id) }
            }
        }
        currentAudioTrackId = id
    }

    func selectSubtitleTrack(id: Int?) {
        // Delegate the actual pipeline switch to the auto-selection helper,
        // then persist the user's explicit choice as the saved preference so
        // future playback sessions restore it.
        // TODO: AVPlayer path still needs AVMediaSelectionGroup wiring; this
        // fix only covers the RivuletPlayer pipeline (custom player).
        selectSubtitleTrackWithoutSaving(id: id)

        if let id = id, let track = subtitleTracks.first(where: { $0.id == id }) {
            SubtitlePreferenceManager.current = SubtitlePreference(from: track)
        } else {
            SubtitlePreferenceManager.current = .off
        }
    }

    /// Load subtitle content for the active Rivulet playback pipeline.
    private func loadSubtitleForRivuletPlayer(trackId: Int?) {
        guard rivuletPlayer != nil else { return }

        // Clear subtitles if no track selected
        guard let trackId = trackId,
              let track = subtitleTracks.first(where: { $0.id == trackId }) else {
            subtitleManager.clear()
            // Stop FFmpeg subtitle stream and callback for Rivulet
            if let rp = rivuletPlayer {
                rp.deselectEmbeddedSubtitle()
                rp.onSubtitleCue = nil
                rp.onBitmapSubtitleCue = nil
            }
            return
        }

        // For RivuletPlayer in DirectPlay mode, enable inline subtitle extraction via FFmpeg.
        // The read loop delivers subtitle cues as it encounters them (no second HTTP connection).
        // Falls back to Plex URL for external sidecar subs if FFmpeg has no subtitle tracks.
        if let rp = rivuletPlayer, rp.activePipeline == .directPlay {
            let ffmpegSubs = rp.ffmpegSubtitleTracks
            if !ffmpegSubs.isEmpty {
                print("🎬 [Subtitles] Enabling inline embedded subtitle for track \(trackId) (FFmpeg has \(ffmpegSubs.count) sub tracks)")
                subtitleManager.clear()
                rp.onSubtitleCue = { [weak self] text, start, end in
                    self?.subtitleManager.addCue(text: text, startTime: start, endTime: end)
                }
                rp.onBitmapSubtitleCue = { [weak self] cue in
                    self?.subtitleManager.addBitmapCue(cue)
                }

                // Select the subtitle stream in the demuxer.
                // Returns false if the track is external (not in the container) —
                // fall through to Plex URL fetch in that case.
                if rp.selectEmbeddedSubtitle(plexTrackId: trackId, plexSubtitleTracks: subtitleTracks) {
                    return
                }

                // Embedded mapping failed — clean up the callbacks before falling through
                rp.onSubtitleCue = nil
                rp.onBitmapSubtitleCue = nil
            }

            // No embedded match — try Plex URL (external sidecar subs)
            print("🎬 [Subtitles] Track \(trackId) not embedded in container, trying Plex URL")
        }

        loadSubtitleFromPlexURL(trackId: trackId, track: track)
    }

    /// Load subtitle from Plex server URL for external sidecar subtitles.
    private func loadSubtitleFromPlexURL(trackId: Int, track: MediaTrack) {
        let codec = track.codec?.lowercased()
        let supportedCodecs = ["srt", "subrip", "vtt", "webvtt", "ass", "ssa", "mov_text", "tx3g"]
        let isLikelyTextSubtitle = codec.map { supportedCodecs.contains($0) } ?? true
        if let codec, !isLikelyTextSubtitle {
            print("🎬 [Subtitles] Non-text or unsupported subtitle codec '\(codec)' - attempting SRT conversion fallback")
        }

        let hintedFormat: SubtitleFormat? = isLikelyTextSubtitle ? SubtitleFormat(from: codec) : .srt
        let headers = ["X-Plex-Token": authToken]

        // Build candidate subtitle URLs from the track's key only. Plex's
        // `/library/streams/{id}` endpoint is PUT-only (used to change stream
        // selection); a GET against it returns 501, so the old fallback just
        // spammed HTTPClientError events without ever loading a subtitle.
        // If there's no `subtitleKey`, there's nothing to fetch.
        var candidateURLStrings: [String] = []
        if let trackKey = track.subtitleKey {
            let isAbsolute = trackKey.hasPrefix("http://") || trackKey.hasPrefix("https://")
            let baseKeyURL = isAbsolute ? trackKey : (serverURL + trackKey)
            candidateURLStrings.append(baseKeyURL)

            // Explicit conversion endpoint for codecs we cannot parse directly.
            let separator = baseKeyURL.contains("?") ? "&" : "?"
            candidateURLStrings.append(baseKeyURL + "\(separator)format=srt")
        }

        // Preserve order but avoid duplicate network requests.
        var seen = Set<String>()
        candidateURLStrings = candidateURLStrings.filter { seen.insert($0).inserted }

        let candidateURLs = candidateURLStrings.compactMap(URL.init(string:))
        guard !candidateURLs.isEmpty else {
            print("🎬 [Subtitles] Could not build subtitle URL candidates for track \(trackId)")
            subtitleManager.clear()
            return
        }

        Task { @MainActor in
            var loaded = false
            for candidateURL in candidateURLs {
                let formatHintForCandidate: SubtitleFormat? =
                    candidateURL.query?.localizedCaseInsensitiveContains("format=srt") == true ? .srt : hintedFormat
                await subtitleManager.load(url: candidateURL, headers: headers, format: formatHintForCandidate)
                if subtitleManager.error == nil {
                    loaded = true
                    print("🎬 [Subtitles] Loaded subtitle track \(trackId) from \(candidateURL.absoluteString)")
                    break
                }
                print(
                    "🎬 [Subtitles] Candidate failed for track \(trackId): \(candidateURL.absoluteString) " +
                    "(\(subtitleManager.error?.localizedDescription ?? "unknown error"))"
                )
            }

            if !loaded {
                print("🎬 [Subtitles] Failed to load subtitle track \(trackId) from all candidate URLs")
                subtitleManager.clear()
            }
        }
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

    private func updateTrackLists() {
        let previousSubtitleCount = subtitleTracks.count
        let previousAudioCount = audioTracks.count

        let newAudioTracks: [MediaTrack]
        let newSubtitleTracks: [MediaTrack]
        let newCurrentAudioTrackId: Int?
        let newCurrentSubtitleTrackId: Int?

        if let streams = metadata.Media?.first?.Part?.first?.Stream {
            newAudioTracks = streams.filter { $0.isAudio }.map { MediaTrack(from: $0) }
            newSubtitleTracks = streams.filter { $0.isSubtitle }.map { MediaTrack(from: $0) }
            let selectedAudioId = streams.first(where: { $0.isAudio && $0.selected == true })?.id
            let selectedSubtitleId = streams.first(where: { $0.isSubtitle && $0.selected == true })?.id
            newCurrentAudioTrackId = selectedAudioId ??
                newAudioTracks.first(where: { $0.isDefault })?.id ??
                newAudioTracks.first?.id
            newCurrentSubtitleTrackId = selectedSubtitleId ??
                newSubtitleTracks.first(where: { $0.isForced })?.id ??
                newSubtitleTracks.first(where: { $0.isDefault })?.id
        } else {
            // AVPlayer track enumeration would go here — for now use empty
            newAudioTracks = []
            newSubtitleTracks = []
            newCurrentAudioTrackId = nil
            newCurrentSubtitleTrackId = nil
        }

        audioTracks = newAudioTracks
        subtitleTracks = newSubtitleTracks

        // Only update current track IDs on first population.
        // After tracks are populated, the user's explicit selections take precedence.
        if previousAudioCount == 0 {
            currentAudioTrackId = newCurrentAudioTrackId
        }
        if previousSubtitleCount == 0 {
            currentSubtitleTrackId = newCurrentSubtitleTrackId
        }

        // Apply saved audio preference when tracks are first available
        if !hasAppliedAudioPreference && !audioTracks.isEmpty && previousAudioCount == 0 {
            hasAppliedAudioPreference = true
            applyAudioPreference()
        }

        // Apply saved subtitle preference when tracks are first available
        if !hasAppliedSubtitlePreference && !subtitleTracks.isEmpty && previousSubtitleCount == 0 {
            hasAppliedSubtitlePreference = true
            applySubtitlePreference()
        }
    }

    enum StreamType { case audio, subtitle }

    /// Enrich player tracks with Plex stream metadata (display name, channels, subtitle keys, etc.)
    private func enrichTracksWithPlexStreams(_ tracks: [MediaTrack], plexStreams: [PlexStream], type: StreamType) -> [MediaTrack] {
        // Filter Plex streams to only match the correct type
        let filteredStreams = plexStreams.filter { stream in
            switch type {
            case .audio: return stream.isAudio
            case .subtitle: return stream.isSubtitle
            }
        }

        return tracks.map { track in
            // Try to find matching Plex stream by language code and codec
            let matchingStream = filteredStreams.first { stream in
                // Match by language code and codec type
                let langMatch = track.languageCode?.lowercased() == stream.languageCode?.lowercased()
                let codecMatch = track.codec?.lowercased() == stream.codec?.lowercased()
                return langMatch && codecMatch
            } ?? filteredStreams.first { stream in
                // Fallback: just match by language
                track.languageCode?.lowercased() == stream.languageCode?.lowercased()
            }

            guard let stream = matchingStream else { return track }

            // Use Plex displayTitle for better formatting (e.g., "English (AAC 7.1)" instead of "Track 1")
            let enrichedName = stream.displayTitle ?? stream.extendedDisplayTitle ?? track.name

            // Create enriched track with Plex metadata - keep original ID for selection to work
            return MediaTrack(
                id: track.id,
                name: enrichedName,
                language: stream.language ?? track.language,
                languageCode: stream.languageCode ?? track.languageCode,
                codec: stream.codec ?? track.codec,
                isDefault: stream.default ?? track.isDefault,
                isForced: stream.forced ?? track.isForced,
                isHearingImpaired: stream.hearingImpaired ?? track.isHearingImpaired,
                extendedDisplayTitle: stream.extendedDisplayTitle ?? track.extendedDisplayTitle,
                channels: stream.channels ?? track.channels,
                subtitleKey: stream.key ?? track.subtitleKey
            )
        }
    }

    /// Apply saved audio preference. Selection priority is:
    ///  1. `initialAudioTrackId` from the pre-play picker (this session).
    ///  2. Plex's per-item explicit selection (a `selected: true` stream
    ///     that isn't also the file's `default: true` track — meaning the
    ///     user picked something deliberately, in Plex Web / mobile / our
    ///     own picker — that choice persists server-side and should win
    ///     over a global language default).
    ///  3. App-level `AudioPreferenceManager` language preference (which
    ///     defaults to English even when nothing has been stored — drives
    ///     the typical "auto-pick the highest-quality English stream"
    ///     behavior for items the user has never deliberately picked for).
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
        // 1. Pre-play picker (this session).
        if let id = initialAudioTrackId {
            initialAudioTrackId = nil
            if audioTracks.contains(where: { $0.id == id }) {
                selectAudioTrackWithoutSaving(id: id)
                return
            }
        }

        // 2. Plex per-item explicit selection.
        if let plexSelectedId = currentAudioTrackId,
           let plexDefaultId = audioTracks.first(where: { $0.isDefault })?.id,
           plexSelectedId != plexDefaultId,
           audioTracks.contains(where: { $0.id == plexSelectedId }) {
            selectAudioTrackWithoutSaving(id: plexSelectedId)
            return
        }

        // 3. App-level language preference.
        let preference = AudioPreferenceManager.current
        if let match = AudioPreferenceManager.findBestMatch(in: audioTracks, preference: preference) {
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
            initialSubtitleSelection = .auto
            if subtitleTracks.contains(where: { $0.id == id }) {
                selectSubtitleTrackWithoutSaving(id: id)
                return
            }
        case .auto:
            break
        }

        // 2. Plex's per-item explicit selection. A `selected: true`
        //    track that's neither the default nor the forced track is
        //    one the user picked deliberately — honor it over the
        //    app-level language preference.
        if let plexSelectedSubId = currentSubtitleTrackId,
           let track = subtitleTracks.first(where: { $0.id == plexSelectedSubId }),
           !track.isDefault, !track.isForced {
            selectSubtitleTrackWithoutSaving(id: plexSelectedSubId)
            return
        }

        // No explicit user preference yet: honor selected/default stream behavior.
        if !SubtitlePreferenceManager.hasStoredPreference {
            if currentSubtitleTrackId == nil,
               let forcedTrack = subtitleTracks.first(where: { $0.isForced }) {
                selectSubtitleTrackWithoutSaving(id: forcedTrack.id)
            } else if let activeSubtitleTrackId = currentSubtitleTrackId {
                // For custom renderers, selecting can require explicit file fetch/load.
                loadSubtitleForRivuletPlayer(trackId: activeSubtitleTrackId)
            }
            return
        }

        let preference = SubtitlePreferenceManager.current

        if !preference.enabled {
            // User prefers subtitles off
            selectSubtitleTrackWithoutSaving(id: nil)
            return
        }

        // Find best matching track
        if let match = SubtitlePreferenceManager.findBestMatch(in: subtitleTracks, preference: preference) {
            selectSubtitleTrackWithoutSaving(id: match.id)
        } else {
            // No matching language found - keep subtitles off
            selectSubtitleTrackWithoutSaving(id: nil)
        }
    }

    /// Select subtitle track without saving preference (for auto-selection)
    private func selectSubtitleTrackWithoutSaving(id: Int?) {
        if rivuletPlayer != nil {
            rivuletPlayer?.selectSubtitleTrack(id: id)
            loadSubtitleForRivuletPlayer(trackId: id)
        }
        currentSubtitleTrackId = id
    }

    private func configureSubtitleClockSyncForCurrentPlayer() {
        guard let rp = rivuletPlayer else {
            subtitleClockSync.stop()
            return
        }
        subtitleClockSync.start(
            owner: "Rivulet",
            subtitleManager: subtitleManager,
            timeProvider: { rp.renderer.displayTime },
            isPlayingProvider: { rp.isPlaying }
        )
    }

    // MARK: - Controls Visibility

    func showControlsTemporarily() {
        showControls = true
        startControlsHideTimer()
    }

    private func startControlsHideTimer() {
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

    /// Start timer to show poster after being paused for 5 seconds
    private func startPausedPosterTimer() {
        pausedPosterTimer?.invalidate()
        pausedPosterTimer = Timer.scheduledTimer(withTimeInterval: pausedPosterDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackState == .paused else { return }
                withAnimation(.easeIn(duration: 1.0)) {
                    self.showPausedPoster = true
                }
            }
        }
    }

    /// Cancel paused poster timer and hide the poster
    private func cancelPausedPosterTimer() {
        pausedPosterTimer?.invalidate()
        pausedPosterTimer = nil
        if showPausedPoster {
            withAnimation(.easeOut(duration: 0.5)) {
                showPausedPoster = false
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
            if hasSkippedIntro || userDeclinedIntroAutoSkip {
                if time < previewStart {
                    hasSkippedIntro = false
                    userDeclinedIntroAutoSkip = false
                    // Cancel any running countdown
                    introSkipCountdownTimer?.invalidate()
                    introSkipCountdownTimer = nil
                    introSkipCountdownSeconds = 0
                } else if previewStart == 0 && time < intro.startTimeSeconds + 1.0 && activeMarker == nil {
                    hasSkippedIntro = false
                    userDeclinedIntroAutoSkip = false
                    introSkipCountdownTimer?.invalidate()
                    introSkipCountdownTimer = nil
                    introSkipCountdownSeconds = 0
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

            // Show skip button during entire credits range (5s preview through end)
            // Only show if credits marker is in a valid position
            if creditsAreValid && time >= previewStart && time < credits.endTimeSeconds {
                handleCreditsMarkerActive(credits, currentTime: time)

                // Trigger post-video summary when FIRST credits marker actually starts
                // (skip button will be hidden by UI when postVideoState != .hidden)
                if let firstCredits = metadata.firstCreditsMarker,
                   credits.id == firstCredits.id,
                   time >= credits.startTimeSeconds && !hasTriggeredPostVideo {
                    hasTriggeredPostVideo = true
                    Task { await handlePlaybackEnded() }
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
                Task { await handlePlaybackEnded() }
                return
            }
        }

        // No active marker
        if activeMarker != nil {
            activeMarker = nil
            showSkipButton = false
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

        // Check for auto-skip with countdown (only when inside actual marker range)
        if isIntro && autoSkipIntro && !hasSkippedIntro && insideMarker && !userDeclinedIntroAutoSkip {
            // Start countdown timer if not already running
            if introSkipCountdownTimer == nil && introSkipCountdownSeconds == 0 {
                startIntroSkipCountdown(for: marker)
            }
            // Show skip button during countdown
            if activeMarker == nil {
                activeMarker = marker
                showSkipButton = true
            }
            return
        }

        // Show skip button if not already skipped
        if !hasSkippedIntro && activeMarker == nil {
            activeMarker = marker
            showSkipButton = true
        }
    }

    /// Start countdown timer for auto-skip intro
    private func startIntroSkipCountdown(for marker: PlexMarker) {
        introSkipCountdownSeconds = introSkipDelaySeconds

        introSkipCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else {
                    timer.invalidate()
                    return
                }

                self.introSkipCountdownSeconds -= 1

                if self.introSkipCountdownSeconds <= 0 {
                    timer.invalidate()
                    self.introSkipCountdownTimer = nil
                    self.hasSkippedIntro = true
                    await self.skipMarker(marker)
                }
            }
        }
    }

    /// Cancel the intro skip countdown (called when user presses Menu during countdown)
    func cancelIntroSkipCountdown() {
        guard introSkipCountdownTimer != nil || introSkipCountdownSeconds > 0 else { return }

        introSkipCountdownTimer?.invalidate()
        introSkipCountdownTimer = nil
        introSkipCountdownSeconds = 0
        userDeclinedIntroAutoSkip = true  // Don't restart countdown for this intro
    }

    /// Handle when playback enters a credits marker range (or preview window)
    /// Auto-skip only triggers when actually inside the marker (at or past startTimeSeconds).
    private func handleCreditsMarkerActive(_ marker: PlexMarker, currentTime: TimeInterval) {
        guard let creditsId = marker.id else { return }

        let autoSkipCredits = UserDefaults.standard.bool(forKey: "autoSkipCredits")

        // Only auto-skip when actually inside the marker (not during preview window)
        let insideMarker = currentTime >= marker.startTimeSeconds

        // Check for auto-skip (only when inside actual marker range)
        if autoSkipCredits && !skippedCreditsIds.contains(creditsId) && insideMarker {
            skippedCreditsIds.insert(creditsId)
            Task { await skipMarker(marker) }
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

        // Check for auto-skip (only when inside actual marker range)
        if autoSkipAds && !skippedCommercialIds.contains(commercialId) && insideMarker {
            skippedCommercialIds.insert(commercialId)
            Task { await skipMarker(marker) }
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
        // Mark as skipped to prevent re-showing button if user seeks back
        if marker.isIntro {
            hasSkippedIntro = true
            // Cancel any running countdown (user clicked skip button manually)
            introSkipCountdownTimer?.invalidate()
            introSkipCountdownTimer = nil
            introSkipCountdownSeconds = 0
        } else if marker.isCredits, let creditsId = marker.id {
            skippedCreditsIds.insert(creditsId)
        } else if marker.isCommercial, let commercialId = marker.id {
            skippedCommercialIds.insert(commercialId)
        }

        // Seek to end of marker
        await seek(to: marker.endTimeSeconds)

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
        }
        return "Skip"
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
    func handlePlaybackEnded() async {
        // Don't re-enter if already showing post-video
        guard postVideoState == .hidden else { return }

        // Mark as watched immediately when playback ends/reaches credits
        await markCurrentAsWatched()

        postVideoState = .loading

        let isEpisode = metadata.type == "episode"

        // Movies: No PostVideo - just let the video play through to the end
        guard isEpisode else {
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
                ratingKey: ratingKey
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

        } catch {
            print("🎬 [Metadata] Failed to fetch full metadata: \(error)")
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

        // Reset intro skip countdown state
        introSkipCountdownTimer?.invalidate()
        introSkipCountdownTimer = nil
        introSkipCountdownSeconds = 0
        userDeclinedIntroAutoSkip = false
        nextEpisode = nil

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
        countdownTimer?.invalidate()
        seekIndicatorTimer?.invalidate()
        introSkipCountdownTimer?.invalidate()
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

    /// Posted when video playback starts (pauses hub polling)
    static let plexPlaybackStarted = Notification.Name("plexPlaybackStarted")

    /// Posted when video playback stops (resumes hub polling)
    static let plexPlaybackStopped = Notification.Name("plexPlaybackStopped")
}
