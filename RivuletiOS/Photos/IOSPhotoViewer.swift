// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit

/// Full-screen pager over a listing's photos and clips. Tap toggles the chrome;
/// the slideshow advances every 4 s, skips clips and wraps once every page is loaded.
struct IOSPhotoViewer: View {
    @ObservedObject var model: PhotoListingModel
    let onPlay: (MediaItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: MediaItemRef
    @State private var chrome = true
    @State private var slideshow = false
    /// Set only while this viewer is what turned the idle timer off.
    @State private var holdsDisplayAwake = false
    @Environment(\.scenePhase) private var scenePhase

    private static let interval: Duration = .seconds(4)

    init(model: PhotoListingModel, start: PhotoItem, onPlay: @escaping (MediaItem) -> Void) {
        self.model = model
        self.onPlay = onPlay
        _selection = State(initialValue: start.ref)
    }

    private var current: PhotoItem? { model.media.first { $0.ref == selection } }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(model.media, id: \.ref) { item in
                page(item)
                    .tag(item.ref)
                    .onAppear { model.loadMoreIfNeeded(after: item) }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .top) { if chrome { topBar } }
        .overlay(alignment: .bottom) { if chrome { caption } }
        .statusBarHidden(!chrome)
        .animation(.easeInOut(duration: 0.2), value: chrome)
        .onChange(of: slideshow) { _, on in setAwake(on) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { slideshow = false } }
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
        ZStack {
            IOSZoomableImage(url: item.full ?? item.thumbnail, placeholder: item.thumbnail) { chrome.toggle() }
            if item.kind == .clip, let clip = item.playable {
                Button { onPlay(clip) } label: {
                    Image(systemName: "play.circle.fill").font(.system(size: 72)).foregroundStyle(.white)
                        .shadow(radius: 4)
                }
                .accessibilityLabel("Play")
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close")
            Spacer()
            Button { slideshow.toggle() } label: {
                Image(systemName: slideshow ? "pause.fill" : "play.fill").font(.body.weight(.semibold)).padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(slideshow ? "Stop Slideshow" : "Start Slideshow")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 60)
    }

    @ViewBuilder
    private var caption: some View {
        if let current {
            VStack(spacing: 2) {
                Text(verbatim: current.title).font(.headline)
                if let date = current.date {
                    Text(date.formatted(date: .long, time: .omitted)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func setAwake(_ on: Bool) {
        let app = UIApplication.shared
        if on {
            guard !holdsDisplayAwake else { return }
            holdsDisplayAwake = !app.isIdleTimerDisabled
            app.isIdleTimerDisabled = true
        } else if holdsDisplayAwake {
            app.isIdleTimerDisabled = false
            holdsDisplayAwake = false
        }
    }

    /// Next photo after the current one, wrapping only when no more pages exist.
    private func advance() {
        let media = model.media
        guard let index = media.firstIndex(where: { $0.ref == selection }) else { return }
        if let next = PhotoViewerIndex.step(from: index, by: 1, count: media.count, wraps: !model.listing.hasMore,
                                            skipping: { media[$0].kind == .clip }) {
            withAnimation { selection = media[next].ref }
        } else if !model.listing.hasMore || model.failed {
            slideshow = false
        } else {
            model.listing.loadMore()
        }
    }
}

/// One image in a UIScrollView: pinch to 4x, double-tap between 1x and 2.5x, single tap reported.
private struct IOSZoomableImage: View {
    let url: URL?
    let placeholder: URL?
    let onTap: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                IOSZoomScrollView(image: image, onTap: onTap)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle()).onTapGesture(perform: onTap)
            }
        }
        .task(id: url) {
            guard let url else { return }
            if let cached = IOSArtworkCache.shared.cachedImage(for: url) { image = cached; return }
            // The tile's thumbnail is usually cached already: show it while the full image loads.
            if image == nil, let placeholder { image = IOSArtworkCache.shared.cachedImage(for: placeholder) }
            if let full = await IOSArtworkCache.shared.image(for: url) { image = full }
        }
    }
}

private struct IOSZoomScrollView: UIViewRepresentable {
    let image: UIImage
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scroll = scroll

        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: double)
        scroll.addGestureRecognizer(double)
        scroll.addGestureRecognizer(single)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTap = onTap
        if coordinator.imageView?.image !== image {
            coordinator.imageView?.image = image
            scroll.zoomScale = 1
        }
        coordinator.layout()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scroll: UIScrollView?
        var onTap: () -> Void = {}

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

        /// Fits the image view to the scroll view at 1x.
        func layout() {
            guard let scroll, let imageView, scroll.zoomScale == 1, scroll.bounds.size != .zero else { return }
            imageView.frame = CGRect(origin: .zero, size: scroll.bounds.size)
            scroll.contentSize = scroll.bounds.size
        }

        private func center() {
            guard let scroll, let imageView else { return }
            let x = max(0, (scroll.bounds.width - imageView.frame.width) / 2)
            let y = max(0, (scroll.bounds.height - imageView.frame.height) / 2)
            imageView.frame.origin = CGPoint(x: x, y: y)
        }

        @objc func singleTap() { onTap() }

        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let scale: CGFloat = 2.5
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}
