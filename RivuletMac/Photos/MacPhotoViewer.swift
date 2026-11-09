// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import SwiftUI

/// Full-window photo viewer over a grid's listing. Arrows page, Space runs a slideshow
/// (4 s, skips clips, wraps once every page is loaded), Escape closes, pinch zooms.
struct MacPhotoViewer: View {
    @ObservedObject var model: PhotoListingModel
    let onClose: () -> Void
    @Environment(\.macActions) private var actions
    @State private var index: Int
    @State private var slideshow = false
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var drag: CGSize = .zero
    @FocusState private var focused: Bool
    @State private var awake: NSObjectProtocol?

    private static let interval: Duration = .seconds(4)

    init(model: PhotoListingModel, start: PhotoItem, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _index = State(initialValue: model.media.firstIndex(of: start) ?? 0)
    }

    private var item: PhotoItem? { model.media.indices.contains(index) ? model.media[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let item {
                page(item)
                    .scaleEffect(zoom * pinch)
                    .offset(x: pan.width + drag.width, y: pan.height + drag.height)
                    .gesture(MagnifyGesture()
                        .onChanged { pinch = $0.magnification }
                        .onEnded { zoom = max(1, min(zoom * $0.magnification, 8)); pinch = 1; if zoom == 1 { pan = .zero } })
                    .simultaneousGesture(DragGesture()
                        .onChanged { if zoom > 1 { drag = $0.translation } }
                        .onEnded { if zoom > 1 { pan.width += $0.translation.width; pan.height += $0.translation.height }; drag = .zero })
                    .onTapGesture(count: 2) { zoom = 1; pan = .zero }
            }
            controls
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.space) { slideshow.toggle(); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onExitCommand(perform: onClose)
        .onChange(of: index) { zoom = 1; pan = .zero }
        .onChange(of: slideshow) { _, on in setAwake(on) }
        .onDisappear { slideshow = false; setAwake(false) }
        .task(id: slideshow) {
            while slideshow, !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                if slideshow, !Task.isCancelled { advance() }
            }
        }
    }

    @ViewBuilder
    private func page(_ item: PhotoItem) -> some View {
        MacPhotoPage(item: item)
            .id(item.ref)
            .overlay {
                if item.kind == .clip, let playable = item.playable {
                    Button {
                        slideshow = false
                        actions.play(playable)
                    } label: {
                        Image(systemName: "play.circle.fill").font(.system(size: 72)).foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                }
            }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .help("Close")
                Spacer()
                if let item { Text(verbatim: item.title).lineLimit(1).foregroundStyle(.white.opacity(0.8)) }
                Spacer()
                Button { slideshow.toggle() } label: { Image(systemName: slideshow ? "pause.circle.fill" : "play.circle.fill") }
                    .help(slideshow ? "Pause Slideshow" : "Start Slideshow")
            }
            .font(.title)
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Text("\(index + 1) of \(model.media.count)").font(.callout).foregroundStyle(.white.opacity(0.7))
        }
        .padding(16)
    }

    /// Keeps the display on while the slideshow runs.
    private func setAwake(_ on: Bool) {
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                          reason: "Photo slideshow")
        } else if !on, let activity = awake {
            ProcessInfo.processInfo.endActivity(activity)
            awake = nil
        }
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard model.media.indices.contains(next) else { return }
        index = next
        model.loadMoreIfNeeded(after: model.media[next])
    }

    /// The next photo, skipping clips; at the end waits for the next page, else wraps.
    private func advance() {
        let media = model.media
        if let next = PhotoViewerIndex.step(from: index, by: 1, count: media.count, wraps: !model.listing.hasMore,
                                            skipping: { media[$0].kind == .clip }) {
            index = next
            model.loadMoreIfNeeded(after: media[next])
        } else if !model.listing.hasMore || model.failed {
            slideshow = false
        } else {
            model.listing.loadMore()
        }
    }
}

/// One photo, the grid's thumbnail until the full image arrives.
private struct MacPhotoPage: View {
    let item: PhotoItem
    @State private var image: NSImage?

    init(item: PhotoItem) {
        self.item = item
        _image = State(initialValue: (item.full ?? item.thumbnail).flatMap(MacArtworkCache.shared.cachedImage(for:))
            ?? item.thumbnail.flatMap(MacArtworkCache.shared.cachedImage(for:)))
    }

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() } else { ProgressView() }
        }
        .task(id: item.ref) {
            guard let url = item.full ?? item.thumbnail,
                  let loaded = await MacArtworkCache.shared.image(for: url), !Task.isCancelled else { return }
            image = loaded
        }
    }
}
