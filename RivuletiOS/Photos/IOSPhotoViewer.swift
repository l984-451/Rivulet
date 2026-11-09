// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import MapKit
import SwiftUI
import UIKit

/// Full-screen pager over a listing's photos and clips. Tap toggles the chrome. The slideshow
/// follows the Photos settings (interval, transition, clips) and wraps once every page is loaded.
struct IOSPhotoViewer: View {
    @ObservedObject var model: PhotoListingModel
    /// Plays a clip; `inShow` asks the host to resume the slideshow after it.
    let onPlay: (PhotoItem, _ inShow: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: MediaItemRef
    @State private var chrome = true
    @State private var slideshow = false
    /// Set only while this viewer is what turned the idle timer off.
    @State private var holdsDisplayAwake = false
    @State private var showsInfo = false
    /// The shown photo's place, once geocoded.
    @State private var place: (ref: MediaItemRef, name: String)?
    @Environment(\.scenePhase) private var scenePhase

    init(model: PhotoListingModel, start: PhotoItem, running: Bool = false,
         onPlay: @escaping (PhotoItem, Bool) -> Void) {
        self.model = model
        self.onPlay = onPlay
        _selection = State(initialValue: start.ref)
        _slideshow = State(initialValue: running)
    }

    private var current: PhotoItem? { model.media.first { $0.ref == selection } }

    var body: some View {
        Group {
            if slideshow {
                stage
            } else {
                TabView(selection: $selection) {
                    ForEach(model.media, id: \.ref) { item in
                        page(item)
                            .tag(item.ref)
                            .onAppear { model.loadMoreIfNeeded(after: item) }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .top) { if chrome { topBar } }
        .overlay(alignment: .bottom) { if chrome { caption } }
        .statusBarHidden(!chrome)
        .animation(.easeInOut(duration: 0.2), value: chrome)
        .onChange(of: slideshow) { _, on in setAwake(on) }
        .onChange(of: showsInfo) { _, open in if open { slideshow = false } }
        .sheet(isPresented: $showsInfo) {
            if let current {
                IOSPhotoInfoSheet(item: current, provider: model.listing.source()?.provider) {
                    model.toggleFavorite(current)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { slideshow = false } }
        .onAppear { if slideshow { setAwake(true) } }
        .task(id: current?.ref) {
            guard let current, let coordinate = current.coordinate else { return }
            let name = await PhotoPlaceNames.shared.name(for: coordinate)
            guard let name, !Task.isCancelled, self.current?.ref == current.ref else { return }
            withAnimation(.easeInOut(duration: 0.2)) { place = (current.ref, name) }
        }
        .onDisappear { slideshow = false; setAwake(false) }
        .task(id: slideshow) {
            guard slideshow else { return }
            if let current, current.kind == .clip, PhotoPreferences.playsClips { onPlay(current, true); return }
            while slideshow, !Task.isCancelled {
                Task { await prefetchNext() }
                try? await Task.sleep(for: .seconds(PhotoPreferences.slideInterval))
                if slideshow, !Task.isCancelled { advance() }
            }
        }
    }

    /// The slideshow's own page: one photo at a time, dissolving into the next.
    private var stage: some View {
        ZStack {
            if let current {
                IOSSlide(item: current, panAndZoom: PhotoPreferences.transition == .panAndZoom,
                         interval: PhotoPreferences.slideInterval) { chrome.toggle() }
                    .id(current.ref)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Warms the cache with the next photo so the dissolve starts on a picture, not a spinner.
    private func prefetchNext() async {
        let media = model.media
        guard let index = media.firstIndex(where: { $0.ref == selection }), index + 1 < media.count,
              let url = media[index + 1].full ?? media[index + 1].thumbnail else { return }
        _ = await IOSArtworkCache.shared.image(for: url)
    }

    @ViewBuilder
    private func page(_ item: PhotoItem) -> some View {
        ZStack {
            IOSPhotoFill(item: item)
            IOSZoomableImage(url: item.full ?? item.thumbnail, placeholder: item.thumbnail) { chrome.toggle() }
            if item.kind == .clip {
                Button { onPlay(item, false) } label: {
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
            if current != nil {
                Button { showsInfo = true } label: {
                    Image(systemName: "info").font(.body.weight(.semibold)).padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Info")
            }
            if let current {
                Button { model.toggleFavorite(current) } label: {
                    Image(systemName: current.isFavorite ? "heart.fill" : "heart").font(.body.weight(.semibold))
                        .padding(12).background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(current.isFavorite ? Text("Unfavorite") : Text("Favorite"))
            }
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

    /// The player's title block: the place over the day taken.
    @ViewBuilder
    private var caption: some View {
        let shown = current.map { item in
            PhotoInfoLines.caption(date: item.date, place: place?.ref == item.ref ? place?.name : nil)
        }
        if let shown, let title = shown.title {
            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow = shown.eyebrow {
                    Text(verbatim: eyebrow).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Text(verbatim: title).font(.headline).lineLimit(2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        let skipsClips = !PhotoPreferences.playsClips
        if let next = PhotoViewerIndex.step(from: index, by: 1, count: media.count, wraps: !model.listing.hasMore,
                                            skipping: { skipsClips && media[$0].kind == .clip }) {
            withAnimation(.easeInOut(duration: 1)) { selection = media[next].ref }
            if media[next].kind == .clip { onPlay(media[next], true) }
        } else if !model.listing.hasMore || model.failed {
            slideshow = false
        } else {
            model.listing.loadMore()
        }
    }
}

/// One slideshow photo; Pan and Zoom grows it 8% and drifts it, past the fade-out that follows.
private struct IOSSlide: View {
    let item: PhotoItem
    let panAndZoom: Bool
    let interval: TimeInterval
    let onTap: () -> Void
    @State private var image: UIImage?
    @State private var moved = false

    var body: some View {
        let drift: CGFloat = item.ref.hashValue & 1 == 0 ? 14 : -14
        ZStack {
            IOSPhotoFill(item: item)
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit() } else { ProgressView().tint(.white) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(moved ? 1.08 : 1)
            .offset(x: moved ? drift : 0, y: moved ? -drift / 2 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .task {
            guard let url = item.full ?? item.thumbnail else { return }
            image = IOSArtworkCache.shared.cachedImage(for: url) ?? item.thumbnail.flatMap(IOSArtworkCache.shared.cachedImage(for:))
            if let full = await IOSArtworkCache.shared.image(for: url) { image = full }
        }
        .onAppear {
            if panAndZoom { withAnimation(.linear(duration: interval + 1)) { moved = true } }
        }
    }
}

/// The thumbnail blurred past reading and darkened, behind a photo that leaves bars;
/// one that fills the screen sits on black.
private struct IOSPhotoFill: View {
    let item: PhotoItem
    @State private var image: UIImage?

    init(item: PhotoItem) {
        self.item = item
        _image = State(initialValue: item.thumbnail.flatMap(IOSArtworkCache.shared.cachedImage(for:)))
    }

    var body: some View {
        GeometryReader { proxy in
            if let image, PhotoLetterbox.needsFill(imageSize: image.size, screenSize: proxy.size) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .blur(radius: 60, opaque: true)
                    .overlay(Color.black.opacity(0.55))
                    .clipped()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: item.ref) {
            guard image == nil, let url = item.thumbnail else { return }
            image = await IOSArtworkCache.shared.image(for: url)
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

/// The info pane as a sheet: the photo's lines, a map when it has a place, and Favorite.
private struct IOSPhotoInfoSheet: View {
    let item: PhotoItem
    let provider: (any PhotoProvider)?
    let onFavorite: () -> Void
    /// Fetched details, used only while they belong to the photo on show.
    @State private var loaded: (ref: MediaItemRef, details: PhotoDetails?)?

    private var lines: [String] {
        var shown = PhotoDetailsCache.known(item)
        if let loaded, loaded.ref == item.ref { shown.details = loaded.details }
        return PhotoInfoLines.lines(for: shown)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(lines.enumerated()), id: \.offset) { Text(verbatim: $0.element) }
                }
                if let point = item.coordinate {
                    let center = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                    Map(initialPosition: .region(MKCoordinateRegion(center: center, latitudinalMeters: 2000,
                                                                    longitudinalMeters: 2000))) {
                        Marker(item.title, coordinate: center)
                    }
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    Button(action: onFavorite) {
                        Label(item.isFavorite ? "Unfavorite" : "Favorite",
                              systemImage: item.isFavorite ? "heart.fill" : "heart")
                    }
                }
            }
            .navigationTitle(Text(verbatim: item.title))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: item.ref) {
            guard let provider else { return }
            let full = await PhotoDetailsCache.load(item, provider: provider)
            guard !Task.isCancelled else { return }
            loaded = (full.ref, full.details)
        }
    }
}
