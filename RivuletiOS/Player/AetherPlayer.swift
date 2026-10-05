// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AetherPlayer.swift
//  Rivulet iOS
//
//  Touch-first host for AetherEngine, used for both Live TV and Plex VOD on
//  iOS. It shares no code with the tvOS player of the same name: that one
//  conforms to PlayerProtocol and is driven by the UIKit focus chrome, this one
//  is a plain ObservableObject read by SwiftUI. Two files rather than one
//  because shared code carries no platform conditionals (see CLAUDE.md,
//  Platform Boundary). This is the only iOS file that names engine types.
//

@preconcurrency import AVFoundation
import AVKit
import Combine
import CoreMedia
import Foundation
import SwiftUI
import UIKit
import AetherEngine

@MainActor
final class AetherPlayer: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case ended
        case failed(String)
    }

    struct Track: Identifiable, Hashable {
        let id: Int
        let name: String
        let codec: String
        let language: String?
        let channels: Int
        let isDefault: Bool
        let isForced: Bool
        let isHearingImpaired: Bool

        var detail: String {
            var parts: [String] = []
            if let language, !language.isEmpty {
                parts.append(Locale.current.localizedString(forLanguageCode: language) ?? language)
            }
            if !codec.isEmpty { parts.append(codec.uppercased()) }
            if channels > 0 { parts.append(channels == 2 ? "Stereo" : "\(channels) ch") }
            if isHearingImpaired { parts.append("SDH") }
            if isForced { parts.append("Forced") }
            return parts.joined(separator: " · ")
        }
    }

    struct SubtitleCue: Identifiable {
        struct StyledRun: Hashable {
            let text: String
            let color: UIColor?
            let isBold: Bool
            let isItalic: Bool
            let isUnderlined: Bool
            let isStruckThrough: Bool
            let fontName: String?
            let fontSize: Int?
        }

        struct TextPlacement: Hashable {
            let alignment: Int?
            let position: CGPoint?
        }

        enum Body {
            case text(String)
            case styledText([StyledRun])
            case image(UIImage, CGRect)
        }

        let id: Int
        let startTime: Double
        let endTime: Double
        let body: Body
        let placement: TextPlacement?
    }

    /// A sidecar subtitle file registered at load (Plex external streams).
    struct SidecarSubtitle {
        let url: URL
        let name: String?
        let language: String?
        let isForced: Bool
        let isHearingImpaired: Bool
        let isDefault: Bool
        /// "srt", "ass", "vtt": Plex stream keys carry no extension.
        let formatHint: String?
    }

    /// The live rewind window on the session axis, the one `seekLive` takes.
    /// Never `sourceTime`: on the software live path that axis is offset.
    struct LiveWindow: Equatable {
        var seekableRange: ClosedRange<Double>?
        var edgeTime: Double
        var playhead: Double
        var isAtLiveEdge: Bool

        static let idle = LiveWindow(seekableRange: nil, edgeTime: 0, playhead: 0, isAtLiveEdge: true)
    }

    private static let nativeAudioTrackIDBase = 300_000

    private let engine: AetherEngine
    private var cancellables = Set<AnyCancellable>()
    private var nativeItemObservation: AnyCancellable?
    private var nativeVideoSizeObservation: AnyCancellable?
    private var timeControlObservation: AnyCancellable?
    private weak var nativeMediaItem: AVPlayerItem?
    private var nativeAudioGroup: AVMediaSelectionGroup?
    private var nativeAudioOptions: [AVMediaSelectionOption] = []
    private var nativeLegibleOutput: AVPlayerItemLegibleOutput?
    private var nativeLegibleBridge: NativeLegibleBridge?
    private var nativeLegibleClearWorkItem: DispatchWorkItem?
    private var lastNativeLegibleLines: [NativeStyledLine] = []
    private let softwarePiPBridge = SoftwarePiPBridge()

    @Published private(set) var state: State = .idle
    @Published private(set) var isBuffering = false
    @Published private(set) var audioTracks: [Track] = []
    @Published private(set) var subtitleTracks: [Track] = []
    @Published private(set) var currentAudioTrackId: Int?
    @Published private(set) var currentSubtitleTrackId: Int?
    @Published private(set) var subtitleCues: [SubtitleCue] = []
    @Published private(set) var nativeSubtitleCues: [SubtitleCue] = []
    /// Media timeline position (VOD scrubber, markers, Plex reports).
    @Published private(set) var currentTime: Double = 0
    /// Cue axis: holds the on-screen frame through a seek; captions only.
    @Published private(set) var sourceTime: Double = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var isLive = false
    @Published private(set) var liveWindow: LiveWindow = .idle
    /// Where an in-flight seek is headed, so repeated skips stack and the
    /// scrubber does not snap back while the engine lands.
    @Published private(set) var pendingSeekTarget: Double?
    /// A VOD load whose clock has not moved yet; the start position stands in as the pending target.
    @Published private(set) var isStarting = false
    @Published private(set) var rate: Float = 1
    @Published private(set) var isMuted = false
    @Published private(set) var canRetry = true
    @Published var fillsScreen = false {
        didSet { engine.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect }
    }
    /// What an AVPictureInPictureController presents for the current session.
    @Published private(set) var pictureInPictureSource: AVPictureInPictureController.ContentSource?

    /// Whether the USER wants playback running. Not derived from engine state,
    /// which flips to paused on a background teardown (tvOS AetherPlayer).
    private var userIntendsToPlay = false
    private var isBackgrounded = false
    /// When the engine's background teardown released the pipeline; non-nil
    /// means the session needs a rebuild before it can play again.
    private var tornDownAt: Date?
    private var foregroundReloadTask: Task<Void, Never>?
    private var lastLoad: LoadRequest?

    private enum LoadRequest {
        case vod(url: URL, headers: [String: String], subtitles: [SidecarSubtitle])
        case live(url: URL, headers: [String: String], forceEngineDemux: Bool)
    }

    /// AVPlayerLayer does not paint remote HLS WebVTT captions when the host
    /// supplies its own controls, so forward native legible output to SwiftUI.
    private final class NativeLegibleBridge: NSObject, AVPlayerItemLegibleOutputPushDelegate {
        let onStrings: ([NSAttributedString]) -> Void

        init(onStrings: @escaping ([NSAttributedString]) -> Void) {
            self.onStrings = onStrings
        }

        func legibleOutput(
            _ output: AVPlayerItemLegibleOutput,
            didOutputAttributedStrings strings: [NSAttributedString],
            nativeSampleBuffers nativeSamples: [Any],
            forItemTime itemTime: CMTime
        ) {
            onStrings(strings)
        }
    }

    init() {
        do {
            engine = try AetherEngine()
        } catch {
            fatalError("Unable to create AetherEngine: \(error)")
        }
        // The app owns the session on iOS, so the engine releases it off-main
        // on final teardown (no host-side setActive(false) racing the stop).
        engine.deactivatesAudioSessionOnStop = true
        softwarePiPBridge.player = self
        wirePublishers()
        observeAppLifecycle()
    }

    private func wirePublishers() {
        engine.$state
            // errorInfo is assigned right before state, so read it on this turn.
            .map { [engine] state in (state, engine.errorInfo) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, errorInfo in
                guard let self else { return }
                self.state = Self.translate(state, errorInfo: errorInfo)
                if case .error = state { self.canRetry = errorInfo?.kind != .dolbyVisionRequiresHardware }
                self.recomputeBuffering()
                self.softwarePiPBridge.update(isPaused: state != .playing)
            }
            .store(in: &cancellables)

        engine.$isBuffering
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeBuffering() }
            .store(in: &cancellables)

        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                if let source = self.engine.softwarePiPSource { self.softwarePiPBridge.update(timeRange: source.timeRange()) }
                self.duration = $0
            }
            .store(in: &cancellables)

        engine.$isLive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isLive = $0 }
            .store(in: &cancellables)

        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                guard let self else { return }
                if tracks.isEmpty || !self.engineAudioTracksAreSelectable {
                    if self.nativeAudioOptions.isEmpty { self.audioTracks = [] }
                } else {
                    self.nativeAudioGroup = nil
                    self.nativeAudioOptions = []
                    self.audioTracks = tracks.map(Self.translate)
                }
            }
            .store(in: &cancellables)

        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?.subtitleTracks = tracks.map(Self.translate)
            }
            .store(in: &cancellables)

        engine.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self, self.nativeAudioGroup == nil else { return }
                self.currentAudioTrackId = id
            }
            .store(in: &cancellables)

        engine.$activeSubtitleTrackIndex
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentSubtitleTrackId)

        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in self?.clockTicked(time) }
            .store(in: &cancellables)

        engine.clock.$sourceTime
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sourceTime = $0 }
            .store(in: &cancellables)

        engine.seekEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, event.isTerminal, let pending = self.pendingSeekTarget,
                      abs(pending - event.target) < 0.5 else { return }
                self.pendingSeekTarget = nil
            }
            .store(in: &cancellables)

        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                // The engine's cue type cannot be named here (module and class share a name).
                self.subtitleCues = cues.map { cue in
                    let body: SubtitleCue.Body
                    switch cue.body {
                    case .text(let text):
                        body = .text(text)
                    case .richText(let runs):
                        body = .styledText(runs.map {
                            SubtitleCue.StyledRun(
                                text: $0.text,
                                color: $0.color.map {
                                    UIColor(red: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255,
                                            blue: CGFloat($0.b) / 255, alpha: 1)
                                },
                                isBold: $0.isBold,
                                isItalic: $0.isItalic,
                                isUnderlined: $0.isUnderlined,
                                isStruckThrough: $0.isStruckThrough,
                                fontName: $0.fontName,
                                fontSize: $0.fontSize
                            )
                        })
                    case .image(let image):
                        body = .image(UIImage(cgImage: image.cgImage), image.position)
                    }
                    return SubtitleCue(
                        id: cue.id,
                        startTime: cue.startTime,
                        endTime: cue.endTime,
                        body: body,
                        placement: cue.placement.map { SubtitleCue.TextPlacement(alignment: $0.alignment, position: $0.position) }
                    )
                }
            }
            .store(in: &cancellables)

        engine.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avPlayer in
                guard let self else { return }
                self.nativeItemObservation = nil
                self.observeTimeControlStatus(of: avPlayer)
                self.refreshPictureInPictureSource()
                guard let avPlayer else {
                    self.observeVideoSize(of: nil)
                    self.clearNativeMediaSelection()
                    return
                }
                self.nativeItemObservation = avPlayer.publisher(for: \.currentItem)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] item in
                        self?.observeVideoSize(of: item)
                        self?.prepareNativeMediaSelection(for: item)
                    }
            }
            .store(in: &cancellables)

        engine.$softwarePiPSource
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPictureInPictureSource() }
            .store(in: &cancellables)

        // The software path's picture size under its pixel aspect ratio
        // (anamorphic SD broadcast); nil on the native path.
        engine.$softwareDisplaySize
            .compactMap { $0 }
            .filter { $0.width > 0 && $0.height > 0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.videoSize = $0 }
            .store(in: &cancellables)

        engine.$playbackBackend
            .receive(on: DispatchQueue.main)
            .sink { [weak self] backend in
                // A teardown parks the session paused; a load passes through .loading.
                guard let self, backend == .none, self.isBackgrounded, self.lastLoad != nil,
                      self.engine.state == .paused else { return }
                self.tornDownAt = Date()
            }
            .store(in: &cancellables)
    }

    private func clockTicked(_ time: Double) {
        currentTime = time
        if isStarting, time > 0 {
            isStarting = false
            pendingSeekTarget = nil
        }
        if isLive {
            let clock = engine.clock
            let window = LiveWindow(
                seekableRange: clock.seekableLiveRange,
                edgeTime: clock.liveEdgeTime,
                playhead: time,
                isAtLiveEdge: clock.isAtLiveEdge
            )
            if window != liveWindow { liveWindow = window }
        }
        if let source = engine.softwarePiPSource {
            softwarePiPBridge.update(timeRange: source.timeRange())
        }
    }

    // MARK: - Loading

    /// Live TV. HLS goes to AVPlayer natively; everything else (raw MPEG-TS)
    /// through the engine's demux. `forceEngineDemux` is for Plex
    /// `/livetv/sessions/` grants, whose broadcast mp2 and teletext AVPlayer
    /// cannot decode (tvOS AetherPlayer.loadLive).
    func loadLive(url: URL, headers: [String: String]? = nil, forceEngineDemux: Bool = false) async throws {
        lastLoad = .live(url: url, headers: headers ?? [:], forceEngineDemux: forceEngineDemux)
        try await performLiveLoad(url: url, headers: headers ?? [:], forceEngineDemux: forceEngineDemux)
    }

    private func performLiveLoad(url: URL, headers: [String: String], forceEngineDemux: Bool) async throws {
        beginLoad()
        let isNativeHLS = Self.isHLSURL(url) && !forceEngineDemux
        // Forced onto the engine demuxer AND a playlist: the Plex direct-play grant.
        let usesHLSIngest = !isNativeHLS && Self.isHLSURL(url)
        // A wireless receiver buffers ~2 s before it sounds; mount paused and
        // let the route catch up instead of playing silent picture (#319).
        let joinsWirelessAudio = Self.isWirelessAudioRoute()

        func makeOptions(nativeRemoteHLS: Bool) -> LoadOptions {
            var options = LoadOptions(
                suppressDisplayCriteria: false,
                httpHeaders: headers,
                matchContentEnabled: true,
                panelIsInHDRMode: false,
                audioBridgeMode: .lossless,
                isLive: true,
                dvrWindowSeconds: 1800,
                nativeRemoteHLS: nativeRemoteHLS,
                // No libass on iOS: ASS arrives as clean text instead of raw event lines.
                preserveASSMarkup: false,
                probesize: 5 * 1024 * 1024,
                maxAnalyzeDuration: 5_000_000,
                preferredAudioLanguages: [],
                preferredSubtitleLanguages: [],
                teletextPage: Self.regionTeletextPage(),
                // Software only where the source says it is interlaced; the
                // engine's own SPS check catches mis-signalled H.264 (#150).
                preferredDecodePath: (!nativeRemoteHLS && Self.needsDeinterlacing(url)) ? .software : .automatic
            )
            if joinsWirelessAudio {
                options.liveJoinStartsImmediately = false
                options.autoplay = false
            }
            return options
        }

        do {
            if usesHLSIngest {
                // LoadOptions.httpHeaders never reaches a custom reader (AE#119).
                let reader = HLSLiveIngestReader(playlistURL: url, httpHeaders: headers)
                do {
                    try await engine.load(source: .custom(reader, formatHint: "mpegts"), options: makeOptions(nativeRemoteHLS: false))
                } catch {
                    // Encrypted or fMP4 playlist: retry natively on the same grant.
                    guard reader.terminalError != nil, !Self.isCancellation(error) else { throw error }
                    try await engine.load(url: url, startPosition: nil, options: makeOptions(nativeRemoteHLS: true))
                }
            } else {
                try await engine.load(url: url, startPosition: nil, options: makeOptions(nativeRemoteHLS: isNativeHLS))
            }
            if joinsWirelessAudio {
                if engine.videoRoute == .software {
                    try? await Task.sleep(for: .seconds(Self.wirelessAudioPrimeSeconds()))
                }
                if userIntendsToPlay { engine.play() }
            }
            seedVideoSize()
        } catch {
            failLoad(error)
            throw error
        }
    }

    /// Plex video on demand. Sidecars are registered at load so they appear
    /// as ordinary subtitle tracks.
    func load(
        url: URL,
        headers: [String: String]? = nil,
        startTime: TimeInterval? = nil,
        externalSubtitles: [SidecarSubtitle] = []
    ) async throws {
        lastLoad = .vod(url: url, headers: headers ?? [:], subtitles: externalSubtitles)
        try await performVODLoad(url: url, headers: headers ?? [:], startTime: startTime, subtitles: externalSubtitles)
    }

    private func performVODLoad(
        url: URL,
        headers: [String: String],
        startTime: TimeInterval?,
        subtitles: [SidecarSubtitle]
    ) async throws {
        beginLoad()
        pendingSeekTarget = startTime
        isStarting = true
        let options = LoadOptions(
            suppressDisplayCriteria: false,
            httpHeaders: headers,
            matchContentEnabled: true,
            panelIsInHDRMode: false,
            audioBridgeMode: .lossless,
            isLive: false,
            dvrWindowSeconds: 0,
            nativeRemoteHLS: Self.isHLSURL(url),
            preserveASSMarkup: false,
            probesize: 8 * 1024 * 1024,
            maxAnalyzeDuration: 8_000_000,
            preferredAudioLanguages: [],
            preferredSubtitleLanguages: [],
            externalSubtitles: subtitles.map {
                ExternalSubtitleTrack(
                    url: $0.url,
                    name: $0.name,
                    language: $0.language,
                    isForced: $0.isForced,
                    isHearingImpaired: $0.isHearingImpaired,
                    isDefault: $0.isDefault,
                    httpHeaders: nil,
                    formatHint: $0.formatHint
                )
            },
            teletextPage: Self.regionTeletextPage()
        )

        do {
            try await engine.load(url: url, startPosition: startTime, options: options)
            seedVideoSize()
        } catch {
            failLoad(error)
            throw error
        }
    }

    /// Reloads the last source: VOD at the last position, live at the edge.
    func retry() async {
        guard let lastLoad else { return }
        let position = currentTime
        switch lastLoad {
        case .vod(let url, let headers, let subtitles):
            try? await performVODLoad(url: url, headers: headers, startTime: position > 1 ? position : nil, subtitles: subtitles)
        case .live(let url, let headers, let forceEngineDemux):
            try? await performLiveLoad(url: url, headers: headers, forceEngineDemux: forceEngineDemux)
        }
    }

    private func beginLoad() {
        state = .loading
        canRetry = true
        videoSize = .zero
        pendingSeekTarget = nil
        isStarting = false
        liveWindow = .idle
        // The engine forgets the speed when the source changes.
        rate = 1
        userIntendsToPlay = true
        tornDownAt = nil
        // Audio session activation is an XPC round trip; keep it off main.
        Task.detached(priority: .userInitiated) {
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    private func failLoad(_ error: Error) {
        guard !Self.isCancellation(error) else { return }
        isStarting = false
        canRetry = engine.errorInfo?.kind != .dolbyVisionRequiresHardware
        state = .failed(Self.userFacingFailure(engine.errorInfo))
    }

    /// The engine's coded dimensions until the item reports its own size.
    private func seedVideoSize() {
        guard videoSize == .zero else { return }
        let size = CGSize(width: Int(engine.sourceVideoWidth), height: Int(engine.sourceVideoHeight))
        if size.width > 0, size.height > 0 { videoSize = size }
    }

    // MARK: - Transport

    func play() {
        userIntendsToPlay = true
        if tornDownAt != nil {
            startForegroundReload()
            return
        }
        engine.play()
        // A rate set while paused is applied on resume; setRate would start playback.
        if rate != 1 { engine.setRate(rate) }
    }

    func pause() {
        userIntendsToPlay = false
        engine.pause()
    }

    func togglePlayPause() {
        state == .playing ? pause() : play()
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if state == .playing { engine.setRate(newRate) }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        engine.volume = muted ? 0 : 1
    }

    /// VOD seek on the media timeline.
    func seek(to time: TimeInterval) async {
        let upper = duration > 0 ? duration : .greatestFiniteMagnitude
        let target = min(max(0, time), upper)
        await performSeek(to: target)
    }

    /// Skip relative to where the last skip was headed, so rapid taps stack.
    func skip(by seconds: Double) async {
        if isLive {
            await seekLive(to: (pendingSeekTarget ?? liveWindow.playhead) + seconds)
        } else {
            await seek(to: (pendingSeekTarget ?? currentTime) + seconds)
        }
    }

    /// Live seek on the session axis, clamped to the rewind window. Landing
    /// within a second of the edge snaps to live.
    func seekLive(to sessionSeconds: Double) async {
        let window = liveWindow
        guard let range = window.seekableRange else { return }
        let target = min(max(sessionSeconds, range.lowerBound), window.edgeTime)
        if window.edgeTime - target < 1 {
            await seekToLiveEdge()
        } else {
            await performSeek(to: target)
        }
    }

    /// Seek events clear the pending target; the timeout covers a seek the
    /// engine drops without one (no session yet).
    private func performSeek(to target: Double) async {
        // A user seek owns the pending target from here; its seek event clears it.
        isStarting = false
        pendingSeekTarget = target
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if self?.pendingSeekTarget == target { self?.pendingSeekTarget = nil }
        }
        await engine.seek(to: target)
    }

    func seekToLiveEdge() async {
        pendingSeekTarget = nil
        await engine.seekToLiveEdge()
    }

    func selectAudioTrack(id: Int) {
        if id >= Self.nativeAudioTrackIDBase,
           let item = nativeMediaItem,
           let group = nativeAudioGroup {
            let index = id - Self.nativeAudioTrackIDBase
            guard nativeAudioOptions.indices.contains(index) else { return }
            item.select(nativeAudioOptions[index], in: group)
            currentAudioTrackId = id
            return
        }
        engine.selectAudioTrack(index: id)
    }

    func selectSubtitleTrack(id: Int?) {
        if let id {
            if let item = nativeMediaItem {
                ensureNativeLegibleOutput(on: item)
            }
            engine.selectSubtitleTrack(index: id)
        } else {
            engine.clearSubtitle()
            subtitleCues = []
            clearNativeSubtitleText()
        }
    }

    func stop() {
        foregroundReloadTask?.cancel()
        foregroundReloadTask = nil
        tornDownAt = nil
        userIntendsToPlay = false
        lastLoad = nil
        clearNativeMediaSelection()
        nativeVideoSizeObservation = nil
        videoSize = .zero
        pendingSeekTarget = nil
        isStarting = false
        liveWindow = .idle
        rate = 1
        engine.pictureInPictureActive = false
        engine.stop()
        state = .idle
    }

    // MARK: - Render surface and Picture in Picture

    /// A render surface typed as a plain view, so hosts never name the engine's view.
    static func makeRenderSurface() -> UIView {
        let view = AetherPlayerView()
        view.backgroundColor = .black
        return view
    }

    func bind(surface: UIView) {
        guard let view = surface as? AetherPlayerView else { return }
        engine.bind(view: view)
    }

    func unbind(surface: UIView) {
        guard let view = surface as? AetherPlayerView else { return }
        engine.unbind(view: view)
    }

    /// Arms the engine's background keepalive and its in-place next-item
    /// handover while the PiP window is up.
    func setPictureInPictureActive(_ active: Bool) {
        engine.pictureInPictureActive = active
    }

    /// The native session's AVPlayerLayer, or the software path's sample
    /// buffer layer with a playback delegate backed by this player.
    private func refreshPictureInPictureSource() {
        if let software = engine.softwarePiPSource {
            softwarePiPBridge.update(timeRange: software.timeRange())
            guard pictureInPictureSource?.sampleBufferDisplayLayer !== software.layer else { return }
            pictureInPictureSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: software.layer,
                playbackDelegate: softwarePiPBridge
            )
        } else if let layer = engine.nativePlayerLayer {
            guard pictureInPictureSource?.playerLayer !== layer else { return }
            pictureInPictureSource = AVPictureInPictureController.ContentSource(playerLayer: layer)
        } else if pictureInPictureSource != nil {
            pictureInPictureSource = nil
        }
    }

    // MARK: - Background / foreground

    /// With background audio and PiP the engine keeps a playing session alive;
    /// a session paused in the background is torn down after the grace window
    /// and the host must rebuild it. Playing user: on foreground. Paused user:
    /// on the next play(), because a reload zeroes the clock until playback
    /// starts (tvOS AetherPlayer.observeAppLifecycle, issue #215).
    private func observeAppLifecycle() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.isBackgrounded = true }
            .store(in: &cancellables)

        // didBecomeActive pairs with the engine's own teardown/restore observers.
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.isBackgrounded = false
                if self.tornDownAt != nil, self.userIntendsToPlay { self.startForegroundReload() }
            }
            .store(in: &cancellables)
    }

    private func startForegroundReload() {
        guard foregroundReloadTask == nil, lastLoad != nil else { return }
        let since = tornDownAt ?? .distantPast
        foregroundReloadTask = Task { [weak self] in
            // The teardown drains loopback sockets for ~3.5 s with no handle to await.
            let drain = max(0, 4.0 - Date().timeIntervalSince(since))
            if drain > 0 { try? await Task.sleep(for: .seconds(drain)) }
            guard let self, !Task.isCancelled else { return }
            defer { self.foregroundReloadTask = nil }
            // A failed reload (a forward-only live source refuses) surfaces Retry, which loads afresh.
            do {
                try await self.engine.reloadAtCurrentPosition()
                self.tornDownAt = nil
            } catch {
                guard !Task.isCancelled, !Self.isCancellation(error) else { return }
                self.tornDownAt = nil
                self.canRetry = true
                self.state = .failed(Self.userFacingFailure(self.engine.errorInfo))
            }
        }
    }

    // MARK: - Buffering

    /// The engine's flag goes stale after a far seek that lands while AVPlayer
    /// is still waiting, so fold in timeControlStatus (tvOS AetherPlayer).
    private var hostPlayerWaiting = false

    private func observeTimeControlStatus(of player: AVPlayer?) {
        timeControlObservation = player?
            .publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.hostPlayerWaiting = status == .waitingToPlayAtSpecifiedRate
                self?.recomputeBuffering()
            }
        if player == nil {
            hostPlayerWaiting = false
            recomputeBuffering()
        }
    }

    private func recomputeBuffering() {
        let buffering = engine.isBuffering || (engine.state == .playing && hostPlayerWaiting)
        if buffering != isBuffering { isBuffering = buffering }
    }

    // MARK: - Translation

    private static func translate(_ state: PlaybackState, errorInfo: PlaybackErrorInfo?) -> State {
        switch state {
        case .idle: return .idle
        case .loading, .seeking: return .loading
        case .playing: return .playing
        case .paused: return .paused
        case .ended: return .ended
        case .error: return .failed(userFacingFailure(errorInfo))
        }
    }

    /// Only kinds that change what the viewer should do get their own sentence.
    private static func userFacingFailure(_ info: PlaybackErrorInfo?) -> String {
        let generic = "This video couldn't be played. Check your connection and try again."
        guard let kind = info?.kind else { return generic }
        switch kind {
        case .sourceRateLimited:
            return "The server is refusing new streams right now. Wait a moment and try again."
        case .sourceRefused:
            return "The server refused this stream. It may have moved, or your access to it may have changed."
        case .sourceCertificateRejected:
            return "The server's security certificate was not accepted."
        case .liveSourceUnavailable:
            return "This channel is not responding right now."
        case .dolbyVisionRequiresHardware:
            return "This Dolby Vision file has no fallback layer this device can decode."
        default:
            return generic
        }
    }

    private static func translate(_ track: TrackInfo) -> Track {
        Track(
            id: track.id,
            name: track.name.isEmpty ? fallbackTrackName(track) : track.name,
            codec: track.codec,
            language: track.language,
            channels: track.channels,
            isDefault: track.isDefault,
            isForced: track.isForced,
            isHearingImpaired: track.isHearingImpaired
        )
    }

    private static func fallbackTrackName(_ track: TrackInfo) -> String {
        if let language = track.language, !language.isEmpty {
            return Locale.current.localizedString(forLanguageCode: language) ?? language
        }
        return track.codec.isEmpty ? "Track \(track.id)" : track.codec.uppercased()
    }

    // MARK: - Source predicates (shared with tvOS AetherPlayer)

    private static func isHLSURL(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "m3u8" { return true }
        let text = url.absoluteString.lowercased()
        return text.contains(".m3u8") || text.contains("format=hls")
    }

    /// Plex reports the scan type on the tune; absence means progressive,
    /// because forcing software decode on every playlist channel dropped
    /// frames and put AirPlay audio seconds late (tvOS AetherPlayer).
    private static func needsDeinterlacing(_ url: URL) -> Bool {
        guard let scan = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "rivuletLiveScanType" })?.value?
            .lowercased() else { return false }
        return scan != "progressive"
    }

    /// AU free-to-air carries captions on 801 without flagging it; a stored
    /// `liveTeletextPage` overrides (0 means auto-detect).
    private static func regionTeletextPage() -> Int? {
        if let stored = UserDefaults.standard.object(forKey: "liveTeletextPage") as? Int {
            return stored == 0 ? nil : stored
        }
        return Locale.current.region?.identifier == "AU" ? 801 : nil
    }

    private static func isWirelessAudioRoute() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    private static func wirelessAudioPrimeSeconds() -> Double {
        let reported = AVAudioSession.sharedInstance().outputLatency
        guard reported > 0.2 else { return 2.0 }
        return min(max(reported, 1.0), 3.0)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    // MARK: - Native remote-HLS media selection and captions

    private func prepareNativeMediaSelection(for item: AVPlayerItem?) {
        guard nativeMediaItem !== item else { return }
        clearNativeMediaSelection()
        guard let item, Self.isRemoteItem(item) else { return }
        nativeMediaItem = item
        ensureNativeLegibleOutput(on: item)

        Task { @MainActor [weak self, weak item] in
            guard let item else { return }
            if item.status == .unknown {
                for await status in item.publisher(for: \.status).values where status != .unknown {
                    guard status == .readyToPlay else { return }
                    break
                }
            }
            guard let self, self.nativeMediaItem === item else { return }
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  !group.options.isEmpty,
                  self.engine.audioTracks.isEmpty || !self.engineAudioTracksAreSelectable else { return }

            self.nativeAudioGroup = group
            self.nativeAudioOptions = group.options
            self.audioTracks = group.options.enumerated().map { index, option in
                Track(
                    id: Self.nativeAudioTrackIDBase + index,
                    name: option.displayName.isEmpty ? "Audio \(index + 1)" : option.displayName,
                    codec: "",
                    language: option.extendedLanguageTag,
                    channels: 0,
                    isDefault: group.defaultOption == option,
                    isForced: false,
                    isHearingImpaired: false
                )
            }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group),
               let index = group.options.firstIndex(of: selected) {
                self.currentAudioTrackId = Self.nativeAudioTrackIDBase + index
            }
        }
    }

    /// Since 7.22.0 the remote-HLS bypass publishes AVPlayer's audio tracks for
    /// information only and ignores `selectAudioTrack`; AVMediaSelection owns them.
    private var engineAudioTracksAreSelectable: Bool { engine.videoRoute != .remoteBypass }

    private static func isRemoteItem(_ item: AVPlayerItem) -> Bool {
        guard let asset = item.asset as? AVURLAsset else { return false }
        switch asset.url.host?.lowercased() {
        case "127.0.0.1", "localhost", "::1", nil: return false
        default: return true
        }
    }

    private func observeVideoSize(of item: AVPlayerItem?) {
        nativeVideoSizeObservation = nil
        guard let item else { return }
        nativeVideoSizeObservation = item
            .publisher(for: \.presentationSize)
            .filter { $0.width > 0 && $0.height > 0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in self?.videoSize = size }
    }

    private func ensureNativeLegibleOutput(on item: AVPlayerItem) {
        guard nativeLegibleOutput == nil || nativeMediaItem !== item else { return }
        if let oldItem = nativeMediaItem, let output = nativeLegibleOutput {
            oldItem.remove(output)
        }

        let bridge = NativeLegibleBridge { [weak self] strings in
            self?.handleNativeLegible(strings)
        }
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = true
        output.textStylingResolution = .sourceAndRulesOnly
        output.setDelegate(bridge, queue: .main)
        item.add(output)
        nativeLegibleBridge = bridge
        nativeLegibleOutput = output
    }

    private struct NativeStyledLine: Equatable {
        let runs: [SubtitleCue.StyledRun]
        let placement: SubtitleCue.TextPlacement?
    }

    private func handleNativeLegible(_ strings: [NSAttributedString]) {
        let lines = strings.compactMap(Self.nativeStyledLine(from:))

        if lines.isEmpty {
            guard nativeLegibleClearWorkItem == nil, !lastNativeLegibleLines.isEmpty else { return }
            let workItem = DispatchWorkItem { [weak self] in
                self?.nativeLegibleClearWorkItem = nil
                self?.lastNativeLegibleLines = []
                self?.nativeSubtitleCues = []
            }
            nativeLegibleClearWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        } else {
            nativeLegibleClearWorkItem?.cancel()
            nativeLegibleClearWorkItem = nil
            guard lines != lastNativeLegibleLines else { return }
            lastNativeLegibleLines = lines
            nativeSubtitleCues = lines.enumerated().map { index, line in
                SubtitleCue(
                    id: 1_000_000 + index,
                    startTime: 0,
                    endTime: .greatestFiniteMagnitude,
                    body: .styledText(line.runs),
                    placement: line.placement
                )
            }
        }
    }

    private static func nativeStyledLine(from attr: NSAttributedString) -> NativeStyledLine? {
        guard !attr.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let colorKey = NSAttributedString.Key(kCMTextMarkupAttribute_ForegroundColorARGB as String)
        let boldKey = NSAttributedString.Key(kCMTextMarkupAttribute_BoldStyle as String)
        let italicKey = NSAttributedString.Key(kCMTextMarkupAttribute_ItalicStyle as String)
        let underlineKey = NSAttributedString.Key(kCMTextMarkupAttribute_UnderlineStyle as String)
        let faceKey = NSAttributedString.Key(kCMTextMarkupAttribute_FontFamilyName as String)
        let sizeKey = NSAttributedString.Key(kCMTextMarkupAttribute_RelativeFontSize as String)

        let ns = attr.string as NSString
        var runs: [SubtitleCue.StyledRun] = []
        attr.enumerateAttributes(
            in: NSRange(location: 0, length: attr.length)
        ) { attributes, range, _ in
            var color: UIColor?
            if let argb = attributes[colorKey] as? [NSNumber], argb.count == 4 {
                color = UIColor(
                    red: CGFloat(argb[1].doubleValue),
                    green: CGFloat(argb[2].doubleValue),
                    blue: CGFloat(argb[3].doubleValue),
                    alpha: CGFloat(argb[0].doubleValue)
                )
            }

            var fontSize: Int?
            if let percent = (attributes[sizeKey] as? NSNumber)?.doubleValue,
               percent > 0,
               abs(percent - 100) > 0.5 {
                fontSize = Int((percent / 100 * 16).rounded())
            }

            runs.append(
                SubtitleCue.StyledRun(
                    text: ns.substring(with: range),
                    color: color,
                    isBold: (attributes[boldKey] as? NSNumber)?.boolValue ?? false,
                    isItalic: (attributes[italicKey] as? NSNumber)?.boolValue ?? false,
                    isUnderlined: (attributes[underlineKey] as? NSNumber)?.boolValue ?? false,
                    isStruckThrough: false,
                    fontName: attributes[faceKey] as? String,
                    fontSize: fontSize
                )
            )
        }

        if let first = runs.first {
            runs[0] = first.replacingText(String(first.text.drop(while: \.isWhitespace)))
        }
        if let lastIndex = runs.indices.last {
            let last = runs[lastIndex]
            runs[lastIndex] = last.replacingText(String(last.text.reversed().drop(while: \.isWhitespace).reversed()))
        }
        runs.removeAll { $0.text.isEmpty }
        guard !runs.isEmpty else { return nil }
        return NativeStyledLine(runs: runs, placement: nativeCuePlacement(from: attr))
    }

    private static func nativeCuePlacement(
        from attr: NSAttributedString
    ) -> SubtitleCue.TextPlacement? {
        guard attr.length > 0 else { return nil }
        let attributes = attr.attributes(at: 0, effectiveRange: nil)
        let lineKey = NSAttributedString.Key(
            kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection
                as String
        )
        let positionKey = NSAttributedString.Key(
            kCMTextMarkupAttribute_TextPositionPercentageRelativeToWritingDirection as String
        )
        let alignmentKey = NSAttributedString.Key(kCMTextMarkupAttribute_Alignment as String)

        let linePercent = (attributes[lineKey] as? NSNumber)?.doubleValue
        let positionPercent = (attributes[positionKey] as? NSNumber)?.doubleValue
        let alignment = attributes[alignmentKey] as? String
        guard linePercent != nil || positionPercent != nil || alignment != nil else { return nil }

        var column = 1
        if alignment == (kCMTextMarkupAlignmentType_Start as String)
            || alignment == (kCMTextMarkupAlignmentType_Left as String) {
            column = 0
        } else if alignment == (kCMTextMarkupAlignmentType_End as String)
                    || alignment == (kCMTextMarkupAlignmentType_Right as String) {
            column = 2
        }

        guard let linePercent else {
            return SubtitleCue.TextPlacement(alignment: column + 1, position: nil)
        }
        let y = min(max(linePercent / 100, 0), 1)
        let row = y < 0.34 ? 2 : (y < 0.67 ? 1 : 0)
        let x = positionPercent.map { min(max($0 / 100, 0), 1) } ?? 0.5
        return SubtitleCue.TextPlacement(
            alignment: row * 3 + column + 1,
            position: CGPoint(x: x, y: y)
        )
    }

    private func clearNativeSubtitleText() {
        nativeLegibleClearWorkItem?.cancel()
        nativeLegibleClearWorkItem = nil
        lastNativeLegibleLines = []
        nativeSubtitleCues = []
    }

    private func clearNativeMediaSelection() {
        let hadNativeAudio = !nativeAudioOptions.isEmpty
        if let item = nativeMediaItem, let output = nativeLegibleOutput {
            item.remove(output)
        }
        nativeMediaItem = nil
        nativeAudioGroup = nil
        nativeAudioOptions = []
        nativeLegibleOutput = nil
        nativeLegibleBridge = nil
        if hadNativeAudio {
            audioTracks = []
            currentAudioTrackId = nil
        }
        clearNativeSubtitleText()
    }
}

