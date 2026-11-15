// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import SwiftUI
import UIKit

enum IOSLiveRoute: Hashable {
    case recordings
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

extension View {
    /// The record choices dialog and the failure alert for `recorder`.
    func liveRecorder(_ recorder: LiveRecorder) -> some View {
        modifier(IOSLiveRecorderPresenter(recorder: recorder))
    }
}

private struct IOSLiveRecorderPresenter: ViewModifier {
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

// MARK: - Menus

extension LiveMenu {
    static func uiMenu(_ sections: [[LiveMenuAction]]) -> UIMenu {
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

/// SwiftUI rendering of `LiveMenu.sections`.
struct IOSLiveMenuContent: View {
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
