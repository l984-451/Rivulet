//
//  AetherPlayer.swift
//  Rivulet
//
//  PlayerProtocol-conforming adapter around AetherEngine.
//
//  Rivulet's only player: VOD and Live TV (one instance per grid slot).
//  Video must be displayed through `bind(view:)` / AetherVideoSurfaceView —
//  the engine attaches the active backend's layer itself (AVPlayerLayer on
//  the native path, AVSampleBufferDisplayLayer on the software path).
//  `currentAVPlayer` is still republished for non-render uses (mute
//  reapplication, item-level metadata observation).
//
//  Aether handles HDR10+ dynamic metadata preservation, HLG signaling,
//  EAC3+JOC Atmos stream-copy through MKV, and DV P5/P8.1 via dvh1+dvcC
//  in HLS-fMP4 sample entries. DV P7 plays as HDR10 base only. Routing
//  decisions live in ContentRouter; this adapter just bridges the engine
//  surface.
//

import AVFoundation
import Combine
import Foundation
import UIKit
import AetherEngine

@MainActor
final class AetherPlayer: PlayerProtocol {

    private let engine: AetherEngine

    private let stateSubject = CurrentValueSubject<UniversalPlaybackState, Never>(.idle)
    private let timeSubject = PassthroughSubject<TimeInterval, Never>()
    private let errorSubject = PassthroughSubject<PlayerError, Never>()
    private var cancellables = Set<AnyCancellable>()

    /// Re-publishes AetherEngine.currentAVPlayer so the host player view can
    /// rebind its .player on every internal Aether reload (audio-track
    /// switch / background reopen). Documented at AetherEngine.swift:1225.
    @Published private(set) var currentAVPlayer: AVPlayer?

    /// Mute state for the underlying AVPlayer. Tracked so it survives Aether's
    /// internal player swaps (see the `$currentAVPlayer` sink). Used by the
    /// Live TV grid, where non-focused slots play muted.
    private(set) var isMuted = false

    /// Subtitle cues bridged from AetherEngine.SubtitleCue into Rivulet's
    /// nameable AetherSubtitleCue (carries text AND bitmap bodies). Converted
    /// on the main queue in wireUpPublishers so the host overlay binds directly.
    @Published private(set) var subtitleCues: [AetherSubtitleCue] = []

    /// Mirrors engine.$isSubtitleActive. True when any subtitle track
    /// (embedded or sidecar) is selected and the engine has cue data.
    @Published private(set) var isSubtitleActive: Bool = false

    /// True while playback is stalled waiting for media. Combines
    /// engine.$isBuffering with a direct timeControlStatus observation on the
    /// engine's inner AVPlayer: the engine's flag only updates inside its
    /// timeControlStatus sink gated on `state == .playing` at that moment, so
    /// a far seek that lands while the player is still waiting (producer
    /// remuxing at the new anchor) leaves the flag stale-false — a silent
    /// stall window (upstream gap; the engine patches this in its seek-wedge
    /// branch but not the normal landing path).
    @Published private(set) var isBuffering: Bool = false

    /// Inputs for the combined `isBuffering` (see above).
    private var engineReportsBuffering = false
    private var engineIsPlaying = false
    private var hostPlayerWaiting = false
    private var timeControlStatusCancellable: AnyCancellable?

    /// Active Aether subtitle stream index, or nil when subtitles are off.
    @Published private(set) var activeSubtitleTrackId: Int?

    /// Active Aether audio stream index, or nil before the engine resolves one.
    @Published private(set) var activeAudioTrackId: Int?

    /// Source-timeline position in seconds, mirroring clock.$currentTime.
    /// Equal to currentTime on all current Aether paths (PlaybackClock
    /// unifies source-PTS and wall-clock onto a single value).
    @Published private(set) var sourceTime: Double = 0

    @Published private(set) var audioTracks: [MediaTrack] = []
    /// Published so the host can rebuild its merged track list the moment the
    /// engine reports (symmetric with `audioTracks`). These carry engine stream
    /// indices as ids and NO forced bit / long title — `TrackMerge` folds Plex's
    /// metadata onto them.
    @Published private(set) var subtitleTracks: [MediaTrack] = []

