// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerProtocol adapter around AetherEngine, for VOD and each Live TV slot. Video
//  renders through `bind(view:)` / AetherVideoSurfaceView; `currentAVPlayer` is
//  republished only for mute and item metadata. HDR and DV handling: CLAUDE.md, "HDR / DV".
//

import AVFoundation
import Combine
import Foundation
import os
import Sentry
import SwiftUI
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
    /// switch / background reopen). Documented in AetherEngine.swift.
    @Published private(set) var currentAVPlayer: AVPlayer?

    /// Mute state for the underlying AVPlayer. Tracked so it survives Aether's
    /// internal player swaps (see the `$currentAVPlayer` sink). Used by the
    /// Live TV grid, where non-focused slots play muted.
    private(set) var isMuted = false

    /// Subtitle cues bridged from AetherEngine.SubtitleCue into Rivulet's
    /// nameable AetherSubtitleCue (carries text AND bitmap bodies). Converted
    /// on the main queue in wireUpPublishers so the host overlay binds directly.
    @Published private(set) var subtitleCues: [AetherSubtitleCue] = []
    /// The active subtitle track's ASS script, or nil when that track is not
    /// ASS/SSA or its sidecar header has not decoded yet. The caption overlay
    /// renders the track's raw event lines through libass against it.
    @Published private(set) var assTrack: ASSTrackSource?

    /// The loaded file's embedded fonts (MKV attachments). The engine fills
    /// these once per load and does not publish them, so they are read after
    /// `engine.load` returns.
    private var assFonts: [LibassRenderer.Font] = []

    /// Scrub stills for the loaded item, made on the first scrub. It opens its
    /// own demuxer, so it is shut down on every load and on stop and never
    /// outlives its item.
    private var frameExtractor: FrameExtractor?

    /// Mirrors engine.$isSubtitleActive. True when any subtitle track
    /// (embedded or sidecar) is selected and the engine has cue data.
    @Published private(set) var isSubtitleActive: Bool = false

    /// The item's presentation size (pixel dimensions after aperture/pixel
    /// aspect correction), for hosts that must place UI against the VIDEO
    /// rect rather than the screen — the subtitle overlay measures its bottom
    /// margin from the picture, so captions on 2.39:1 content sit above the
    /// letterbox rather than down in the black bar.
    ///
    /// `.zero` until an item reports one, and on the software path (no
    /// AVPlayer). Callers treat `.zero` as "assume the video fills the view".
    @Published private(set) var videoSize: CGSize = .zero

    /// Per-player / per-item observers for `videoSize`. Held separately from
    /// `cancellables` because they are replaced whenever the engine swaps its
    /// inner AVPlayer or item (audio-track switch, background reopen, the
    /// failure ladder), not torn down with the session.
    private var videoItemCancellable: AnyCancellable?
    private var videoSizeCancellable: AnyCancellable?

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
    private var externalSubtitleTimelineOffset: TimeInterval = 0
    private var providerSubtitleGeneration = 0
    private var providerSubtitleDownload: Task<URL, Error>?
    /// A committed candidate stays readable for engine background/audio reloads.
    private var providerSubtitleFile: URL?

    private func subtitleClockTime(_ time: TimeInterval) -> TimeInterval {
        guard let selected = engine.activeSubtitleTrackIndex,
              engine.subtitleTracks.contains(where: { $0.id == selected && $0.isExternal }) else { return time }
        return time + externalSubtitleTimelineOffset
    }

    @Published private(set) var audioTracks: [MediaTrack] = []
    /// Published so the host can rebuild its merged track list the moment the
    /// engine reports (symmetric with `audioTracks`). These carry engine stream
    /// indices as ids and NO forced bit / long title — `TrackMerge` folds Plex's
    /// metadata onto them.
    @Published private(set) var subtitleTracks: [MediaTrack] = []

    /// Whether the USER wants playback running. Mutated only by play()/pause()
    /// and set at load start (every load auto-plays). Deliberately NOT derived
    /// from engine state: tvOS auto-pauses the AVPlayer on resign-active and
    /// the engine's timeControlStatus sink flips its state to .paused
    /// synchronously, so engine state at background time always reads "paused"
    /// even for an actively watching user.
    private var userIntendsToPlay = false

    /// Read-only view of the intent above, for hosts that must not act on a
    /// session the user parked. The host stall watchdog reads it: engine state
    /// alone can't distinguish "stalled mid-playback" from "paused and idling"
    /// once the screensaver has the display (issue #247).
    var intendsToPlay: Bool { userIntendsToPlay }

    /// Set on didEnterBackground, cleared when the foreground reload runs.
    /// nil means "no background transit pending" (also skips the spurious
    /// willEnterForeground at cold launch).
    private var backgroundedAt: Date?

    private var foregroundReloadTask: Task<Void, Never>?

    /// True while a foreground reload is actually running, so repeated Play
    /// presses queue behind the rebuild instead of cancelling and restarting
    /// it. Cleared on every exit, including the deadline path.
    private var foregroundReloadInFlight = false

    /// Non-nil when the app returned from background with the user PAUSED:
    /// the torn-down session stays parked (clock intact, so the paused UI
    /// shows the true position) and play() performs the reload. Holds the
    /// background timestamp so the teardown-drain wait still applies.
    private var pendingReloadSince: Date?

    /// One file of a stacked title.
    struct PartFile {
        let url: URL
        let externalSubtitles: [SidecarSubtitle]
    }

    /// A stacked title (#399) plays one file at a time while the player reports
    /// the title's timeline: time and duration span every file, a seek into
    /// another file loads it, and only the last file's end is `.ended`.
    private var stack: StackedParts<PartFile>?
    private var partIndex = 0
    private var partStart: TimeInterval { stack?.starts[partIndex] ?? 0 }
    /// Arguments of the title's load, repeated for each file.
    private var partLoad: (headers: [String: String]?, audio: [String], subtitles: [String])?
    /// True while the next file loads: the engine's idle/loading states and
    /// zeroed clock belong to the swap, not to the title.
    private var isSwitchingPart = false
    private var prewarmedPart: Int?

    /// Warms a source's opening bytes so a later `load()` skips the cold open's round trips.
    /// URL and headers must be byte-identical to the load's, or the bytes are never adopted.
    /// Best-effort: declines when the origin has no free request slot.
    static func prewarm(url: URL, headers: [String: String]) async {
        let report = await AetherEngine.prewarm(url: url, httpHeaders: headers)
        if let declined = report.declined {
            print("[AetherPlayer] prewarm declined: \(declined)")
        }
    }

    init() {
        do {
            self.engine = try AetherEngine()
        } catch {
            fatalError("AetherEngine init failed: \(error)")
        }
        // The engine otherwise uses system trust alone, so a server the API
        // session accepts would browse and never play (#337).
        EngineTLS.serverTrustEvaluator = { PlexCertificateDelegate.trustsServer($0) }
        wireUpPublishers()
        observeAppLifecycle()
    }

    private func wireUpPublishers() {
        engine.$state
            // Read `errorInfo` on the PUBLISHING turn, not after the hop.
            // AetherEngine assigns it immediately before `state` and clears it
            // when state leaves `.error`, so it is exact here and merely
            // probably-still-there one runloop turn later. Pairing them in the
            // map costs a tuple and removes the question.
            .map { [engine] aetherState in (aetherState, engine.errorInfo) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] aetherState, errorInfo in
                guard let self else { return }
                self.engineIsPlaying = (aetherState == .playing)
                // Recompute BEFORE publishing the state so the view model's
                // ".playing while still buffering" reconciliation sees the
                // combined flag the moment a seek lands.
                self.recomputeIsBuffering()
                let state = Self.translate(aetherState, errorInfo: errorInfo)
                if state == .ended, !self.isSwitchingPart, let stack = self.stack, self.partIndex + 1 < stack.files.count {
                    self.isSwitchingPart = true
                    self.stateSubject.send(.buffering)
                    Task { await self.switchPart(to: self.partIndex + 1, at: 0) }
                    return
                }
                if self.isSwitchingPart, [.idle, .loading, .ended].contains(state) {
                    self.stateSubject.send(.buffering)
                    return
                }
                self.stateSubject.send(state)
            }
            .store(in: &cancellables)

        // AetherEngine 3.x moved the high-frequency clock off the engine's
        // own objectWillChange into a separate PlaybackClock (the engine
        // does NOT fire on clock ticks). Observe clock.$currentTime.
        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                guard let self, !self.isSwitchingPart else { return }
                self.timeSubject.send(t + self.partStart)
                self.prewarmNextPartIfNear(t)
            }
            .store(in: &cancellables)

        // Subtitles use sourceTime, not currentTime: it holds the on-screen frame during a
        // seek (engine #49), and on live sources cue PTS are on the source axis (engine #107).
        engine.clock.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                guard let self else { return }
                self.sourceTime = self.subtitleClockTime(t)
            }
            .store(in: &cancellables)

        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                // Under preserveASSMarkup an ASS/SSA track's cues are raw
                // event lines (the flag touches no other codec). Read the
                // active track now, after the main-queue hop, so a track
                // switch that landed first is already visible.
                let rawASS = self?.activeASSTrackInfo() != nil
                // Convert here: each cue's type is inferred as
                // AetherEngine.SubtitleCue (it cannot be named explicitly),
                // and the body cases are pattern-matched without naming them.
                self?.subtitleCues = cues.map { cue in
                    let body: AetherSubtitleCue.Body
                    switch cue.body {
                    case .text(let string):
                        body = rawASS ? .assEvents(string) : .text(string)
                    case .richText(let runs):
                        // Styled runs. Since engine 5.26.0 this is not just
                        // colour: bold / italic / underline / strikethrough,
                        // font face and size arrive too, and for EVERY text
                        // format — libavcodec converts SRT, WebVTT and
                        // teletext into ASS event lines, and the engine now
                        // parses the whole override set rather than colour
                        // alone. Whether any of it is painted is the
                        // renderer's call, per attribute, against the
                        // CaptionStyle.allowsContent* Video Override states.
                        body = .styledText(runs.map { run in
                            AetherSubtitleCue.StyledRun(
                                text: run.text,
                                color: run.color.map {
                                    UIColor(red: CGFloat($0.r) / 255,
                                            green: CGFloat($0.g) / 255,
                                            blue: CGFloat($0.b) / 255,
                                            alpha: 1)
                                },
                                isBold: run.isBold,
                                isItalic: run.isItalic,
                                isUnderlined: run.isUnderlined,
                                isStruckThrough: run.isStruckThrough,
                                fontName: run.fontName,
                                fontSize: run.fontSize
                            )
                        })
                    case .image(let image):
                        body = .image(cgImage: image.cgImage, position: image.position)
                    }
                    // Placement the source asked for (ASS \an / \pos), nil for
                    // nearly every cue. Bitmap cues carry their own geometry
                    // on the image, so placement is text-only upstream.
                    let placement = cue.placement.map {
                        AetherSubtitleCue.TextPlacement(alignment: $0.alignment, position: $0.position)
                    }
                    return AetherSubtitleCue(
                        id: cue.id,
                        startTime: cue.startTime,
                        endTime: cue.endTime,
                        body: body,
                        placement: placement
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
                self?.refreshASSTrack()
            }
            .store(in: &cancellables)

        // A sidecar's header arrives when its decode finishes, after the
        // track is already active.
        engine.$sidecarASSHeader
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshASSTrack() }
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
                self.observeVideoSize(of: avp)
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                guard let self else { return }
                // Since 7.22.0 the remote-HLS bypass lists AVPlayer's audio
                // tracks for information only, and the engine ignores
                // selectAudioTrack there. Publish none, so the Live TV audio
                // menu keeps switching through AVPlayer's media selection.
                self.audioTracks = self.engine.videoRoute == .remoteBypass
                    ? [] : tracks.map(Self.translateTrack)
            }
            .store(in: &cancellables)

        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?.subtitleTracks = tracks.map(Self.translateTrack)
            }
            .store(in: &cancellables)
    }

    /// Tracks `presentationSize` across item swaps. Observed in two hops
    /// rather than through a `\.currentItem?.presentationSize` key path:
    /// nested KVO through an optional chain is not reliably delivered, and a
    /// missed update would leave the overlay measuring against a stale
    /// aspect ratio for the whole session.
    private func observeVideoSize(of player: AVPlayer?) {
        videoSizeCancellable = nil
        guard let player else {
            videoItemCancellable = nil
            videoSize = .zero
            return
        }
        videoItemCancellable = player
            .publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                guard let self else { return }
                guard let item else {
                    self.videoSizeCancellable = nil
                    return
                }
                self.videoSizeCancellable = item
                    .publisher(for: \.presentationSize)
                    // A zero size is the pre-ready placeholder; publishing it
                    // would flip the overlay back to full-bounds mid-session.
                    .filter { $0.width > 0 && $0.height > 0 }
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] size in self?.videoSize = size }
            }
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

    /// Wraps a failed `engine.load` (live and VOD) in the engine's own classification.
    /// `errorInfo` is set just before the throw and tells an HTTP error from a non-media body.
    private func loadFailure(from error: Error) -> PlayerError {
        if let info = engine.errorInfo {
            return .engineFailure(kind: info.kind.rawValue, message: info.message)
        }
        return .loadFailed(String(describing: error))
    }

    /// Maps the engine's state, keeping its failure classification. A nil `errorInfo`
    /// on `.failed` maps to `.unknown`.
    private static func translate(_ s: PlaybackState,
                                  errorInfo: PlaybackErrorInfo?) -> UniversalPlaybackState {
        switch s {
        case .idle: return .idle
        case .loading: return .loading
        case .playing: return .playing
        case .paused: return .paused
        case .seeking: return .buffering
        case .ended: return .ended
        case .error(let message):
            guard let errorInfo else { return .failed(.unknown(message)) }
            return .failed(.engineFailure(kind: errorInfo.kind.rawValue,
                                          message: errorInfo.message))
        }
    }

    /// Domain and code of whatever failed underneath the engine's most recent
    /// error, for telemetry that wants to split one kind further.
    ///
    /// `sourceRefused` and `sourceRateLimited` put the origin's HTTP status in
    /// `underlyingCode`, which is the single field that answers RIVULET-19's
    /// open question: which non-media body the demuxer was handed. Kept off
    /// `PlayerError` because nothing in the UI branches on it.
    var lastEngineErrorUnderlying: (domain: String?, code: Int?)? {
        guard let info = engine.errorInfo else { return nil }
        guard info.underlyingDomain != nil || info.underlyingCode != nil else { return nil }
        return (info.underlyingDomain, info.underlyingCode)
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
            // The engine reports these from the container's disposition bits.
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
        /// Explicit per-delivery authority; empty prevents inheriting the media source's headers.
        var httpHeaders: [String: String]? = nil
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

    // MARK: - Background / foreground lifecycle

    /// Upstream AetherEngine tears the video pipeline down on tvOS background
    /// (releases the AVPlayer item, VT session, and loopback server; parks
    /// state = .paused) and expects the HOST to reload on foreground — its own
    /// foreground observer is compiled out on tvOS (#if os(iOS)). Without this
    /// reload the session stays torn down forever and playback can never
    /// resume (issue #215).
    private func observeAppLifecycle() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.backgroundedAt = Date()
                // A reload landing while backgrounded would rebuild the decode
                // session right before suspension — the wedge the engine's
                // teardown exists to prevent. Foreground return re-arms it.
                self?.foregroundReloadTask?.cancel()
            }
            .store(in: &cancellables)

        // didBecomeActive, not willEnterForeground: the engine's own teardown /
        // restore pair is keyed on didEnterBackground / didBecomeActive, so
        // arming and disarming have to observe the same two notifications or
        // the reload can race the engine's restore. A resign-active-only cycle
        // (screensaver, Control Center) delivers didBecomeActive without a
        // preceding background, and `reloadAfterBackgroundReturn` no-ops on the
        // nil `backgroundedAt`, so this stays a strict superset of the old
        // trigger rather than a new one.
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadAfterBackgroundReturn()
            }
            .store(in: &cancellables)
    }

    private func reloadAfterBackgroundReturn() {
        guard let backgroundedAt else { return }
        self.backgroundedAt = nil
        if userIntendsToPlay {
            startForegroundReload(since: backgroundedAt)
        } else {
            // Paused user: leave the session parked and reload on play()
            // instead. The engine preserves the playback clock through its
            // teardown, so the paused UI keeps the true position; an eager
            // rebuild-then-pause showed 0 (load's stopInternal zeroes the
            // clock and nothing re-anchors it until playback starts) and paid
            // for a pipeline the user might never resume. Scrubs while parked
            // still work: the engine defers pre-ready seeks and updates the
            // clock optimistically (#127), so the reload resumes at the
            // scrubbed position.
            pendingReloadSince = backgroundedAt
        }
    }

    /// Rebuilds the torn-down session at the preserved playhead. Bounded, and a failure
    /// re-arms the retry, since a stale connection can hang the reload as at cold start (#245).
    private func startForegroundReload(since: Date) {
        guard !foregroundReloadInFlight else { return }
        foregroundReloadTask?.cancel()
        foregroundReloadInFlight = true
        foregroundReloadTask = Task { [weak self] in
            defer { self?.foregroundReloadInFlight = false }
            // The engine's teardown holds a background task through a 3.5s
            // loopback socket drain after its synchronous stopInternal. It
            // exposes no handle to await, so on a quick app switch wait out
            // the remainder before rebuilding; a real background stay has
            // long finished and pays nothing.
            let drain = max(0, 4.0 - Date().timeIntervalSince(since))
            if drain > 0 { try? await Task.sleep(for: .seconds(drain)) }
            guard let self, !Task.isCancelled else { return }
            DiagLog.notice(.playback, "Foreground reload at \(Int(self.engine.currentTime))s")
            do {
                // No-ops if nothing is loaded or the session was stopped while
                // we waited (public stop() clears the engine's loadedURL). The
                // load auto-plays, which is correct: this path only runs when
                // the user intends playback.
                try await self.reloadWithDeadline()
                self.pendingReloadSince = nil
                DiagLog.notice(.playback, "Foreground reload done: \(self.engine.state) at \(Int(self.engine.currentTime))s")
            } catch {
                // Arm the deferred reload so the next Play press retries the
                // rebuild. Covers the playing-user entry too: that one reloads
                // eagerly with nothing armed, so without this a failure there
                // wedges the session just as badly.
                DiagLog.error(.playback, "Foreground reload failed: \(DiagLog.describe(error))")
                self.pendingReloadSince = since
            }
        }
    }

    /// `reloadAtCurrentPosition` under the same deadline the startup load uses.
    /// Same operation, same failure mode: a load that never returns has to
    /// become a thrown error, or the retry can never be reached.
    private func reloadWithDeadline() async throws {
        let deadline = AetherLoadTimeoutPolicy.startupLoadDeadline
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [engine] in
                try await engine.reloadAtCurrentPosition()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(deadline))
                throw AetherLoadTimeoutPolicy.TimedOut(seconds: deadline)
            }
            do {
                try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
        }
    }

    // MARK: - PlayerProtocol state

    var isPlaying: Bool { engine.state == .playing }
    var currentTime: TimeInterval { engine.currentTime + partStart }
    var duration: TimeInterval { stack?.duration ?? engine.duration }

    /// Duration updates. The engine publishes `duration` once the source is
    /// probed; the VM needs this (not just `timePublisher`) so Plex progress
    /// reports carry a real duration (viewOffset + watched threshold).
    var durationPublisher: AnyPublisher<TimeInterval, Never> {
        engine.$duration
            .receive(on: DispatchQueue.main)
            .map { [weak self] seconds in MainActor.assumeIsolated { self?.stack?.duration ?? seconds } }
            .eraseToAnyPublisher()
    }
    var bufferedTime: TimeInterval { engine.bufferedPosition + partStart }
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

    /// Seek lifecycle (AetherEngine 6.1.0), mapped to host terms. `seek(to:)`
    /// returns on accept, not on landing, so the clock ticks in between report
    /// a position the picture has left; this says which seek landed where, and
    /// which gave up. Aether only — the hls route's AVPlayer has no
    /// equivalent, and its `seek(to:)` completion already means landed.
    ///
    /// `.rejected` is dropped rather than forwarded: it stands alone with no
    /// `.began`, so there is never a hold for it to release.
    var seekEvents: AnyPublisher<SeekHoldEvent, Never> {
        engine.seekEvents
            .receive(on: DispatchQueue.main)
            .compactMap { [weak self] event -> SeekHoldEvent? in
                let start = MainActor.assumeIsolated { self?.partStart ?? 0 }
                let outcome: SeekHoldEvent.Outcome
                switch event.outcome {
                case .began: outcome = .began
                case .landed(let rendered): outcome = .landed(renderedTime: rendered + start)
                case .stalled, .superseded: outcome = .settledElsewhere
                case .rejected: return nil
                }
                return SeekHoldEvent(id: event.id, outcome: outcome, target: event.target + start)
            }
            .eraseToAnyPublisher()
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

    /// What a live load is for.
    enum LiveLoadRole {
        /// The one channel on screen: full rewind window, and the software
        /// deinterlacer wherever the channel may be interlaced.
        case fullscreen
        /// One of up to four multiview tiles decoding at once. Keeps the
        /// engine's own decode routing (it still sends MPEG-2 and declared
        /// interlace to software) rather than forcing four software decodes,
        /// and a short rewind window, since a tile is never scrubbed.
        case multiviewSlot
    }

    /// Whether the last live load handed the origin's HLS to AVPlayer as is
    /// (who renders its captions depends on it). Travels with the player when
    /// a session moves between surfaces.
    private(set) var isOnNativeLiveRoute = false

    /// The engine's decode path and source codec for the current load, as
    /// plain strings for telemetry.
    var videoRouteName: String { engine.videoRoute.rawValue }

    /// How the current Dolby Vision source is reaching the screen; nil when not DV.
    var dolbyVisionPlayback: DolbyVisionPlayback? {
        DolbyVisionPlayback(sourceProfile: engine.sourceDVProfile,
                            convertedTo81: engine.dolbyVisionConversion == .profile7ToProfile81,
                            onSoftwareRoute: isOnSoftwareRoute,
                            presentsDolbyVision: engine.videoFormat == .dolbyVision,
                            presentsHDR: engine.videoFormat != .sdr)
    }
    var sourceVideoCodecName: String? { engine.sourceVideoCodecName }
    /// FEL or MEL for the current Profile 7 load; nil when the engine didn't classify it (FEL setting off, no DV panel).
    private(set) var dolbyVisionEnhancementLayer: DolbyVisionEnhancementLayer?

    /// The start of a fullscreen live join, measured for issue #319. See
    /// LiveAVTelemetry.
    private var avCapture: LiveAVCapture?
    private var avCaptureTask: Task<Void, Never>?
    /// Which capture holds the engine's global log handler.
    private static var engineLogCapture: LiveAVCapture?

    private func startAVCapture(url: URL) {
        let capture = LiveAVCapture(url: url)
        avCapture = capture
        Self.engineLogCapture = capture
        // @Sendable, so neither closure is inferred main-actor: the engine
        // calls both on its own threads.
        EngineLog.handler = { @Sendable line in capture.ingest(line: line) }
        engine.setSoftwareVideoFrameTimeObserver { @Sendable time in
            capture.frame(pts: time.presentation.seconds)
        }
    }

    /// Report what the capture has, if the join got as far as sound and a
    /// picture, and stop listening.
    func finishAVCapture() {
        avCaptureTask?.cancel()
        avCaptureTask = nil
        guard let capture = avCapture else { return }
        avCapture = nil
        engine.setSoftwareVideoFrameTimeObserver(nil)
        if Self.engineLogCapture === capture {
            // ponytail: one global handler; a second fullscreen join replaces it.
            EngineLog.handler = nil
            Self.engineLogCapture = nil
        }
        if let sample = capture.sample() { LiveAVTelemetry.report(sample) }
    }

    /// Live TV load. HLS sources go to AVPlayer directly (`nativeRemoteHLS`), anything else
    /// through the engine's remux. `forceEngineDemux` makes the engine open the playlist, the
    /// fallback when a server rejects AVPlayer's request pattern.
    func loadLive(url: URL, headers: [String: String]?, forceEngineDemux: Bool = false,
                  role: LiveLoadRole = .fullscreen) async throws {
        finishAVCapture()
        invalidateProviderSubtitlePreparation()
        removeProviderSubtitleFile()
        dropFrameExtractor()
        if role == .fullscreen { startAVCapture(url: url) }
        let isHLS = Self.liveRoute(for: url, forceEngineDemux: forceEngineDemux) == .nativeHLS
        isOnNativeLiveRoute = isHLS
        // Forced onto the engine demuxer AND the source is a playlist: the Plex
        // direct-play case. See the ingest branch below.
        let usesHLSIngest = !isHLS && Self.isHLSURL(url)
        let httpHeaders = headers ?? [:]
        // A wireless receiver (HomePod, an AirPlay speaker) buffers about two
        // seconds before its first sample sounds. A join that starts the clock
        // the moment a frame is ready plays that stretch as silent picture and
        // then snaps into sync (issue #319). Mount paused instead, and let the
        // start wait for the route: see the priming step after the load.
        let joinsWirelessAudio = Self.isWirelessAudioRoute()

        func makeOptions(nativeRemoteHLS: Bool) -> LoadOptions {
            var options = LoadOptions(
                suppressDisplayCriteria: false,
                httpHeaders: httpHeaders,
                // Same rich config as VOD, plus the live-specific flags.
                matchContentEnabled: true,
                panelIsInHDRMode: Self.panelIsInHDRMode(),
                audioBridgeMode: .lossless,
                isLive: true,
                // ~30-minute DVR rewind window (engine retains it disk-backed).
                dvrWindowSeconds: role == .fullscreen ? 1800 : 120,
                nativeRemoteHLS: nativeRemoteHLS,
                preserveASSMarkup: true,
                probesize: 5 * 1024 * 1024,
                maxAnalyzeDuration: 5_000_000,
                // Honor the user's saved audio/subtitle language preferences, same
                // as VOD, so the right tracks are picked on the first frame.
                preferredAudioLanguages: Self.livePreferredAudioLanguages(),
                preferredSubtitleLanguages: Self.livePreferredSubtitleLanguages(),
                // DVB teletext caption page. libzvbi auto-detect (nil) only finds a
                // page the broadcast FLAGS as a subtitle page; AU FTA channels carry
                // captions on 801 without that flag, so auto-detect returns nothing.
                // Region-default to 801 for AU, otherwise auto-detect.
                teletextPage: Self.regionTeletextPage(),
                // Software path (bwdif) only where PMS's tune says the channel is interlaced;
                // the engine's SPS check covers other sources (#150). Ignored on native HLS.
                preferredDecodePath: (role == .fullscreen && !nativeRemoteHLS && Self.needsDeinterlacing(url))
                    ? .software : .automatic
            )
            // Segments cut at every keyframe join in seconds instead of waiting
            // out the standard ~18s holdback (loopback joins measured 8-34s, #415).
            // Costs rewind depth on short-GOP channels: the playlist caps at 900 segments.
            options.liveJoinProfile = .fastZap
            if role == .multiviewSlot {
                // Field-rate deinterlacing on a quarter-screen tile only
                // doubles decoder output for nothing.
                options.deinterlaceFieldRate = .frame
            }
            if joinsWirelessAudio {
                // AVPlayer's own start-up wait is what rides out the receiver's
                // buffer on the native routes; the one-shot that cuts it short
                // is exactly wrong here.
                options.liveJoinStartsImmediately = false
                options.autoplay = false
            }
            return options
        }

        let options = makeOptions(nativeRemoteHLS: isHLS)

        // Same reason as the VOD path: a zap is new content, and broadcast
        // mixes 4:3 SD with 16:9 HD channel to channel, so a reused slot must
        // not measure the new channel against the old one's picture rect.
        videoSize = .zero
        userIntendsToPlay = true
        pendingReloadSince = nil
        do {
            // A Plex direct-play part key is an HLS playlist, which the raw live path
            // rejects (AE#140). HLSLiveIngestReader demuxes its MPEG-TS so mp2 and teletext survive.
            if usesHLSIngest {
                // The reader does its own HTTP on its own session, so the
                // headers have to be handed to it here: `LoadOptions.httpHeaders`
                // never reaches a custom IOReader (AE#119).
                let reader = HLSLiveIngestReader(playlistURL: url, httpHeaders: httpHeaders)
                do {
                    try await engine.load(source: .custom(reader, formatHint: "mpegts"), options: options)
                } catch {
                    // The reader does not throw out of `read`: it records why it
                    // gave up and the probe fails as a `DemuxerError`, so the
                    // error type says nothing. Its own verdict does. Encryption or
                    // an fMP4 playlist it will not open: retry natively on the
                    // SAME session rather than letting the host fall back, which
                    // costs another tune and, on a single-tuner box, competes with
                    // the grab we are already holding.
                    guard reader.terminalError != nil, !isCancellationError(error) else { throw error }
                    try await engine.load(
                        url: url,
                        startPosition: nil,
                        options: makeOptions(nativeRemoteHLS: true)
                    )
                }
            } else {
                try await engine.load(url: url, startPosition: nil, options: options)
            }
            if let capture = avCapture {
                capture.setCodec(engine.sourceVideoCodecName)
                // Long enough for the prime, the start, and the 5 s from the
                // start that vlead_min skips, with ten seconds of it measured.
                avCaptureTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(18))
                    if !Task.isCancelled { self?.finishAVCapture() }
                }
            }
            if joinsWirelessAudio && isOnSoftwareRoute {
                // The software backend renders on a sample-buffer synchronizer
                // with no player to wait on the route, so hold the mounted,
                // paused session for the receiver's latency. A live source keeps
                // filling while paused, so when the caller's play() starts the
                // clock the audio renderer already has that much queued and the
                // receiver starts in sync instead of catching up.
                try? await Task.sleep(for: .seconds(Self.wirelessAudioPrimeSeconds()))
            }
        } catch {
            // The caller left the slot / retuned while the load was in flight.
            // Rethrow untouched so the type survives; wrapping it in a
            // PlayerError makes it indistinguishable from a real failure.
            if isCancellationError(error) { throw error }
            let pe = loadFailure(from: error)
            errorSubject.send(pe)
            throw pe
        }
    }

    /// Whether audio is leaving this device for an AirPlay receiver.
    private static func isWirelessAudioRoute() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    /// How long a software-route live join holds for a wireless receiver: the
    /// route's own reported latency, bounded so a route that reports nothing
    /// useful still gets the typical two seconds and a bad reading cannot
    /// stall the join.
    private static func wirelessAudioPrimeSeconds() -> Double {
        let reported = AVAudioSession.sharedInstance().outputLatency
        guard reported > 0.2 else { return 2.0 }
        return min(max(reported, 1.0), 3.0)
    }

    /// Which path `loadLive` will take for this URL. Single source of truth: the
    /// load itself routes through this, so live-join telemetry can tag the real
    /// decision instead of re-deriving the predicate and drifting from it.
    ///
    /// This is the distinction that decides whether AetherEngine's
    /// `LoadOptions.liveJoinProfile` (`.fastZap`) can do anything at all: the
    /// engine reads it only when building the loopback segment producer, so it
    /// is inert on `.nativeHLS`.
    static func liveRoute(for url: URL, forceEngineDemux: Bool) -> LiveJoinRoute {
        (isHLSURL(url) && !forceEngineDemux) ? .nativeHLS : .loopback
    }

    /// Whether this live source has to take the deinterlacing path.
    ///
    /// Reads `rivuletLiveScanType`, which `PlexLiveTVProvider` puts on the URL from the tune.
    /// A missing scan type means no: software decode of 4K60 HEVC drops ~14 fps on an
    /// Apple TV 4K (2nd gen).
    static func needsDeinterlacing(_ url: URL) -> Bool {
        guard let scan = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "rivuletLiveScanType" })?.value?
            .lowercased() else { return false }
        return scan != "progressive"
    }

    private static func isHLSURL(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "m3u8" { return true }
        let text = url.absoluteString.lowercased()
        return text.contains(".m3u8") || text.contains("format=hls")
    }

    /// Speaker layout ("7.1.4"…) object audio renders into; absent = off.
    static let heightSpeakersKey = "heightSpeakers"

    /// Profile 7 FEL composition; absent = off.
    static let dolbyVisionFELKey = "dolbyVisionFEL"
    private static let felDefaultSettledKey = "dolbyVisionFELDefaultSettled"

    /// FEL used to default on. Once, pin it on for an install that already had a server,
    /// so only new installs get the off default.
    static func settleFELDefault(existingInstall: Bool, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: felDefaultSettledKey) else { return }
        defaults.set(true, forKey: felDefaultSettledKey)
        if existingInstall, defaults.object(forKey: dolbyVisionFELKey) == nil {
            defaults.set(true, forKey: dolbyVisionFELKey)
        }
    }

    /// DVB teletext caption page, applied to BOTH live and VOD loads. A
    /// `liveTeletextPage` UserDefaults key overrides everything (0 = force
    /// libzvbi auto-detect); otherwise Australian regions default to 801
    /// (AU FTA carries captions there without flagging it as a subtitle page,
    /// so auto-detect misses it) and every other region uses libzvbi's
    /// flagged-page auto-detect (nil) — identical to prior behavior.
    private static func regionTeletextPage() -> Int? {
        if let stored = UserDefaults.standard.object(forKey: "liveTeletextPage") as? Int {
            return stored == 0 ? nil : stored
        }
        return Locale.current.region?.identifier == "AU" ? 801 : nil
    }

    /// The user's saved audio-language intent (ISO code), if any.
    private static func livePreferredAudioLanguages() -> [String] {
        let lang = TrackIntentStore.effectiveAudioIntent.language
        return lang.isEmpty || lang == TrackLanguage.original ? [] : [lang]
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
        externalSubtitleTimelineOffset: TimeInterval = 0,
        isLive: Bool = false,
        stackedParts: StackedParts<PartFile>? = nil
    ) async throws {
        stack = stackedParts
        prewarmedPart = nil
        guard let stackedParts else {
            partIndex = 0
            partLoad = nil
            try await loadFile(url: url, headers: headers, startTime: startTime,
                               preferredAudioLanguages: preferredAudioLanguages,
                               preferredSubtitleLanguages: preferredSubtitleLanguages,
                               externalSubtitles: externalSubtitles,
                               externalSubtitleTimelineOffset: externalSubtitleTimelineOffset, isLive: isLive)
            return
        }
        partLoad = (headers, preferredAudioLanguages, preferredSubtitleLanguages)
        let (index, offset) = stackedParts.locate(startTime ?? 0)
        partIndex = index
        try await loadFile(url: stackedParts.files[index].url, headers: headers, startTime: offset,
                           preferredAudioLanguages: preferredAudioLanguages,
                           preferredSubtitleLanguages: preferredSubtitleLanguages,
                           externalSubtitles: stackedParts.files[index].externalSubtitles, isLive: false)
    }

    /// Opens another file of the stacked title at `offset` within it, keeping
    /// the track picks and the paused state. The last frame holds through the gap.
    private func switchPart(to index: Int, at offset: TimeInterval) async {
        isSwitchingPart = true
        defer { isSwitchingPart = false }
        guard let stack, let partLoad, stack.files.indices.contains(index) else { return }
        let audio = activeAudioTrackId
        let subtitle = activeSubtitleTrackId
        let wasPlaying = userIntendsToPlay
        DiagLog.notice(.playback, "Stacked title: part \(index + 1) of \(stack.files.count) at \(Int(offset))s")
        partIndex = index
        engine.prepareForItemReplacement()
        do {
            try await loadFile(url: stack.files[index].url, headers: partLoad.headers, startTime: offset,
                               preferredAudioLanguages: partLoad.audio,
                               preferredSubtitleLanguages: partLoad.subtitles,
                               externalSubtitles: stack.files[index].externalSubtitles, isLive: false)
        } catch {
            // The load already published the failure.
            return
        }
        // Stream indexes match across the files of one release.
        if let audio, audio != activeAudioTrackId, audioTracks.contains(where: { $0.id == audio }) {
            selectAudioTrack(id: audio)
        }
        if subtitle != activeSubtitleTrackId, subtitle.map({ id in subtitleTracks.contains { $0.id == id } }) ?? true {
            selectSubtitleTrack(id: subtitle)
        }
        if !wasPlaying { pause() }
    }

    /// Warms the next file's opening bytes in the last 30s of this one.
    private func prewarmNextPartIfNear(_ time: TimeInterval) {
        guard let stack, let headers = partLoad?.headers, partIndex + 1 < stack.files.count,
              prewarmedPart != partIndex + 1,
              stack.starts[partIndex + 1] - (time + partStart) < 30 else { return }
        prewarmedPart = partIndex + 1
        let url = stack.files[partIndex + 1].url
        Task.detached { await Self.prewarm(url: url, headers: headers) }
    }

    private func loadFile(
        url: URL,
        headers: [String: String]?,
        startTime: TimeInterval?,
        preferredAudioLanguages: [String],
        preferredSubtitleLanguages: [String],
        externalSubtitles: [SidecarSubtitle],
        externalSubtitleTimelineOffset: TimeInterval = 0,
        isLive: Bool
    ) async throws {
        invalidateProviderSubtitlePreparation()
        removeProviderSubtitleFile()
        // .lossless: FLAC for non-stream-copy audio, ~3x realtime on A15 against EAC3's
        // ~0.5x, so 4K segments keep up. Needs a multichannel LPCM sink; others downmix.
        // subtitleLanguageHintsByStreamIndex is unused (the engine has no such parameter).
        // isLive must be declared: the engine does not auto-detect live (broken MKV durations).
        // Reanchored HLS sidecars retain source timestamps. Register those after load
        // for the host overlay, not a native WebVTT rendition on the player's axis.
        self.externalSubtitleTimelineOffset = externalSubtitleTimelineOffset
        let sidecars = externalSubtitles.map { sub in
            ExternalSubtitleTrack(
                url: sub.url, name: sub.name, language: sub.language,
                isForced: sub.isForced, isHearingImpaired: sub.isHearingImpaired,
                isDefault: sub.isDefault, httpHeaders: sub.httpHeaders, formatHint: sub.formatHint
            )
        }
        var options = LoadOptions(
            suppressDisplayCriteria: false,
            httpHeaders: headers ?? [:],
            matchContentEnabled: true,
            panelIsInHDRMode: Self.panelIsInHDRMode(),
            audioBridgeMode: .lossless,
            isLive: isLive,
            // ASS/SSA cues arrive as raw event lines for libass, with the header
            // on TrackInfo.assHeader / sidecarASSHeader and fonts on
            // fontAttachments. The flag touches no other codec.
            preserveASSMarkup: true,
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            externalSubtitles: externalSubtitleTimelineOffset == 0 ? sidecars : [],
            // Same teletext rule as Live TV: a teletext stream decodes the same
            // way whichever surface plays it (VOD recordings/rips included).
            teletextPage: Self.regionTeletextPage()
        )
        // Settings → Playback → Height Speakers: TrueHD Atmos and DTS:X keep their heights as a
        // rendered bed (lossless PCM, APAC on AirPlay) instead of 7.1 without them.
        let heightLayout = SpatialSpeakerLayout(rawValue: UserDefaults.standard.string(forKey: Self.heightSpeakersKey) ?? "")
        if let heightLayout { options.objectAudioRendering = .render(heightLayout) }
        // Profile 7 FEL composes both layers (#345). The engine doesn't check the panel,
        // so keep the native route (HDR10 base) where the TV can't show Dolby Vision.
        // The FEL route renders heights too, so both settings apply to one title (#362).
        let panelDV = AetherEngine.displayCapabilities.supportsDolbyVision
        let felOn = UserDefaults.standard.bool(forKey: Self.dolbyVisionFELKey)
        options.preferDualLayerDolbyVision = panelDV && felOn
        // #362: catch the engine's one Profile 7 route line for Sentry. Live TV's capture owns the
        // handler while it runs, and VOD never loads then.
        let p7RouteLine = OSAllocatedUnfairLock<String?>(initialState: nil)
        let ownsLogHandler = EngineLog.handler == nil
        if ownsLogHandler {
            EngineLog.handler = { @Sendable line in
                if line.contains("DV P7 dual-layer route:") { p7RouteLine.withLock { $0 = line } }
            }
        }
        defer { if ownsLogHandler { EngineLog.handler = nil } }
        // New content, so the previous item's aspect ratio describes nothing.
        // Reset HERE rather than when `currentItem` goes nil: the engine also
        // swaps its player for SAME-content reasons (audio track switch,
        // background reopen), and zeroing on those would flash the caption
        // overlay out to full bounds for no reason. A next-episode swap reuses
        // this instance, so without this the overlay measures the new episode
        // against the old episode's picture rect until `presentationSize`
        // arrives.
        videoSize = .zero
        dolbyVisionEnhancementLayer = nil
        // New file: the previous track's script and fonts describe nothing,
        // even when the next episode repeats the same header and track id.
        assFonts = []
        assTrack = nil
        dropFrameExtractor()
        userIntendsToPlay = true
        pendingReloadSince = nil
        do {
            try await engine.load(url: url, startPosition: startTime, options: options)
            if externalSubtitleTimelineOffset != 0 {
                for sidecar in sidecars { engine.addExternalSubtitleTrack(sidecar) }
            }
        } catch {
            // User navigated away / switched items mid-load. Rethrow untouched
            // and stay off errorSubject: wrapping it as PlayerError.loadFailed
            // destroys the type, so downstream can no longer tell a
            // cancellation from a genuine startup failure (RIVULET-19).
            if isCancellationError(error) { throw error }
            let pe = loadFailure(from: error)
            errorSubject.send(pe)
            throw pe
        }
        if let routeLine = p7RouteLine.withLock({ $0 }) {
            dolbyVisionEnhancementLayer = DolbyVisionEnhancementLayer(routeLine: routeLine)
            SentryBridge.log(.info, "DV P7 route", attributes: [
                "engine_route": routeLine,
                "panel_dv": panelDV,
                "height_speakers": heightLayout?.rawValue ?? "off",
                "fel_setting": felOn
            ])
        }
        assFonts = engine.fontAttachments.map { LibassRenderer.Font(name: $0.filename, data: $0.data) }
        // The track may have been published during the load with no fonts;
        // republish so the renderer is built with them.
        assTrack = nil
        refreshASSTrack()
    }

    /// The engine's active subtitle track when it is ASS/SSA.
    private func activeASSTrackInfo() -> TrackInfo? {
        guard let index = engine.activeSubtitleTrackIndex,
              let track = engine.subtitleTracks.first(where: { $0.id == index }),
              ["ass", "ssa"].contains(track.codec.lowercased()) else { return nil }
        return track
    }

    /// Publishes `assTrack` for the active track. A new instance whenever the
    /// track id or header changes: two tracks from one release can share a
    /// header, and each needs its own libass track.
    ///
    /// Relies on AetherEngine (re-checked at 7.25.3) clearing `subtitleCues` BEFORE it publishes
    /// a new `activeSubtitleTrackIndex` (embedded select, sidecar select and
    /// stop all do), so the overlay's new libass track never receives the old
    /// track's lines. Re-check that ordering on every engine bump.
    private func refreshASSTrack() {
        guard let track = activeASSTrackInfo(),
              let header = track.isExternal ? engine.sidecarASSHeader : track.assHeader else {
            if assTrack != nil { assTrack = nil }
            return
        }
        if let current = assTrack, current.trackId == track.id, current.header == header { return }
        assTrack = ASSTrackSource(trackId: track.id, header: header, fonts: assFonts)
    }

    /// The cue-axis (source) time the video shows at `hostTime`, a
    /// `CACurrentMediaTime()` / `CADisplayLink.targetTimestamp` reading, or
    /// nil when no presentation timebase exists. `sourceTime` ticks at 10 Hz
    /// (native) or 4 Hz (software); libass animation needs one reading per
    /// display frame.
    func sourceTime(atHostTime hostTime: CFTimeInterval) -> Double? {
        let host = CMTime(seconds: hostTime, preferredTimescale: 1_000_000_000)
        if let timebase = engine.softwarePresentationTimebase {
            // The software path presents on the source axis already.
            let t = CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: timebase)
            return t.isNumeric ? subtitleClockTime(t.seconds) : nil
        }
        guard let timebase = engine.currentAVPlayerItem?.timebase else { return nil }
        let item = CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: timebase)
        guard item.isNumeric else { return nil }
        return engine.presentationAxisMap.sourceSeconds(forItemSeconds: item.seconds).map { subtitleClockTime($0) }
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

    func play() {
        userIntendsToPlay = true
        if let since = pendingReloadSince {
            // Parked since a paused background return: rebuild the torn-down
            // session (auto-plays at the preserved clock position) instead of
            // playing into a session with no player item. The flag stays armed
            // until the rebuild succeeds, so a Play press after a failed or
            // timed-out one retries rather than no-opping forever.
            startForegroundReload(since: since)
            return
        }
        engine.play()
    }
    func pause() {
        userIntendsToPlay = false
        engine.pause()
    }
    func stop() { stop(resetDisplayCriteria: true) }

    /// `resetDisplayCriteria: false` keeps the TV's mode for a following load
    /// on this player, so a same-format channel change makes no HDMI switch (#419).
    func stop(resetDisplayCriteria: Bool) {
        invalidateProviderSubtitlePreparation()
        foregroundReloadTask?.cancel()
        pendingReloadSince = nil
        userIntendsToPlay = false
        stack = nil
        partIndex = 0
        finishAVCapture()
        dropFrameExtractor()
        engine.stop(resetDisplayCriteria: resetDisplayCriteria)
        removeProviderSubtitleFile()
    }

    deinit {
        providerSubtitleDownload?.cancel()
        if let providerSubtitleFile { try? FileManager.default.removeItem(at: providerSubtitleFile) }
        if let extractor = frameExtractor { Task { await extractor.shutdown() } }
    }

    /// A low-res still of the loaded item at `seconds`, for the scrub bar.
    /// Keyframe-snapped and cached by the engine, and it yields while playback
    /// is starved. nil with no engine session (the hls route) or when the
    /// source cannot open a second reader.
    func scrubFrame(atSeconds seconds: TimeInterval, maxWidth: Int = 320) async -> CGImage? {
        // A stacked title's stills come from the open file only.
        let local = stack.map { $0.locate(seconds) }
        if let local, local.index != partIndex { return nil }
        if frameExtractor == nil { frameExtractor = engine.makeFrameExtractor() }
        guard let extractor = frameExtractor else { return nil }
        return await extractor.thumbnail(at: local?.offset ?? seconds, maxWidth: maxWidth)
    }

    private func dropFrameExtractor() {
        guard let extractor = frameExtractor else { return }
        frameExtractor = nil
        Task { await extractor.shutdown() }
    }

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

    /// A render surface typed as a plain view, so a host can show video
    /// without naming the engine's own view type. Bind it with
    /// `bind(surface:)`.
    static func makeRenderSurface() -> UIView {
        AetherPlayerView()
    }

    func bind(surface: UIView) {
        guard let view = surface as? AetherPlayerView else { return }
        engine.bind(view: view)
    }

    func unbind(surface: UIView) {
        guard let view = surface as? AetherPlayerView else { return }
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

    /// Bumped per `playbackAudio()` stream, so an ended stream can tell it no longer owns the tap.
    private var audioTapOwner = 0

    /// Decoded playback audio for on-device speech (the engine's audio tap):
    /// mono 48 kHz on the source axis, up to ~10 s ahead of the playhead on the
    /// loopback route. Surround sources deliver the centre (dialogue) channel
    /// alone; stereo falls back to the downmix. The tap ends on every load or
    /// reload, so it is re-installed until the stream is cancelled.
    func playbackAudio() -> AsyncStream<PlaybackAudioChunk> {
        let (stream, continuation) = AsyncStream<PlaybackAudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let engine = self?.engine else { break }
                let tap = engine.installAudioTap(channels: .dialogue)
                if engine.audioTapHasDeliverySource {
                    var first = true
                    for await buffer in tap {
                        continuation.yield(PlaybackAudioChunk(
                            buffer: buffer.buffer, sourceTime: buffer.sourceTime,
                            discontinuity: buffer.discontinuity || first))
                        first = false
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
            continuation.finish()
        }
        audioTapOwner += 1
        let owner = audioTapOwner
        continuation.onTermination = { _ in
            task.cancel()
            // A newer stream may already own the engine's one tap; only the latest removes it.
            Task { @MainActor [weak self] in
                guard let self, self.audioTapOwner == owner else { return }
                self.engine.removeAudioTap()
            }
        }
        return stream
    }

    func seek(to time: TimeInterval) async {
        guard let stack else { return await engine.seek(to: time) }
        let (index, offset) = stack.locate(time)
        // ponytail: a seek during a part swap starts a second load; queue it if that ever misbehaves.
        if index == partIndex {
            await engine.seek(to: offset)
        } else {
            await switchPart(to: index, at: offset)
        }
    }

    // MARK: - Live timeshift

    /// The live rewind window, as a host draws it. Every time here is on the
    /// session axis, the one `currentTime` reports and `seek(to:)` takes on a
    /// live session. Never `sourceTime`: on the software live path that axis is
    /// offset by the session zero.
    struct LiveTimeshift: Equatable {
        /// What a seek can reach. nil when the session has no rewind window
        /// (a live-only load, or before the first segment lands).
        var seekableRange: ClosedRange<Double>?
        var edgeTime: Double
        var playhead: Double
        var behindLiveSeconds: Double
        var isAtLiveEdge: Bool

        /// No session yet: nothing to rewind, and nothing behind.
        static let idle = LiveTimeshift(seekableRange: nil, edgeTime: 0, playhead: 0,
                                        behindLiveSeconds: 0, isAtLiveEdge: true)
    }

    /// A snapshot of the live window. Cheap: these are the clock's own
    /// published values, which the engine keeps current even while paused.
    var liveTimeshift: LiveTimeshift {
        let clock = engine.clock
        return LiveTimeshift(
            seekableRange: clock.seekableLiveRange,
            edgeTime: clock.liveEdgeTime,
            playhead: clock.currentTime,
            behindLiveSeconds: clock.behindLiveSeconds,
            isAtLiveEdge: clock.isAtLiveEdge
        )
    }

    /// Move a live session by `seconds`, clamped to what the rewind window
    /// still holds. Landing within a second of the edge snaps to the edge
    /// itself, so skipping forward to "now" reads as live rather than as one
    /// second behind. False when there is no window to move in.
    @discardableResult
    func seekLive(by seconds: Double) async -> Bool {
        await seekLive(to: liveTimeshift.playhead + seconds)
    }

    /// Move a live session to `sessionSeconds` on the session axis (the one
    /// `liveTimeshift` reports), with the same clamping and snap to live.
    @discardableResult
    func seekLive(to sessionSeconds: Double) async -> Bool {
        let shift = liveTimeshift
        guard let range = shift.seekableRange else { return false }
        let target = min(max(sessionSeconds, range.lowerBound), shift.edgeTime)
        if shift.edgeTime - target < 1 {
            await engine.seekToLiveEdge()
        } else {
            await engine.seek(to: target)
        }
        return true
    }

    /// Back to the live edge. Works without a rewind window too.
    func seekToLiveEdge() async {
        await engine.seekToLiveEdge()
    }

    /// A still from the rewind window at `sessionSeconds`, decoded from what
    /// the session already holds (no network). nil outside the window, on the
    /// remote-HLS bypass, or across a channel change.
    func liveThumbnail(atSessionSeconds sessionSeconds: Double, maxWidth: Int = 320) async -> CGImage? {
        await engine.liveScrubThumbnail(atSessionSeconds: sessionSeconds, maxWidth: maxWidth)
    }

    /// True once the current load has its first frame on screen (an audio-only
    /// load: once ready). `.playing` is not that: the software path reports it
    /// before a single frame is decoded (#323).
    var hasPresented: AnyPublisher<Bool, Never> {
        engine.$startupProgress.map { $0?.isComplete == true }.removeDuplicates().eraseToAnyPublisher()
    }

    /// Fires when the engine has given up on a live source (a transcode that
    /// respawned from byte 0, a frozen playlist, the reopen budget spent). The
    /// session is parked; only a fresh URL and a new load revive it, which for
    /// Plex means a new tune. Without a subscriber a dead channel just looks
    /// slow forever.
    var liveSourceResets: AnyPublisher<Void, Never> {
        engine.liveSourceReset.eraseToAnyPublisher()
    }

    /// Seconds skipped when resuming a paused live session whose rewind window
    /// had already dropped the paused position.
    var liveResumeSkips: AnyPublisher<Double, Never> {
        engine.liveResumeClamped.map(\.skippedSeconds).eraseToAnyPublisher()
    }

    /// The DVB teletext page captions come from; nil means the engine's
    /// auto-detect. Changing it re-decodes at once.
    var teletextPage: Int? { engine.teletextPage }

    func setTeletextPage(_ page: Int?) {
        engine.setTeletextPage(page)
    }

    /// True while the software backend is serving the session. Live joins use
    /// it: that backend has no player of its own to ride out a wireless audio
    /// route's start-up latency (see `loadLive`).
    var isOnSoftwareRoute: Bool { engine.videoRoute == .software }

    // MARK: - Tracks

    var currentAudioTrackId: Int? { activeAudioTrackId }
    var currentSubtitleTrackId: Int? { activeSubtitleTrackId }

    func selectAudioTrack(id: Int) {
        invalidateProviderSubtitlePreparation()
        engine.selectAudioTrack(index: id)
    }

    func selectSubtitleTrack(id: Int?) {
        invalidateProviderSubtitlePreparation()
        if let id {
            engine.selectSubtitleTrack(index: id)
        } else {
            engine.clearSubtitle()
        }
    }

    /// Decode a fresh, bounded text sidecar before changing any visible cues.
    /// The caller's identity fence complements the engine's load/intent fence:
    /// a provider menu pick may be queued without touching the engine yet.
    @discardableResult
    func replaceProviderSubtitle(
        _ track: SubtitleTrack?, timelineOffset: TimeInterval,
        isCurrent: @MainActor () -> Bool
    ) async throws -> Bool {
        invalidateProviderSubtitlePreparation()
        let generation = providerSubtitleGeneration
        guard isCurrent() else { throw CancellationError() }
        if let track, !track.isEmbedded {
            guard let url = track.externalURL else { return false }
            let format = track.codec.lowercased()
            guard ["srt", "vtt", "ass", "ssa"].contains(format) else {
                throw ExternalSubtitlePreparationError.unsupportedFormat
            }
            let policy = ExternalSubtitlePreparationPolicy()
            let download = Task {
                try await Self.downloadProviderSubtitle(
                    url, headers: track.externalHTTPHeaders ?? [:],
                    format: format, maximumBytes: policy.maximumFileBytes)
            }
            providerSubtitleDownload = download
            defer {
                if generation == providerSubtitleGeneration { providerSubtitleDownload = nil }
            }
            let file = try await withTaskCancellationHandler {
                try await download.value
            } onCancel: {
                download.cancel()
            }
            var installed = false
            defer { if !installed { try? FileManager.default.removeItem(at: file) } }
            try Task.checkCancellation()
            guard generation == providerSubtitleGeneration, isCurrent() else { throw CancellationError() }
            let candidate = try await engine.prepareExternalSubtitle(ExternalSubtitleTrack(
                url: file, name: track.extendedTitle ?? track.title, language: track.language,
                isForced: track.isForced, isHearingImpaired: track.isHearingImpaired,
                isDefault: track.isDefault, httpHeaders: [:], formatHint: format), policy: policy)
            defer { candidate.discard() }
            let nativeItem = engine.currentAVPlayer?.currentItem
            let nativeLegibleGroup: AVMediaSelectionGroup?
            if let nativeItem {
                nativeLegibleGroup = try await nativeItem.asset.loadMediaSelectionGroup(for: .legible)
            } else {
                nativeLegibleGroup = nil
            }
            try Task.checkCancellation()
            guard generation == providerSubtitleGeneration, isCurrent(),
                  engine.currentAVPlayer?.currentItem === nativeItem else { throw CancellationError() }
            let registered = try engine.commitExternalSubtitle(candidate)
            // HLS can still have the old injected rendition selected. Clear
            // that native option only after the prepared overlay commit wins.
            if let nativeItem, let nativeLegibleGroup {
                nativeItem.select(nil, in: nativeLegibleGroup)
            }
            // Commit and cleanup do not suspend. Failure above leaves the old
            // registry, decoded cues, active file and timeline offset untouched.
            externalSubtitleTimelineOffset = timelineOffset
            removeProviderExternalSubtitles(except: registered.id)
            removeProviderSubtitleFile()
            providerSubtitleFile = file
            installed = true
            return true
        }
        if let track {
            guard let index = track.nativeStreamIndex,
                  engine.subtitleTracks.contains(where: { !$0.isExternal && $0.id == index }) else { return false }
            engine.selectSubtitleTrack(index: index)
        } else {
            engine.clearSubtitle()
        }
        externalSubtitleTimelineOffset = timelineOffset
        removeProviderExternalSubtitles()
        removeProviderSubtitleFile()
        return true
    }

    func invalidateProviderSubtitlePreparation() {
        providerSubtitleGeneration &+= 1
        providerSubtitleDownload?.cancel()
        providerSubtitleDownload = nil
    }

    private func removeProviderExternalSubtitles(except retainedID: Int? = nil) {
        while let old = engine.subtitleTracks.first(where: { $0.isExternal && $0.id != retainedID }) {
            engine.removeExternalSubtitleTrack(id: old.id)
        }
    }

    private func removeProviderSubtitleFile() {
        if let providerSubtitleFile { try? FileManager.default.removeItem(at: providerSubtitleFile) }
        providerSubtitleFile = nil
    }

    /// Match the host's existing bounded AsyncBytes download pattern. Never
    /// forward credentials through redirects or reuse cached, uncorrected bytes.
    private nonisolated static func downloadProviderSubtitle(
        _ url: URL, headers: [String: String], format: String, maximumBytes: Int
    ) async throws -> URL {
        let data: Data
        if url.isFileURL {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= maximumBytes else {
                throw ExternalSubtitlePreparationError.resourceLimit
            }
            data = try Data(contentsOf: url, options: .uncached)
        } else {
            let session = URLSession(configuration: .ephemeral,
                                     delegate: ProviderSubtitleNoRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.allHTTPHeaderFields = headers
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.url == url else {
                throw ExternalSubtitlePreparationError.decodeFailed
            }
            guard response.expectedContentLength <= Int64(maximumBytes) else {
                throw ExternalSubtitlePreparationError.resourceLimit
            }
            var result = Data()
            result.reserveCapacity(min(maximumBytes, 256 * 1024))
            var chunk = [UInt8]()
            chunk.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == 64 * 1024 {
                    try Task.checkCancellation()
                    guard result.count <= maximumBytes - chunk.count else {
                        throw ExternalSubtitlePreparationError.resourceLimit
                    }
                    result.append(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            guard result.count <= maximumBytes - chunk.count else {
                throw ExternalSubtitlePreparationError.resourceLimit
            }
            result.append(contentsOf: chunk)
            data = result
        }
        guard !data.isEmpty else { throw ExternalSubtitlePreparationError.empty }
        guard data.count <= maximumBytes else { throw ExternalSubtitlePreparationError.resourceLimit }
        try Task.checkCancellation()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rivulet-caption-\(UUID().uuidString)").appendingPathExtension(format)
        do {
            try data.write(to: file, options: .atomic)
            try Task.checkCancellation()
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    /// Load a sidecar subtitle file (SRT, ASS, VTT, PGS) by URL.
    func prepareForReuse() {
        // No-op: AetherEngine doesn't have a reset-without-stop primitive.
        // stop() is called when the view model swaps players, and a fresh
        // AetherPlayer() instance is created for the next session.
    }

    // MARK: - Advanced stats (Info popup "stats for nerds" tab)

    /// Map the engine's `AudioDelivery` to a stats row, or nil to omit the row.
    ///
    /// Switched exhaustively with no `default` on purpose: this file is the only
    /// place an AetherEngine type is named, so a case the engine adds should
    /// fail the build here rather than silently render as a blank row.
    private static func audioDeliveryLabel(_ delivery: AudioDelivery) -> String? {
        switch delivery {
        case .none: return nil  // Pre-load or torn down: nothing to report yet.
        case .noAudioInSource: return "No audio in source"
        case .streamCopy: return "Stream copy"
        case .bridged: return "Bridged"
        case .decoded: return "Decoded"
        case .droppedNoPipeline: return "Video only (audio dropped)"
        case .playerManaged: return "AVFoundation"
        }
    }

    /// Keep the outgoing item on screen until the next `load()` replaces it.
    ///
    /// Call immediately before an episode swap that reuses this player. Video
    /// renders through the engine's own layer (`engine.bind(view:)`), so without
    /// this the gap between items is a black frame. Consumed by the next
    /// `load()`; a `stop()` in between cancels it, and it no-ops when the
    /// outgoing session is not on the engine's native backend.
    func prepareForItemReplacement() {
        engine.prepareForItemReplacement()
    }

    /// Info popup Advanced tab snapshot, read straight from the engine: decoder labels plus
    /// its 1 Hz `LiveTelemetry`, which is nil while idle and on the `hls` route. Starts no sampler.
    func advancedStats() -> AetherAdvancedStats {
        let t = engine.diagnostics.liveTelemetry
        return AetherAdvancedStats(
            backend: engine.activeVideoDecoder,
            audioBridge: engine.activeAudioDecoder,
            audioDelivery: Self.audioDeliveryLabel(engine.audioDelivery),
            instantBitrateMbps: t?.instantBitrateMbps,
            averageBitrateMbps: t?.averageBitrateMbps,
            audioBridgeBitrateMbps: t?.audioBridgeBitrateMbps,
            observedFps: t?.observedFps,
            droppedFrameCount: t?.droppedFrameCount,
            forwardBufferSeconds: t?.forwardBufferSeconds,
            cachedBytes: t?.cachedBytes,
            networkThroughputMbps: t?.networkThroughputMbps,
            networkTransferredBytes: t?.networkTransferredBytes,
            avSyncGapMs: t?.avSyncGapMs,
            producerRestartCount: t?.producerRestartCount,
            muxedBytesLifetime: t?.muxedBytesLifetime,
            serverBytesSentLifetime: t?.serverBytesSentLifetime,
            serverRequestCount: t?.serverRequestCount,
            demuxerBytesFetched: t?.demuxerBytesFetched,
            audioBridgeLiveBytes: t?.audioBridgeLiveBytes,
            rssMb: t?.rssMb
        )
    }
}

/// Full "stats for nerds" snapshot for the Info popup's Advanced tab. An
/// app-side wrapper so the view layer never depends
/// on the engine's own `LiveTelemetry` type. Every field is optional and
/// path-asymmetric: e.g. `observedFps` is nil on the native/AVPlayer path,
/// `droppedFrameCount` / `avSyncGapMs` / `forwardBufferSeconds` are nil on the
/// software path. The Advanced view renders only the non-nil rows.
///
/// The init defaults every field to nil so both the engine mapping and tests
/// can name just the fields they care about.
struct AetherAdvancedStats {
    // Decoder identity (from engine.activeVideoDecoder / activeAudioDecoder).
    let backend: String?
    let audioBridge: String?
    /// How the session's audio reaches the renderer, mapped from the engine's
    /// own `audioDelivery`. Worth a row of its own because `audioBridge` names
    /// a decoder and this names a FATE: "Video only" here is the engine saying
    /// the source has audio it could not deliver, which no decoder label shows.
    let audioDelivery: String?
    // Enthusiast telemetry.
    let instantBitrateMbps: Double?
    let averageBitrateMbps: Double?
    let audioBridgeBitrateMbps: Double?
    let observedFps: Double?
    let droppedFrameCount: Int?
    let forwardBufferSeconds: Double?
    let cachedBytes: Int64?
    let networkThroughputMbps: Double?
    let networkTransferredBytes: Int64?
    let avSyncGapMs: Double?
    // Engine internals.
    let producerRestartCount: Int?
    let muxedBytesLifetime: Int64?
    let serverBytesSentLifetime: Int64?
    let serverRequestCount: Int?
    let demuxerBytesFetched: Int64?
    let audioBridgeLiveBytes: Int?
    let rssMb: Int?

    init(
        backend: String? = nil,
        audioBridge: String? = nil,
        audioDelivery: String? = nil,
        instantBitrateMbps: Double? = nil,
        averageBitrateMbps: Double? = nil,
        audioBridgeBitrateMbps: Double? = nil,
        observedFps: Double? = nil,
        droppedFrameCount: Int? = nil,
        forwardBufferSeconds: Double? = nil,
        cachedBytes: Int64? = nil,
        networkThroughputMbps: Double? = nil,
        networkTransferredBytes: Int64? = nil,
        avSyncGapMs: Double? = nil,
        producerRestartCount: Int? = nil,
        muxedBytesLifetime: Int64? = nil,
        serverBytesSentLifetime: Int64? = nil,
        serverRequestCount: Int? = nil,
        demuxerBytesFetched: Int64? = nil,
        audioBridgeLiveBytes: Int? = nil,
        rssMb: Int? = nil
    ) {
        self.backend = backend
        self.audioBridge = audioBridge
        self.audioDelivery = audioDelivery
        self.instantBitrateMbps = instantBitrateMbps
        self.averageBitrateMbps = averageBitrateMbps
        self.audioBridgeBitrateMbps = audioBridgeBitrateMbps
        self.observedFps = observedFps
        self.droppedFrameCount = droppedFrameCount
        self.forwardBufferSeconds = forwardBufferSeconds
        self.cachedBytes = cachedBytes
        self.networkThroughputMbps = networkThroughputMbps
        self.networkTransferredBytes = networkTransferredBytes
        self.avSyncGapMs = avSyncGapMs
        self.producerRestartCount = producerRestartCount
        self.muxedBytesLifetime = muxedBytesLifetime
        self.serverBytesSentLifetime = serverBytesSentLifetime
        self.serverRequestCount = serverRequestCount
        self.demuxerBytesFetched = demuxerBytesFetched
        self.audioBridgeLiveBytes = audioBridgeLiveBytes
        self.rssMb = rssMb
    }

    /// True when every display field is nil (no decoder labels yet AND no
    /// telemetry). The Advanced view shows a single "Gathering stats…" line
    /// in that case rather than a blank tab.
    var isEmpty: Bool {
        backend == nil && audioBridge == nil
            && instantBitrateMbps == nil && averageBitrateMbps == nil
            && audioBridgeBitrateMbps == nil && observedFps == nil
            && droppedFrameCount == nil && forwardBufferSeconds == nil
            && cachedBytes == nil && networkThroughputMbps == nil
            && networkTransferredBytes == nil && avSyncGapMs == nil
            && producerRestartCount == nil && muxedBytesLifetime == nil
            && serverBytesSentLifetime == nil && serverRequestCount == nil
            && demuxerBytesFetched == nil && audioBridgeLiveBytes == nil
            && rssMb == nil
    }
}

private final class ProviderSubtitleNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
