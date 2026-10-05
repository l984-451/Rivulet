// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import SwiftUI
import UIKit

/// Same key and values as tvOS `liveTVLayout`.
enum IOSLiveLayout: String, CaseIterable {
    case browse = "Browse"
    case guide = "Guide"

    static let storageKey = "liveTVLayout"

    var title: String { self == .browse ? "What's On" : "Guide" }
}

enum IOSLiveRoute: Hashable {
    case recordings
}

/// A programme the sheet describes. `program` is nil for a channel with no guide data.
struct IOSLiveProgrammeSelection: Identifiable {
    let channel: UnifiedChannel
    let program: UnifiedProgram?
    var id: String { program?.id ?? channel.id }
}

extension UnifiedChannel {
    /// "7 · BBC One", or the name alone.
    var numberAndName: String {
        [channelNumber.map(String.init), name].compactMap { $0 }.joined(separator: " · ")
    }
}

extension UnifiedProgram {
    var timeRange: String {
        let style = Date.FormatStyle.dateTime.hour().minute()
        return "\(startTime.formatted(style)) to \(endTime.formatted(style))"
    }
}

// MARK: - Playing

extension IOSPlaybackController {
    /// One tap from a channel to full-screen playback.
    func playLive(_ channel: UnifiedChannel) {
        start(IOSLivePlayback(channel: channel))
    }
}

// MARK: - Artwork

/// A logo drawn whole (scaled to fit), through the shared cache. On dark
/// backgrounds a faint halo keeps black wordmarks legible.
struct IOSLiveLogo: View {
    let url: URL?
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?

    init(url: URL?) {
        self.url = url
        _image = State(initialValue: url.flatMap(IOSArtworkCache.shared.cachedImage(for:)))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            }
        }
        .shadow(color: colorScheme == .dark ? .white.opacity(0.55) : .clear, radius: 1.5)
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = IOSArtworkCache.shared.cachedImage(for: url) { image = cached; return }
            image = await IOSArtworkCache.shared.image(for: url)
        }
    }
}

/// A programme's wide art: declared, or its icon once measured wide.
struct IOSLiveWideArt: ViewModifier {
    let program: UnifiedProgram?
    @Binding var url: URL?

    func body(content: Content) -> some View {
        content.task(id: program?.id) {
            url = EPGImageClassifier.shared.wideArt(for: program)
            guard url == nil, let icon = program?.iconURL else { return }
            let kind = await EPGImageClassifier.shared.classify(icon) {
                await IOSArtworkCache.shared.image(for: icon)?.size
            }
            if kind == .landscape, !Task.isCancelled { url = icon }
        }
    }
}

// MARK: - Recording

/// Record offers and recording changes, with the tvOS copy for failures.
/// Each presenting context (tab, sheet, player) owns one.
@MainActor
final class IOSLiveRecorder: ObservableObject {
    struct Offer: Identifiable {
        let id = UUID()
        let program: UnifiedProgram
        let channel: UnifiedChannel
        let options: [LiveTVRecordOption]
    }

    struct Failure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published var offer: Offer?
    @Published var failure: Failure?
    @Published private(set) var isLoadingOptions = false

    private var store: LiveTVDataStore { .shared }

    /// Loads the source's record options and asks which one.
    func offerRecording(_ program: UnifiedProgram, on channel: UnifiedChannel) {
        isLoadingOptions = true
        Task {
            defer { isLoadingOptions = false }
            do {
                let options = try await store.recordOptions(for: program, on: channel)
                if options.isEmpty {
                    failure = Failure(title: "Can't Record", message: "The server offered no way to record this programme.")
                } else {
                    offer = Offer(program: program, channel: channel, options: options)
                }
            } catch {
                failure = Failure(title: "Can't Record", message: error.localizedDescription)
            }
        }
    }

    func record(_ option: LiveTVRecordOption, offer: Offer) {
        run { try await LiveTVDataStore.shared.record(option, program: offer.program, on: offer.channel) }
    }

    func cancel(_ recording: LiveTVScheduledRecording) {
        run { try await LiveTVDataStore.shared.cancel(recording) }
    }

    func cancelSeries(of recording: LiveTVScheduledRecording) {
        run { try await LiveTVDataStore.shared.cancelSeries(of: recording) }
    }

    func delete(_ rule: LiveTVRecordingRule, then done: @escaping () -> Void = {}) {
        run({ try await LiveTVDataStore.shared.delete(rule) }, then: done)
    }

    private func run(_ change: @escaping () async throws -> Void, then done: @escaping () -> Void = {}) {
        Task {
            do {
                try await change()
                done()
            } catch {
                failure = Failure(title: "Recording Didn't Change", message: error.localizedDescription)
            }
        }
    }
}