private extension AetherPlayer.SubtitleCue.StyledRun {
    func replacingText(_ text: String) -> Self {
        Self(text: text, color: color, isBold: isBold, isItalic: isItalic, isUnderlined: isUnderlined,
             isStruckThrough: isStruckThrough, fontName: fontName, fontSize: fontSize)
    }
}

/// Sample-buffer PiP transport for the software path. AVKit may call it off
/// the main thread, so it answers from a snapshot the player refreshes on
/// each clock tick, and hops to main for commands.
nonisolated private final class SoftwarePiPBridge: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var timeRange = CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    private var isPaused = true
    @MainActor weak var player: AetherPlayer?

    func update(timeRange: CMTimeRange? = nil, isPaused: Bool? = nil) {
        lock.lock()
        if let timeRange { self.timeRange = timeRange }
        if let isPaused { self.isPaused = isPaused }
        lock.unlock()
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        update(isPaused: !playing)
        Task { @MainActor [weak self] in
            guard let player = self?.player else { return }
            playing ? player.play() : player.pause()
        }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        lock.lock()
        defer { lock.unlock() }
        return timeRange
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isPaused
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        let seconds = skipInterval.seconds
        Task { @MainActor [weak self] in
            await self?.player?.skip(by: seconds)
        }
        completionHandler()
    }
}
