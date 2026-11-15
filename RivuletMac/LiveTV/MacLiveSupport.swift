// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import Combine
import SwiftUI

/// Tunes a channel for the Mac player: the stream URL, headers, the Plex keepalive and the
/// messages iOS shows for a refused tune. No engine types, so the player feeds `Stream`
/// to its `loadLive` and shows `notice` as the failure (`IOSLivePlayback.load`).
@MainActor
final class MacLiveTuner: ObservableObject {
    struct Stream {
        let url: URL
        let headers: [String: String]
        let forceEngineDemux: Bool
    }

    @Published private(set) var notice: String?
    private let store = LiveTVDataStore.shared
    private let keepalive = PlexLiveTimelineKeepalive()
    private var watchTask: Task<Void, Never>?

    func tune(_ channel: UnifiedChannel) async -> Stream? {
        notice = nil
        keepalive.stop()
        watchTask?.cancel()
        watchTask = store.beganWatching(channel)
        let url: URL
        do {
            guard let resolved = try await store.resolveStreamURL(for: channel) else {
                notice = String(localized: "This channel has no stream.")
                return nil
            }
            url = resolved
        } catch {
            guard !isCancellationError(error) else { return nil }
            notice = error is PlexLiveTuneError
                ? String(localized: "Couldn't tune this channel. All tuners may be busy.")
                : (error as? TvheadendError)?.errorDescription ?? String(localized: "Couldn't tune this channel.")
            return nil
        }
        // A tune that finished after Close or a switch still holds the tuner.
        guard !Task.isCancelled else { PlexLiveTimelineKeepalive.release(url); return nil }
        keepalive.start(url: url)
        return Stream(url: url, headers: LiveTVClientIdentity.streamHeaders(for: channel),
                      forceEngineDemux: url.path.hasPrefix("/livetv/sessions/"))
    }

    /// Call when the engine could not load `stream`.
    func loadFailed(_ stream: Stream, channel: UnifiedChannel) async {
        keepalive.stop()
        if channel.sourceType != .plex, await LiveTunerBusy.sourceIsBusy(stream.url, headers: stream.headers) {
            notice = String(localized: "All tuners are busy. Stop another stream and try again.")
        }
    }

    func stop() {
        watchTask?.cancel()
        keepalive.stop()
    }
}

// MARK: - Artwork

/// A logo drawn whole; a faint halo keeps black wordmarks legible in dark mode.
struct MacLiveLogo: View {
    let url: URL?
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?

    init(url: URL?) {
        self.url = url
        _image = State(initialValue: url.flatMap(MacArtworkCache.shared.cachedImage(for:)))
    }

    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
        }
        .shadow(color: colorScheme == .dark ? .white.opacity(0.55) : .clear, radius: 1.5)
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = MacArtworkCache.shared.cachedImage(for: url) { image = cached; return }
            image = await MacArtworkCache.shared.image(for: url)
        }
    }
}

/// A programme's wide art: declared, or its icon once measured wide.
struct MacLiveWideArt: ViewModifier {
    let program: UnifiedProgram?
    @Binding var url: URL?

    func body(content: Content) -> some View {
        content.task(id: program?.id) {
            url = EPGImageClassifier.shared.wideArt(for: program)
            guard url == nil, let icon = program?.iconURL else { return }
            let kind = await EPGImageClassifier.shared.classify(icon) {
                await MacArtworkCache.shared.image(for: icon)?.size
            }
            if kind == .landscape, !Task.isCancelled { url = icon }
        }
    }
}

struct MacLivePill: View {
    enum Style { case red, glass }
    let text: String
    let dot: Bool
    let style: Style

    var body: some View {
        HStack(spacing: 4) {
            if dot {
                Circle().fill(style == .red ? Color.white : Color.red).frame(width: 6, height: 6)
            }
            Text(text)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(style == .red ? Color.red : Color.black.opacity(0.45)))
        .accessibilityHidden(true)
    }
}

// MARK: - Recording

extension View {
    /// The record choices dialog and the failure alert for `recorder`.
    func liveRecorder(_ recorder: LiveRecorder) -> some View {
        modifier(MacLiveRecorderPresenter(recorder: recorder))
    }
}

private struct MacLiveRecorderPresenter: ViewModifier {
    @ObservedObject var recorder: LiveRecorder

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                recorder.offer.map { String(localized: "Record \($0.program.displayTitle)") } ?? "",
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

/// SwiftUI rendering of `LiveMenu.sections`, for `.contextMenu`.
struct MacLiveMenuContent: View {
    let sections: [[LiveMenuAction]]

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

/// The record button of a programme: Record, or a Recording menu to cancel.
struct MacLiveRecordControl: View {
    let channel: UnifiedChannel
    let program: UnifiedProgram
    @ObservedObject var recorder: LiveRecorder
    @ObservedObject private var store = LiveTVDataStore.shared

    var body: some View {
        if program.endTime > Date(), store.canRecord(channel) {
            if let recording = store.activeRecording(for: program) {
                Menu {
                    Button(recording.status == .recording ? "Stop Recording" : "Cancel Recording",
                           systemImage: "stop.circle", role: .destructive) { recorder.cancel(recording) }
                    if recording.ruleIsSeries {
                        Button("Cancel Series", systemImage: "square.stack.3d.up.slash", role: .destructive) {
                            recorder.cancelSeries(of: recording)
                        }
                    }
                } label: {
                    Label(recording.status == .recording ? "Recording" : "Scheduled", systemImage: "record.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
            } else {
                Button { recorder.offerRecording(program, on: channel) } label: {
                    Label("Record", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .disabled(recorder.isLoadingOptions)
            }
        }
    }
}
