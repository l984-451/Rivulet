// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import MapKit
import SwiftUI

/// Full-window photo viewer over a grid's listing. Arrows page, Space runs a slideshow (the Photos
/// settings: interval, transition, clips; wraps once every page is loaded), Command-I shows info, Escape closes,
/// pinch zooms.
struct MacPhotoViewer: View {
    @ObservedObject var model: PhotoListingModel
    let onClose: () -> Void
    @Environment(\.macActions) private var actions
    @EnvironmentObject private var playback: MacPlaybackController
    /// A slideshow clip is playing: the show carries on once the player closes.
    @State private var resumeAfterClip = false
    @State private var index: Int
    @State private var slideshow = false
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var drag: CGSize = .zero
    @FocusState private var focused: Bool
    @State private var awake: NSObjectProtocol?
    @State private var showsInfo = false
    @State private var showsHint = false
    /// The shown photo's place, once geocoded.
    @State private var place: (ref: MediaItemRef, name: String)?

    init(model: PhotoListingModel, start: PhotoItem, running: Bool = false, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _index = State(initialValue: model.media.firstIndex(of: start) ?? 0)
        _slideshow = State(initialValue: running)
    }

    private var item: PhotoItem? { model.media.indices.contains(index) ? model.media[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let item {
                // Outside the zoom: only the sharp photo pans and zooms.
                MacPhotoFill(item: item)
                    .id(item.ref)
                    .transition(.opacity)
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
                    .id(item.ref)
                    .transition(.opacity)
            }
            controls
        }
        .inspector(isPresented: $showsInfo) {
            if let item {
                MacPhotoInfo(item: item, provider: model.listing.source()?.provider) { model.toggleFavorite(item) }
                    .inspectorColumnWidth(min: 260, ideal: 300)
            }
        }
        .onChange(of: showsInfo) { _, open in if open { slideshow = false } }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; if slideshow { setAwake(true) } }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.space) { slideshow.toggle(); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onExitCommand(perform: onClose)
        .onChange(of: index) { zoom = 1; pan = .zero }
        .onChange(of: slideshow) { _, on in setAwake(on) }
        .onDisappear { slideshow = false; setAwake(false) }
        .task(id: item?.ref) {
            guard let item, let coordinate = item.coordinate else { return }
            let name = await PhotoPlaceNames.shared.name(for: coordinate)
            guard let name, !Task.isCancelled, self.item?.ref == item.ref else { return }
            withAnimation(.easeInOut(duration: 0.2)) { place = (item.ref, name) }
        }
        .onChange(of: playback.playbackError) { _, error in
            if error != nil { resumeAfterClip = false }
        }
        .onChange(of: playback.isPresented) { _, presented in
            guard !presented, resumeAfterClip else { return }
            resumeAfterClip = false
            focused = true
            slideshow = true
            advance()
        }
        .task(id: slideshow) {
            guard slideshow else { return }
            if let item, item.kind == .clip, PhotoPreferences.playsClips { playInShow(item); return }
            while slideshow, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(PhotoPreferences.slideInterval))
                if slideshow, !Task.isCancelled { advance() }
            }
        }
    }

    @ViewBuilder
    private func page(_ item: PhotoItem) -> some View {
        MacPhotoPage(item: item, panAndZoom: slideshow && PhotoPreferences.transition == .panAndZoom,
                     interval: PhotoPreferences.slideInterval)
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
                // The player's title block: the place over the day taken.
                if let item, case let shown = PhotoInfoLines.caption(
                    date: item.date, place: place?.ref == item.ref ? place?.name : nil), let title = shown.title {
                    VStack(alignment: .leading, spacing: 1) {
                        if let eyebrow = shown.eyebrow {
                            Text(verbatim: eyebrow).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                        Text(verbatim: title).font(.headline).lineLimit(1).foregroundStyle(.white)
                    }
                }
                Spacer()
                Button { showsInfo.toggle() } label: { Image(systemName: "info.circle") }
                    .keyboardShortcut("i", modifiers: .command)
                    .help("Info")
                if let item {
                    Button { model.toggleFavorite(item) } label: { Image(systemName: item.isFavorite ? "heart.circle.fill" : "heart.circle") }
                        .help(item.isFavorite ? Text("Unfavorite") : Text("Favorite"))
                }
                Button { slideshow.toggle() } label: { Image(systemName: slideshow ? "pause.circle.fill" : "play.circle.fill") }
                    .help(slideshow ? "Pause Slideshow" : "Start Slideshow")
            }
            .font(.title)
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Text("\(index + 1) of \(model.media.count)").font(.callout).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 4) {
                Text(verbatim: "\u{2318}I")
                Text("Info")
            }
            .font(.callout)
            .foregroundStyle(.white.opacity(0.7))
            .opacity(showsHint && !slideshow && !showsInfo ? 1 : 0)
            .animation(.easeInOut(duration: 0.5), value: showsHint)
        }
        .padding(16)
        // Each photo shows the hint, then lets it go, as the tvOS caption does.
        .task(id: index) {
            showsHint = true
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { showsHint = false }
        }
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

    /// Hands a clip to the player; the show resumes after it closes.
    private func playInShow(_ item: PhotoItem) {
        guard let clip = item.playable else { return }
        resumeAfterClip = true
        slideshow = false
        actions.play(clip)
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
        let skipsClips = !PhotoPreferences.playsClips
        if let next = PhotoViewerIndex.step(from: index, by: 1, count: media.count, wraps: !model.listing.hasMore,
                                            skipping: { skipsClips && media[$0].kind == .clip }) {
            withAnimation(.easeInOut(duration: 1)) { index = next }
            model.loadMoreIfNeeded(after: media[next])
            if media[next].kind == .clip { playInShow(media[next]) }
        } else if !model.listing.hasMore || model.failed {
            slideshow = false
        } else {
            model.listing.loadMore()
        }
    }
}

