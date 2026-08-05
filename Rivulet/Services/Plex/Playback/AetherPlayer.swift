// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

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

@preconcurrency import AVFoundation
import Combine
import CoreMedia
import Foundation
import SwiftUI
import UIKit
import AetherEngine

#if os(iOS)
/// Lightweight iOS host for AetherEngine. The tvOS implementation below also
/// conforms to Rivulet's full player protocol; iOS uses this touch-first host
/// for both Live TV and Plex VOD.
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

    private static let nativeAudioTrackIDBase = 300_000

    private let engine: AetherEngine
    private var cancellables = Set<AnyCancellable>()
    private var nativeItemObservation: AnyCancellable?
    private var nativeVideoSizeObservation: AnyCancellable?
    private weak var nativeMediaItem: AVPlayerItem?
    private var nativeAudioGroup: AVMediaSelectionGroup?
    private var nativeAudioOptions: [AVMediaSelectionOption] = []
    private var nativeLegibleOutput: AVPlayerItemLegibleOutput?
    private var nativeLegibleBridge: NativeLegibleBridge?
    private var nativeLegibleClearWorkItem: DispatchWorkItem?
    private var lastNativeLegibleLines: [NativeStyledLine] = []

    @Published private(set) var state: State = .idle
    @Published private(set) var isBuffering = false
    @Published private(set) var audioTracks: [Track] = []
    @Published private(set) var subtitleTracks: [Track] = []
    @Published private(set) var currentAudioTrackId: Int?
    @Published private(set) var currentSubtitleTrackId: Int?
    @Published private(set) var subtitleCues: [SubtitleCue] = []
    @Published private(set) var nativeSubtitleCues: [SubtitleCue] = []
    @Published private(set) var sourceTime: Double = 0
    @Published private(set) var videoSize: CGSize = .zero
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

        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.state = Self.translate(state)
            }
            .store(in: &cancellables)

        engine.$isBuffering
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buffering in
                self?.isBuffering = buffering
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                guard let self else { return }
                if tracks.isEmpty {
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

        engine.clock.$sourceTime
            .receive(on: DispatchQueue.main)
            .assign(to: &$sourceTime)

        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                self?.subtitleCues = cues.map { cue in
                    let body: SubtitleCue.Body
                    switch cue.body {
                    case .text(let text):
                        body = .text(text)
                    case .richText(let runs):
                        body = .styledText(runs.map {
                            SubtitleCue.StyledRun(
                                text: $0.text,
                                color: $0.color.map {
                                    UIColor(
                                        red: CGFloat($0.r) / 255,
                                        green: CGFloat($0.g) / 255,
                                        blue: CGFloat($0.b) / 255,
                                        alpha: 1
                                    )
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
                        placement: cue.placement.map {
                            SubtitleCue.TextPlacement(
                                alignment: $0.alignment,
                                position: $0.position
                            )
                        }
                    )
                }
            }
            .store(in: &cancellables)

        engine.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avPlayer in
                guard let self else { return }
                self.nativeItemObservation = nil
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
    }

    func loadLive(url: URL, headers: [String: String]? = nil) async throws {
        state = .loading
        let isHLS = url.pathExtension.lowercased() == "m3u8"
            || url.absoluteString.lowercased().contains("format=hls")
        let options = LoadOptions(
            suppressDisplayCriteria: false,
            httpHeaders: headers ?? [:],
            matchContentEnabled: true,
            panelIsInHDRMode: false,
            audioBridgeMode: .lossless,
            isLive: true,
            dvrWindowSeconds: 1800,
            nativeRemoteHLS: isHLS,
            preserveASSMarkup: true,
            probesize: 5 * 1024 * 1024,
            maxAnalyzeDuration: 5_000_000,
            preferredAudioLanguages: [],
            preferredSubtitleLanguages: [],
            teletextPage: Locale.current.region?.identifier == "AU" ? 801 : nil
        )

        do {
            // Broadcast MPEG-TS frequently carries interlaced H.264 without
            // reliable stream metadata. Match the tvOS live path so Aether's
            // software route can deinterlace it before display.
            if !isHLS { AetherEngine.setForceSoftwarePathForTesting(true) }
            defer { if !isHLS { AetherEngine.setForceSoftwarePathForTesting(false) } }
            try await engine.load(url: url, startPosition: nil, options: options)

            // The software backend has no AVPlayerItem, so presentationSize
            // can never populate `videoSize` for raw broadcast streams. Use
            // Aether's probed dimensions to keep subtitle placement relative
            // to the aspect-fitted picture rather than the full device bounds.
            let sourceSize = CGSize(
                width: Int(engine.sourceVideoWidth),
                height: Int(engine.sourceVideoHeight)
            )
            if sourceSize.width > 0, sourceSize.height > 0 {
                videoSize = sourceSize
            }
        } catch {
            if !(error is CancellationError) {
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    /// Load Plex video-on-demand through the same AetherEngine instance used
    /// by Live TV. Aether chooses its native or software backend from the
    /// container/codecs, preserving the tvOS player's playback architecture.
    func load(
        url: URL,
        headers: [String: String]? = nil,
        startTime: TimeInterval? = nil
    ) async throws {
        state = .loading
        let isHLS = url.pathExtension.lowercased() == "m3u8"
            || url.absoluteString.lowercased().contains("start.m3u8")
        let options = LoadOptions(
            suppressDisplayCriteria: false,
            httpHeaders: headers ?? [:],
            matchContentEnabled: true,
            panelIsInHDRMode: false,
            audioBridgeMode: .lossless,
            isLive: false,
            dvrWindowSeconds: 0,
            nativeRemoteHLS: isHLS,
            preserveASSMarkup: true,
            probesize: 8 * 1024 * 1024,
            maxAnalyzeDuration: 8_000_000,
            preferredAudioLanguages: [],
            preferredSubtitleLanguages: [],
            teletextPage: nil
        )

        do {
            try await engine.load(url: url, startPosition: startTime, options: options)
            let sourceSize = CGSize(
                width: Int(engine.sourceVideoWidth),
                height: Int(engine.sourceVideoHeight)
            )
            if sourceSize.width > 0, sourceSize.height > 0 {
                videoSize = sourceSize
            }
        } catch {
            if !(error is CancellationError) {
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    func play() {
        engine.play()
    }

    func pause() {
        engine.pause()
    }
    func seek(to time: TimeInterval) async { await engine.seek(to: max(0, time)) }

    var duration: TimeInterval {
        return engine.duration
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
            if id >= 200_000, let item = nativeMediaItem {
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
        clearNativeMediaSelection()
        nativeVideoSizeObservation = nil
        videoSize = .zero
        engine.stop()
        state = .idle
    }

    func bind(view: AetherPlayerView) {
        engine.bind(view: view)
    }

    func unbind(view: AetherPlayerView) {
        engine.unbind(view: view)
    }

    private static func translate(_ state: PlaybackState) -> State {
        switch state {
        case .idle: return .idle
        case .loading, .seeking: return .loading
        case .playing: return .playing
        case .paused: return .paused
        case .ended: return .ended
        case .error(let message): return .failed(message)
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

    private func prepareNativeMediaSelection(for item: AVPlayerItem?) {
        guard nativeMediaItem !== item else { return }
        clearNativeMediaSelection()
        guard let item, Self.isRemoteItem(item) else { return }
        nativeMediaItem = item
        ensureNativeLegibleOutput(on: item)

        Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            if item.status == .unknown {
                for await status in item.publisher(for: \.status).values where status != .unknown {
                    guard status == .readyToPlay else { return }
                    break
                }
            }
            guard self.nativeMediaItem === item else { return }
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  !group.options.isEmpty,
                  self.engine.audioTracks.isEmpty else { return }

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

    private static func isRemoteItem(_ item: AVPlayerItem) -> Bool {
        guard let asset = item.asset as? AVURLAsset else { return false }
        switch asset.url.host?.lowercased() {
        case "127.0.0.1", "localhost", "::1", nil: return false
        default: return true
        }
    }

    private func observeVideoSize(of item: AVPlayerItem?) {
        nativeVideoSizeObservation = nil
        guard let item else {
            videoSize = .zero
            return
        }

        let initialSize = item.presentationSize
        if initialSize.width > 0, initialSize.height > 0 {
            videoSize = initialSize
        }
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

        if var first = runs.first {
            first = SubtitleCue.StyledRun(
                text: String(first.text.drop(while: \.isWhitespace)),
                color: first.color,
                isBold: first.isBold,
                isItalic: first.isItalic,
                isUnderlined: first.isUnderlined,
                isStruckThrough: first.isStruckThrough,
                fontName: first.fontName,
                fontSize: first.fontSize
            )
            runs[0] = first
        }
        if let lastIndex = runs.indices.last {
            let last = runs[lastIndex]
            runs[lastIndex] = SubtitleCue.StyledRun(
                text: String(last.text.reversed().drop(while: \.isWhitespace).reversed()),
                color: last.color,
                isBold: last.isBold,
                isItalic: last.isItalic,
                isUnderlined: last.isUnderlined,
                isStruckThrough: last.isStruckThrough,
                fontName: last.fontName,
                fontSize: last.fontSize
            )
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

/// The view-level bridge to AetherEngine's UIKit render surface.
struct AetherPlayerSurface: UIViewRepresentable {
    @ObservedObject var player: AetherPlayer

    final class HostingView: UIView {
        let engineView = AetherPlayerView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            engineView.backgroundColor = .black
            engineView.frame = bounds
            engineView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(engineView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
        }
    }

    final class Coordinator {
        let player: AetherPlayer

        init(player: AetherPlayer) {
            self.player = player
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player)
    }

    func makeUIView(context: Context) -> HostingView {
        let view = HostingView()
        player.bind(view: view.engineView)
        return view
    }

    func updateUIView(_ uiView: HostingView, context: Context) {
        player.bind(view: uiView.engineView)
    }

    static func dismantleUIView(_ uiView: HostingView, coordinator: Coordinator) {
        coordinator.player.unbind(view: uiView.engineView)
    }
}

#else
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

    init() {
        do {
            self.engine = try AetherEngine()
        } catch {
            fatalError("AetherEngine init failed: \(error)")
        }
        wireUpPublishers()
        observeAppLifecycle()
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
        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                self?.timeSubject.send(t)
            }
            .store(in: &cancellables)

        // Subtitle lookups ride the clock's SOURCE axis, which upstream
        // documents as the value to use for the subtitle overlay. It is NOT
        // interchangeable with currentTime:
        //  - On zero-based sources (VOD) the two match in steady play, but
        //    sourceTime holds the ON-SCREEN frame while a seek is in flight,
        //    so cues don't flash the scrub target's text (engine #49).
        //  - On live / mid-stream-joined sources (a tuner TS) sourceTime is
        //    offset by the session zero (engine #107): cue PTS arrive on the
        //    source axis (~8996s) while currentTime is elapsed (~0s), so
        //    matching against currentTime shows no subtitles at all.
        engine.clock.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
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
                self.observeVideoSize(of: avp)
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

    /// Rebuild the torn-down session at the preserved playhead.
    ///
    /// The reload is bounded and its failure is recoverable, because this is the
    /// only way back into a session the engine tore down. An unbounded
    /// fire-and-forget rebuild leaves the player wedged: the reload of a
    /// connection that went stale across a multi-hour sleep can hang the same
    /// way a cold start can (#245), and with `pendingReloadSince` already
    /// consumed, every later Play press just called `engine.play()` on a session
    /// with no player item. Exiting the player and replaying from the library
    /// was the only way out.
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
            print("[AetherPlayer] foreground reload: pos=\(self.engine.currentTime)")
            do {
                // No-ops if nothing is loaded or the session was stopped while
                // we waited (public stop() clears the engine's loadedURL). The
                // load auto-plays, which is correct: this path only runs when
                // the user intends playback.
                try await self.reloadWithDeadline()
                self.pendingReloadSince = nil
                print("[AetherPlayer] foreground reload done: state=\(self.engine.state) pos=\(self.engine.currentTime)")
            } catch {
                // Arm the deferred reload so the next Play press retries the
                // rebuild. Covers the playing-user entry too: that one reloads
                // eagerly with nothing armed, so without this a failure there
                // wedges the session just as badly.
                print("[AetherPlayer] foreground reload failed: \(error)")
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
            .compactMap { event -> SeekHoldEvent? in
                let outcome: SeekHoldEvent.Outcome
                switch event.outcome {
                case .began: outcome = .began
                case .landed(let rendered): outcome = .landed(renderedTime: rendered)
                case .stalled, .superseded: outcome = .settledElsewhere
                case .rejected: return nil
                }
                return SeekHoldEvent(id: event.id, outcome: outcome, target: event.target)
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
        let isHLS = Self.liveRoute(for: url, forceEngineDemux: forceEngineDemux) == .nativeHLS
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
            preferredSubtitleLanguages: Self.livePreferredSubtitleLanguages(),
            // DVB teletext caption page. libzvbi auto-detect (nil) only finds a
            // page the broadcast FLAGS as a subtitle page; AU FTA channels carry
            // captions on 801 without that flag, so auto-detect returns nothing.
            // Region-default to 801 for AU, otherwise auto-detect.
            teletextPage: Self.regionTeletextPage()
        )
        // Same reason as the VOD path: a zap is new content, and broadcast
        // mixes 4:3 SD with 16:9 HD channel to channel, so a reused slot must
        // not measure the new channel against the old one's picture rect.
        videoSize = .zero
        userIntendsToPlay = true
        pendingReloadSince = nil
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
            // The caller left the slot / retuned while the load was in flight.
            // Rethrow untouched so the type survives; wrapping it in a
            // PlayerError makes it indistinguishable from a real failure.
            if isCancellationError(error) { throw error }
            let pe = PlayerError.loadFailed(String(describing: error))
            errorSubject.send(pe)
            throw pe
        }
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

    private static func isHLSURL(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "m3u8" { return true }
        let text = url.absoluteString.lowercased()
        return text.contains(".m3u8") || text.contains("format=hls")
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
            },
            // Same teletext rule as Live TV: a teletext stream decodes the same
            // way whichever surface plays it (VOD recordings/rips included).
            teletextPage: Self.regionTeletextPage()
        )
        // New content, so the previous item's aspect ratio describes nothing.
        // Reset HERE rather than when `currentItem` goes nil: the engine also
        // swaps its player for SAME-content reasons (audio track switch,
        // background reopen), and zeroing on those would flash the caption
        // overlay out to full bounds for no reason. A next-episode swap reuses
        // this instance, so without this the overlay measures the new episode
        // against the old episode's picture rect until `presentationSize`
        // arrives.
        videoSize = .zero
        userIntendsToPlay = true
        pendingReloadSince = nil
        do {
            try await engine.load(url: url, startPosition: startTime, options: options)
        } catch {
            // User navigated away / switched items mid-load. Rethrow untouched
            // and stay off errorSubject: wrapping it as PlayerError.loadFailed
            // destroys the type, so downstream can no longer tell a
            // cancellation from a genuine startup failure (RIVULET-19).
            if isCancellationError(error) { throw error }
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
    func stop() {
        foregroundReloadTask?.cancel()
        pendingReloadSince = nil
        userIntendsToPlay = false
        engine.stop()
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

    // MARK: - Advanced stats (Info popup "stats for nerds" tab)

    /// Full "stats for nerds" snapshot for the Info popup's Advanced tab.
    /// Truthful and engine-sourced — nothing here is synthesized or guessed;
    /// every field is nil unless AetherEngine actually exposes it.
    ///
    /// Folds the two human-readable decoder labels (always readable while a
    /// session is active) with a 1:1 copy of the engine's 1 Hz `LiveTelemetry`
    /// (`engine.diagnostics.liveTelemetry`, sampled automatically on native
    /// load — this method starts no sampler, it is a pure read):
    ///  - `backend` ← `engine.activeVideoDecoder`, e.g. "VideoToolbox HEVC
    ///    (HW)", "dav1d AV1 (SW)". The engine's own string already
    ///    distinguishes HW/SW.
    ///  - `audioBridge` ← `engine.activeAudioDecoder`, e.g.
    ///    "Stream-copy (EAC3+JOC Atmos)", "TrueHD → FLAC bridge".
    ///  - all remaining fields ← `LiveTelemetry`, which is nil while idle /
    ///    before the first sample and on the `hls`/AVPlayer-bypass path (no
    ///    loopback pipeline). Its own fields are path-asymmetric, so the
    ///    Advanced view prunes absent rows rather than showing placeholders.
    func advancedStats() -> AetherAdvancedStats {
        let t = engine.diagnostics.liveTelemetry
        return AetherAdvancedStats(
            backend: engine.activeVideoDecoder,
            audioBridge: engine.activeAudioDecoder,
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
#endif
