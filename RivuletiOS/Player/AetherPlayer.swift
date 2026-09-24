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
//  Platform Boundary) -- and because keeping them together forced
//  `@preconcurrency import AVFoundation` onto the shipping tvOS build.
//

@preconcurrency import AVFoundation
import Combine
import CoreMedia
import Foundation
import SwiftUI
import UIKit
import AetherEngine

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