/// The thumbnail blurred past reading and darkened, behind a photo that leaves bars;
/// one that fills the window sits on black.
private struct MacPhotoFill: View {
    let item: PhotoItem
    @State private var image: NSImage?

    init(item: PhotoItem) {
        self.item = item
        _image = State(initialValue: item.thumbnail.flatMap(MacArtworkCache.shared.cachedImage(for:)))
    }

    var body: some View {
        GeometryReader { proxy in
            if let image, PhotoLetterbox.needsFill(imageSize: image.size, screenSize: proxy.size) {
                Image(nsImage: image).resizable().scaledToFill()
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
            image = await MacArtworkCache.shared.image(for: url)
        }
    }
}

/// One photo, the grid's thumbnail until the full image arrives. Pan and Zoom grows it 8% and
/// drifts it, past the fade-out that follows.
private struct MacPhotoPage: View {
    let item: PhotoItem
    let panAndZoom: Bool
    let interval: TimeInterval
    @State private var image: NSImage?
    @State private var moved = false

    init(item: PhotoItem, panAndZoom: Bool, interval: TimeInterval) {
        self.item = item
        self.panAndZoom = panAndZoom
        self.interval = interval
        _image = State(initialValue: (item.full ?? item.thumbnail).flatMap(MacArtworkCache.shared.cachedImage(for:))
            ?? item.thumbnail.flatMap(MacArtworkCache.shared.cachedImage(for:)))
    }

    var body: some View {
        let drift: CGFloat = item.ref.hashValue & 1 == 0 ? 14 : -14
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() } else { ProgressView() }
        }
        .scaleEffect(moved ? 1.08 : 1)
        .offset(x: moved ? drift : 0, y: moved ? -drift / 2 : 0)
        .task(id: panAndZoom) {
            if panAndZoom { withAnimation(.linear(duration: interval + 1)) { moved = true } } else { moved = false }
        }
        .task(id: item.ref) {
            guard let url = item.full ?? item.thumbnail,
                  let loaded = await MacArtworkCache.shared.image(for: url), !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// The inspector: the photo's lines, a map when it has a place, and Favorite.
private struct MacPhotoInfo: View {
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
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(verbatim: line).font(index == 0 ? .headline : .body)
                        .foregroundStyle(index == 0 ? .primary : .secondary)
                        .textSelection(.enabled)
                }
                if let point = item.coordinate {
                    let center = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                    Map(initialPosition: .region(MKCoordinateRegion(center: center, latitudinalMeters: 2000,
                                                                    longitudinalMeters: 2000))) {
                        Marker(item.title, coordinate: center)
                    }
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .id(item.ref)
                }
                Button(action: onFavorite) {
                    Label(item.isFavorite ? "Unfavorite" : "Favorite",
                          systemImage: item.isFavorite ? "heart.fill" : "heart")
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .task(id: item.ref) {
            guard let provider else { return }
            let full = await PhotoDetailsCache.load(item, provider: provider)
            guard !Task.isCancelled else { return }
            loaded = (full.ref, full.details)
        }
    }
}