extension View {
    /// The record choices dialog and the failure alert for `recorder`.
    func liveRecorder(_ recorder: IOSLiveRecorder) -> some View {
        modifier(IOSLiveRecorderPresenter(recorder: recorder))
    }
}

private struct IOSLiveRecorderPresenter: ViewModifier {
    @ObservedObject var recorder: IOSLiveRecorder

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                recorder.offer.map { "Record \($0.program.displayTitle)" } ?? "",
                isPresented: Binding(get: { recorder.offer != nil }, set: { if !$0 { recorder.offer = nil } }),
                titleVisibility: .visible,
                presenting: recorder.offer
            ) { offer in
                ForEach(offer.options) { option in
                    Button(option.title) { recorder.record(option, offer: offer) }
                }
            }
            .alert(
                recorder.failure?.title ?? "",
                isPresented: Binding(get: { recorder.failure != nil }, set: { if !$0 { recorder.failure = nil } }),
                presenting: recorder.failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
    }
}

// MARK: - Menus

/// One long-press menu entry. Built once, drawn as SwiftUI buttons or UIActions.
struct IOSLiveMenuAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var isDestructive = false
    let perform: () -> Void
}

/// The tvOS `LiveProgramMenu` rules in HIG order: Watch, Record, Favorite.
@MainActor
enum IOSLiveMenu {
    static func sections(
        channel: UnifiedChannel,
        program: UnifiedProgram?,
        recorder: IOSLiveRecorder,
        watch: @escaping (UnifiedChannel) -> Void,
        details: ((IOSLiveProgrammeSelection) -> Void)? = nil
    ) -> [[IOSLiveMenuAction]] {
        let store = LiveTVDataStore.shared
        let airingNow = program?.isCurrentlyAiring ?? true
        var watchGroup = [IOSLiveMenuAction(
            id: "watch",
            title: airingNow ? "Watch" : "Watch \(channel.name)",
            systemImage: "play.fill"
        ) { watch(channel) }]
        if let details, program != nil {
            watchGroup.append(IOSLiveMenuAction(id: "details", title: "Details", systemImage: "info.circle") {
                details(IOSLiveProgrammeSelection(channel: channel, program: program))
            })
        }

        var recordGroup: [IOSLiveMenuAction] = []
        if let program, program.endTime > Date(), store.canRecord(channel) {
            if let recording = store.activeRecording(for: program) {
                recordGroup.append(IOSLiveMenuAction(
                    id: "cancel",
                    title: recording.status == .recording ? "Stop Recording" : "Cancel Recording",
                    systemImage: "stop.circle",
                    isDestructive: true
                ) { recorder.cancel(recording) })
                if recording.ruleIsSeries {
                    recordGroup.append(IOSLiveMenuAction(
                        id: "series",
                        title: "Cancel Series",
                        systemImage: "square.stack.3d.up.slash",
                        isDestructive: true
                    ) { recorder.cancelSeries(of: recording) })
                }
            } else {
                recordGroup.append(IOSLiveMenuAction(id: "record", title: "Record…", systemImage: "record.circle") {
                    recorder.offerRecording(program, on: channel)
                })
            }
        }

        var favoriteGroup: [IOSLiveMenuAction] = []
        // A channel favourited only in Plex stays one; that list is Plex's.
        if store.isFavorite(channel) || !channel.isFavourite {
            let isFavorite = store.isFavorite(channel)
            favoriteGroup.append(IOSLiveMenuAction(
                id: "favorite",
                title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: isFavorite ? "star.slash" : "star"
            ) { store.toggleFavorite(channel) })
        }
        return [watchGroup, recordGroup, favoriteGroup].filter { !$0.isEmpty }
    }

    static func uiMenu(_ sections: [[IOSLiveMenuAction]]) -> UIMenu {
        UIMenu(children: sections.map { group in
            UIMenu(options: .displayInline, children: group.map { action in
                UIAction(
                    title: action.title,
                    image: UIImage(systemName: action.systemImage),
                    attributes: action.isDestructive ? .destructive : []
                ) { _ in action.perform() }
            })
        })
    }
}

/// SwiftUI rendering of `IOSLiveMenu.sections`.
struct IOSLiveMenuContent: View {
    let sections: [[IOSLiveMenuAction]]

    var body: some View {
        ForEach(sections.indices, id: \.self) { index in
            Section {
                ForEach(sections[index]) { action in
                    Button(role: action.isDestructive ? .destructive : nil, action: action.perform) {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
            }
        }
    }
}