    init() {
        do {
            self.engine = try AetherEngine()
        } catch {
            fatalError("AetherEngine init failed: \(error)")
        }
        wireUpPublishers()
    }

    private func wireUpPublishers() {
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] aetherState in
                guard let self else { return }
                self.engineIsPlaying = (aetherState == .playing)
                // Recompute BEFORE publishing the state so the view model's
                // ".playing while still buffering" reconciliation sees the
                // combined flag the moment a seek lands.
                self.recomputeIsBuffering()
                self.stateSubject.send(Self.translate(aetherState))
            }
            .store(in: &cancellables)

        // AetherEngine 3.x moved the high-frequency clock off the engine's
        // own objectWillChange into a separate PlaybackClock (the engine
        // does NOT fire on clock ticks). Observe clock.$currentTime.
        // Also drive sourceTime here so subtitle lookups share the same tick.
        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                self?.timeSubject.send(t)
                self?.sourceTime = t
            }
            .store(in: &cancellables)

        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                // Convert here: each cue's type is inferred as
                // AetherEngine.SubtitleCue (it cannot be named explicitly),
                // and the body cases are pattern-matched without naming them.
                self?.subtitleCues = cues.map { cue in
                    let body: AetherSubtitleCue.Body
                    switch cue.body {
                    case .text(let string):
                        body = .text(string)
                    case .image(let image):
                        body = .image(cgImage: image.cgImage, position: image.position)
                    }
                    return AetherSubtitleCue(
                        id: cue.id,
                        startTime: cue.startTime,
                        endTime: cue.endTime,
                        body: body
                    )
                }
            }
            .store(in: &cancellables)

        engine.$isSubtitleActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.isSubtitleActive = active
            }
            .store(in: &cancellables)

        engine.$isBuffering
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buffering in
                self?.engineReportsBuffering = buffering
                self?.recomputeIsBuffering()
            }
            .store(in: &cancellables)

        engine.$activeSubtitleTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                self?.activeSubtitleTrackId = id
            }
            .store(in: &cancellables)

        engine.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                self?.activeAudioTrackId = id
            }
            .store(in: &cancellables)

        engine.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avp in
                guard let self else { return }
                // Reapply mute across internal reloads — Aether swaps the
                // AVPlayer on audio-track switch / background reopen, and the
                // Live TV grid relies on per-slot muting persisting.
                avp?.isMuted = self.isMuted
                self.currentAVPlayer = avp
                self.observeTimeControlStatus(of: avp)
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?.audioTracks = tracks.map(Self.translateTrack)
            }
            .store(in: &cancellables)

        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?.subtitleTracks = tracks.map(Self.translateTrack)
            }
            .store(in: &cancellables)
    }

    /// Watch the inner AVPlayer's transport directly. Replaced whenever the
    /// engine swaps its player (track switch, background reopen); nil on the
    /// software backend's no-AVPlayer configurations, where the engine's own
    /// flag is the only (and sufficient) signal.
    private func observeTimeControlStatus(of player: AVPlayer?) {
        timeControlStatusCancellable = player?
            .publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.hostPlayerWaiting = (status == .waitingToPlayAtSpecifiedRate)
                self?.recomputeIsBuffering()
            }
        if player == nil {
            hostPlayerWaiting = false
            recomputeIsBuffering()
        }
    }

    private func recomputeIsBuffering() {
        // hostPlayerWaiting only counts while the ENGINE believes it is
        // playing: during loads/seeks the engine state already communicates,
        // and a paused AVPlayer never reports waiting anyway.
        let combined = engineReportsBuffering || (engineIsPlaying && hostPlayerWaiting)
        if combined != isBuffering { isBuffering = combined }
    }

    private static func translate(_ s: PlaybackState) -> UniversalPlaybackState {
        switch s {
        case .idle: return .idle
        case .loading: return .loading
        case .playing: return .playing
        case .paused: return .paused
        case .seeking: return .buffering
        case .ended: return .ended
        case .error(let message): return .failed(.unknown(message))
        }
    }

    private static func translateTrack(_ t: TrackInfo) -> MediaTrack {
        // Build a human-readable name from whatever Aether provides.
        // FFmpeg stream names are often empty for audio; fall back through
        // localized language name → raw language tag → codec so the picker
        // always shows something meaningful.
        let name: String
        if !t.name.isEmpty {
            name = t.name
        } else if let lang = t.language, !lang.isEmpty {
            name = Locale.current.localizedString(forLanguageCode: lang) ?? lang
        } else {
            name = t.codec.uppercased()
        }
        return MediaTrack(
            id: t.id,
            name: name,
            language: t.language,
            languageCode: t.language,
            codec: t.codec,
            isDefault: t.isDefault,
            // The engine reads the container's disposition bits and DOES report
            // these. They were previously dropped on the floor here, which is
            // why the app believed only Plex knew a track was forced.
            isForced: t.isForced,
            isHearingImpaired: t.isHearingImpaired,
            isCommentary: t.isCommentary,
            channels: t.channels > 0 ? t.channels : nil,
            // `TrackInfo.id` IS the container stream index (Demuxer enumerates
            // all streams and passes the loop counter through as `id`). It is
            // the same value Plex reports as `PlexStream.index`, which is what
            // lets TrackMerge pair the two sides on container truth.
            streamIndex: t.isExternal ? nil : t.id,
            isExternal: t.isExternal
        )
    }

    /// Host-side description of an external (sidecar) subtitle file to
    /// register with the engine at load. Mirrors AetherEngine's
    /// ExternalSubtitleTrack without exposing the engine type to the view
    /// model (same isolation discipline as AetherSubtitleCue). Registered
    /// tracks appear in `subtitleTracks` with `isExternal == true`, in
    /// registration order, and are selected through the normal
    /// `selectSubtitleTrack(id:)` path.
    struct SidecarSubtitle {
        let url: URL
        let name: String?
        let language: String?
        let isForced: Bool
        let isHearingImpaired: Bool
        let isDefault: Bool
        /// File-extension hint ("srt", "ass", "vtt") for URLs whose path
        /// hides the format (Plex stream keys have no extension).
        let formatHint: String?
    }

    /// Read panel HDR state for LoadOptions.panelIsInHDRMode. Matches
    /// the post-handshake EDR detection pattern Aether 2.0 documents:
    /// `> 1.001` means the panel accepted HDR signaling.
    private static func panelIsInHDRMode() -> Bool {
        guard let screen = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.screen })
            .first
        else { return false }
        return screen.currentEDRHeadroom > 1.001
    }

    // MARK: - PlayerProtocol state

    var isPlaying: Bool { engine.state == .playing }
    var currentTime: TimeInterval { engine.currentTime }
    var duration: TimeInterval { engine.duration }

    /// Duration updates. The engine publishes `duration` once the source is
    /// probed; the VM needs this (not just `timePublisher`) so Plex progress
    /// reports carry a real duration (viewOffset + watched threshold).
    var durationPublisher: AnyPublisher<TimeInterval, Never> {
        engine.$duration.eraseToAnyPublisher()
    }
    var bufferedTime: TimeInterval { engine.bufferedPosition }
    var playbackRate: Float {
        get { _playbackRate }
        set {
            _playbackRate = newValue
            engine.setRate(newValue)
        }
    }
    private var _playbackRate: Float = 1.0

    var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    var timePublisher: AnyPublisher<TimeInterval, Never> {
        timeSubject.eraseToAnyPublisher()
    }
    var errorPublisher: AnyPublisher<PlayerError, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    // MARK: - Controls

    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?) async throws {
        try await load(
            url: url,
            headers: headers,
            startTime: startTime,
            subtitleLanguageHintsByStreamIndex: [:]
        )
    }

    /// Live variant (separate from the PlayerProtocol requirement — a
    /// defaulted extra parameter would break conformance).
    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?, isLive: Bool) async throws {
        try await load(
            url: url,
            headers: headers,
            startTime: startTime,
            subtitleLanguageHintsByStreamIndex: [:],
            isLive: isLive
        )
    }

    /// Live TV load. Sets `isLive` so the engine treats the source as live
    /// (seek becomes a no-op, live-edge/reconnect behavior). HLS sources use
    /// `nativeRemoteHLS` so AVPlayer plays the remote playlist directly (no
    /// demuxer probe / loopback — "HLS straight to AVPlayer"); everything else
    /// (raw MPEG-TS, etc.) goes through the engine's demux/remux to a loopback
    /// HLS stream. Either way the engine publishes `currentAVPlayer` for the
    /// AVKit OSD. No start position (live).
    /// `forceEngineDemux` disables the native-HLS shortcut so the engine's own
    /// demuxer opens the playlist instead — used as a fallback when AVPlayer's
    /// native path fails against a server (e.g. a Plex transcode session that
    /// rejects AVPlayer's request pattern).
    func loadLive(url: URL, headers: [String: String]?, forceEngineDemux: Bool = false) async throws {
        let isHLS = Self.isHLSURL(url) && !forceEngineDemux
        let options = LoadOptions(
            suppressDisplayCriteria: false,
            httpHeaders: headers ?? [:],
            // Same rich config as VOD, plus the live-specific flags.
            matchContentEnabled: true,
            panelIsInHDRMode: Self.panelIsInHDRMode(),
            audioBridgeMode: .lossless,
            isLive: true,
            // ~30-minute DVR rewind window (engine retains it disk-backed).
            dvrWindowSeconds: 1800,
            nativeRemoteHLS: isHLS,
            preserveASSMarkup: true,
            probesize: 5 * 1024 * 1024,
            maxAnalyzeDuration: 5_000_000,
            // Honor the user's saved audio/subtitle language preferences, same
            // as VOD, so the right tracks are picked on the first frame.
            preferredAudioLanguages: Self.livePreferredAudioLanguages(),
            preferredSubtitleLanguages: Self.livePreferredSubtitleLanguages()
        )
        do {
            // Broadcast H.264 routinely mis-signals interlaced content as
            // progressive (codecpar fieldOrder=0; MBAFF is only flagged
            // per-frame), which routes it down the engine's NATIVE path with
            // no deinterlacer — visible combing. Force the software path for
            // live demux sessions: bwdif deinterlaces genuinely interlaced
            // frames and passes true progressive through untouched, so a
            // correctly-signalled progressive channel only pays a SW decode.
            // (Engine flag is labeled test-only but is the exact switch for
            // this; reset immediately after dispatch. Not applied to the
            // native-HLS shortcut, which never enters the demux dispatch.)
            if !isHLS { AetherEngine.setForceSoftwarePathForTesting(true) }
            defer { if !isHLS { AetherEngine.setForceSoftwarePathForTesting(false) } }
            try await engine.load(url: url, startPosition: nil, options: options)
        } catch {
            let pe = PlayerError.loadFailed(String(describing: error))
            errorSubject.send(pe)
            throw pe
        }
    }

    private static func isHLSURL(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "m3u8" { return true }
        let text = url.absoluteString.lowercased()
        return text.contains(".m3u8") || text.contains("format=hls")
    }

    /// The user's saved audio-language intent (ISO code), if any.
    private static func livePreferredAudioLanguages() -> [String] {
        let lang = TrackIntentStore.effectiveAudioIntent.language
        return lang.isEmpty ? [] : [lang]
    }

    /// The user's saved subtitle-language intent (ISO code) when subtitles
    /// are enabled; empty (subtitles off) otherwise.
    private static func livePreferredSubtitleLanguages() -> [String] {
        if case .track(let language, _, _, _) = TrackIntentStore.subtitleIntent ?? .off,
           !language.isEmpty {
            return [language]
        }
        return []
    }

    func load(
        url: URL,
        headers: [String: String]?,
        startTime: TimeInterval?,
        subtitleLanguageHintsByStreamIndex: [Int: String],
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        externalSubtitles: [SidecarSubtitle] = [],
        isLive: Bool = false
    ) async throws {
        // .lossless: FLAC encode for non-stream-copy audio (TrueHD, DTS,
        // DTS-HD MA, MP3, Opus). FLAC encode is ~3x realtime on A15 vs
        // EAC3's ~0.5x realtime, so segment production keeps up with
        // AVPlayer's HLS pipeline on high-bitrate 4K content.
        //
        // Tradeoff: needs a sink that accepts multichannel LPCM over
        // HDMI (Denon / Marantz / NAD AVRs). On AirPlay-to-HomePod or
        // stereo-LPCM-only routes the multichannel LPCM downmixes to
        // stereo, but the encode-throughput win is still worth it.
        //
        // subtitleLanguageHintsByStreamIndex is accepted for call-site
        // compatibility but unused: upstream 4.8.0 has no per-stream
        // language-hint parameter. preferredSubtitleLanguages (below)
        // is the supported replacement for steering initial subtitle
        // selection.
        // isLive: engine auto-detection is deliberately disabled upstream
        // (VOD MKVs with broken duration headers are too common), so the
        // host must declare live sources. Enables the engine's live path:
        // clock live-edge tracking, LiveReloadPolicy reconnect, and
        // seek(to:) becoming a no-op.
        // externalSubtitles: registered at load (not addExternalSubtitleTrack)
        // so the engine can also serve them as native WebVTT renditions if
        // that path is ever enabled; httpHeaders nil inherits the media's
        // own LoadOptions headers (same Plex auth).
        let options = LoadOptions(
            suppressDisplayCriteria: false,
            httpHeaders: headers ?? [:],
            matchContentEnabled: true,
            panelIsInHDRMode: Self.panelIsInHDRMode(),
            audioBridgeMode: .lossless,
            isLive: isLive,
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            externalSubtitles: externalSubtitles.map { sub in
                ExternalSubtitleTrack(
                    url: sub.url,
                    name: sub.name,
                    language: sub.language,
                    isForced: sub.isForced,
                    isHearingImpaired: sub.isHearingImpaired,
                    isDefault: sub.isDefault,
                    httpHeaders: nil,
                    formatHint: sub.formatHint
                )
            }
        )
        do {
            try await engine.load(url: url, startPosition: startTime, options: options)
        } catch {
            let pe = PlayerError.loadFailed(String(describing: error))
            errorSubject.send(pe)
            throw pe
        }
    }

    /// Hand external metadata (title, artwork, description, genre) to the
    /// engine so AVPlayerViewController's info panel and the system Now
    /// Playing surface populate. Aether stashes these and applies them onto
    /// its internally created AVPlayerItem, replaying across internal reloads
    /// (audio-track switch, background reopen). Call BEFORE load(url:).
    ///
    /// Chapters are NOT covered: AetherEngine 3.3.0 has no navigation-marker
    /// API, so `navigationMarkerGroups` can't be injected here.
    func setExternalMetadata(_ items: [AVMetadataItem]) {
        engine.setExternalMetadata(items)
    }

    func play() { engine.play() }
    func pause() { engine.pause() }
    func stop() { engine.stop() }

    // MARK: - Render surface

    /// Attach the engine's render surface. The engine hosts whichever
    /// CALayer the active backend uses and re-attaches it across internal
    /// session swaps; binding a different view detaches the old one.
    func bind(view: AetherPlayerView) {
        engine.bind(view: view)
    }

    /// Detach a previously bound render surface. Idempotent.
    func unbind(view: AetherPlayerView) {
        engine.unbind(view: view)
    }

    /// Mute/unmute the underlying AVPlayer. Persisted in `isMuted` so it's
    /// reapplied when Aether swaps its player across internal reloads.
    func setMuted(_ muted: Bool) {
        isMuted = muted
        // engine.volume covers both backends (the software path has no
        // AVPlayer) and is remembered across internal host swaps.
        // currentAVPlayer.isMuted stays as well: it mutes the native path
        // even mid-swap, before the engine re-applies desired volume.
        engine.volume = muted ? 0 : 1
        currentAVPlayer?.isMuted = muted
    }
    func seek(to time: TimeInterval) async { await engine.seek(to: time) }

    // MARK: - Tracks

    var currentAudioTrackId: Int? { activeAudioTrackId }
    var currentSubtitleTrackId: Int? { activeSubtitleTrackId }

    func selectAudioTrack(id: Int) {
        engine.selectAudioTrack(index: id)
    }

    func selectSubtitleTrack(id: Int?) {
        if let id {
            engine.selectSubtitleTrack(index: id)
        } else {
            engine.clearSubtitle()
        }
    }

    /// Load a sidecar subtitle file (SRT, ASS, VTT, PGS) by URL.
    func prepareForReuse() {
        // No-op: AetherEngine doesn't have a reset-without-stop primitive.
        // stop() is called when the view model swaps players, and a fresh
        // AetherPlayer() instance is created for the next session.
    }

    // MARK: - Live stats (Info popup "tech sheet")

    /// Truthful, engine-sourced snapshot for the Info popup's PLAYBACK
    /// section. Every field is nil unless AetherEngine actually exposes it —
    /// nothing here is synthesized or guessed.
    ///
    /// Engine inventory (checked against the AetherEngine package checkout,
    /// Sources/AetherEngine/AetherEngine.swift and neighbors):
    ///  - Buffer depth: `engine.bufferedPosition` (source-axis buffer
    ///    frontier, forwards `clock.$bufferedPosition`) exists and is used.
    ///  - Active backend: `engine.activeVideoDecoder` (@Published,
    ///    internal(set)) is a human-readable label already assembled by the
    ///    engine, e.g. "VideoToolbox HEVC (HW)", "dav1d AV1 (SW)",
    ///    "libavcodec VP9 (SW)". Populated at load/probe time, cleared on
    ///    stop. Used directly as `backend` (no re-labeling needed; the
    ///    engine's own string already distinguishes HW/SW).
    ///  - Audio bridge: `engine.activeAudioDecoder` (@Published,
    ///    internal(set)) mirrors `HLSVideoEngine.audioPipelineDescription`,
    ///    e.g. "Stream-copy (EAC3+JOC Atmos)", "TrueHD → FLAC bridge",
    ///    "AC3 → EAC3 5.1 bridge", or the SW-path
    ///    "libavcodec <codec> → CoreAudio" label. Used directly as
    ///    `audioBridge`.
    ///  - Throughput/bitrate counters: `engine.diagnostics.liveTelemetry`
    ///    (LiveTelemetry: instantBitrateMbps, averageBitrateMbps,
    ///    networkThroughputMbps, observedFps, droppedFrameCount, etc.) DO
    ///    exist as a 1 Hz @MainActor snapshot, but are OUT OF SCOPE for this
    ///    task's `AetherLiveStats` contract (buffer/backend/audioBridge
    ///    only) — noted here for a future tech-sheet expansion, not wired.
    ///  - No separate "renderer" or "audio bridge mode" enum is publicly
    ///    readable as engine *state*; `AudioBridgeMode` (.surroundCompat /
    ///    .lossless) is an input to LoadOptions, not an observable output,
    ///    so it is NOT read back here — `activeAudioDecoder`'s resolved
    ///    label is the truthful substitute.
    func liveStats() -> AetherLiveStats {
        AetherLiveStats(
            bufferedSeconds: max(0, bufferedTime - currentTime),
            backend: engine.activeVideoDecoder,
            audioBridge: engine.activeAudioDecoder
        )
    }
}

/// Live engine snapshot for the Info popup's PLAYBACK section. Every field
/// is nil unless AetherEngine truthfully exposes it for the active session —
/// see the inventory comment on `AetherPlayer.liveStats()`.
struct AetherLiveStats {
    let bufferedSeconds: TimeInterval?
    /// Engine's own human-readable decoder label, e.g. "VideoToolbox HEVC (HW)"
    /// or "dav1d AV1 (SW)". nil while idle/no video track.
    let backend: String?
    /// Engine's own human-readable audio pipeline label, e.g.
    /// "Stream-copy (EAC3+JOC Atmos)" or "TrueHD → FLAC bridge". nil while
    /// idle/no audio track.
    let audioBridge: String?

    /// True when every field is nil — the popup omits the PLAYBACK section
    /// entirely in that case rather than rendering an empty header.
    var isEmpty: Bool {
        bufferedSeconds == nil && backend == nil && audioBridge == nil
    }
}
