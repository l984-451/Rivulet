// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// A photo library's root or one folder of it: albums first, then photos and clips, paged.
struct IOSPhotoLibraryView: View {
    let library: MediaLibrary
    var folder: PhotoItem?
    /// One of the root's memories, opened as a flat grid with no albums.
    var memory: PhotoMemory?
    var showsAccount = false
    /// Played once the viewer has finished dismissing.
    @State private var pendingClip: PhotoItem?
    @StateObject private var model: PhotoListingModel
    @State private var query: PhotoQuery
    @State private var viewing: Start?
    /// A clip the slideshow handed to the player: the show picks up after it once the player closes.
    @State private var resume: (model: PhotoListingModel, clip: PhotoItem)?
    @State private var resumeArmed = false
    @State private var shuffling = false
    @Environment(\.plexActions) private var actions
    @EnvironmentObject private var playback: IOSPlaybackController

    private struct Start: Identifiable {
        let id = UUID()
        let model: PhotoListingModel
        let item: PhotoItem
        var running = false
    }

    init(library: MediaLibrary, folder: PhotoItem? = nil, memory: PhotoMemory? = nil, showsAccount: Bool = false) {
        self.library = library
        self.folder = folder
        self.memory = memory
        self.showsAccount = showsAccount
        let query = PhotoPreferences.query(for: library, narrowedBy: memory?.query ?? .default)
        _query = State(initialValue: query)
        let source = PhotoListing.source(for: library)
        _model = StateObject(wrappedValue: PhotoListingModel(
            listing: PhotoListing(folder: folder?.ref, query: query, source: memory?.source(over: source) ?? source)))
    }

    var body: some View {
        ScrollView {
            if folder == nil, memory == nil {
                IOSPhotoMemoriesRow(library: library, ready: !model.folders.isEmpty || !model.media.isEmpty)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
                ForEach(model.folders, id: \.ref) { album in
                    NavigationLink {
                        IOSPhotoLibraryView(library: library, folder: album).iosPlexActionHost()
                    } label: {
                        IOSPhotoTile(item: album)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(model.media, id: \.ref) { item in
                    Button { viewing = Start(model: model, item: item) } label: { IOSPhotoTile(item: item) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(item.isFavorite ? String(localized: "Unfavorite") : String(localized: "Favorite"),
                                   systemImage: item.isFavorite ? "heart.slash" : "heart") { model.toggleFavorite(item) }
                        }
                        .onAppear { model.loadMoreIfNeeded(after: item) }
                }
            }
            if model.isLoading { ProgressView().padding() }
        }
        .overlay { status }
        .navigationTitle(folder?.title ?? memory?.title ?? library.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.listing.loadFirst()?.value }
        .task {
            if model.folders.isEmpty, model.media.isEmpty, !model.isLoading { model.listing.loadFirst() }
        }
        .onAppear {
            // Back from a folder, whose Sort or Show may have changed the library's.
            let saved = PhotoPreferences.query(for: library, narrowedBy: query)
            if saved != query { query = saved; model.listing.query = saved }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Slideshow", systemImage: "play.rectangle") { startSlideshow() }
                    .disabled(model.media.isEmpty)
                Button("Shuffle", systemImage: "shuffle") { startShuffle() }
                    .disabled(model.media.isEmpty)
                // Photos already in hand (On This Day) have no order or filter to change.
                if model.listing.source()?.provider.photoSorts.isEmpty != true { optionsMenu }
            }
            if showsAccount { IOSAccountToolbarItem() }
        }
        .fullScreenCover(item: $viewing, onDismiss: {
            if let clip = pendingClip, let playable = clip.playable { pendingClip = nil; actions.play(playable) }
        }, content: { start in
            IOSPhotoViewer(model: start.model, start: start.item, running: start.running) { clip, inShow in
                pendingClip = clip
                resume = inShow ? (start.model, clip) : nil
                resumeArmed = false
                viewing = nil
            }
        })
        .onChange(of: playback.playbackError) { _, error in
            if error != nil { resume = nil; resumeArmed = false }
        }
        .onChange(of: playback.isPresented) { _, presented in
            if presented { resumeArmed = resume != nil } else if resumeArmed { continueSlideshow() }
        }
    }

    /// The photo after the clip the player just closed on, with the show running.
    private func continueSlideshow() {
        guard let (shown, clip) = resume else { return }
        resume = nil
        resumeArmed = false
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            while true {
                let media = shown.media, skipsClips = !PhotoPreferences.playsClips
                guard let index = media.firstIndex(where: { $0.ref == clip.ref }) else { return }
                if let next = PhotoViewerIndex.step(from: index, by: 1, count: media.count, wraps: !shown.listing.hasMore,
                                                    skipping: { skipsClips && media[$0].kind == .clip }) {
                    viewing = Start(model: shown, item: media[next], running: true)
                    return
                }
                guard shown.listing.hasMore, shown.listing.error == nil, let page = shown.listing.loadMore() else { return }
                await page.value
            }
        }
    }

    private func startSlideshow() {
        guard let first = model.media.first else { return }
        resume = nil
        viewing = Start(model: model, item: first, running: true)
    }

    /// The same folder in a random order, in the viewer; the grid keeps its own.
    private func startShuffle() {
        var shuffled = query
        shuffled.shuffled = true
        let listing = PhotoListing(folder: model.listing.folder, query: shuffled, source: model.listing.source)
        let shuffle = PhotoListingModel(listing: listing)
        resume = nil
        guard !shuffling else { return }
        shuffling = true
        Task {
            defer { shuffling = false }
            await listing.loadFirst()?.value
            while shuffle.media.isEmpty, listing.hasMore, listing.error == nil, let page = listing.loadMore() {
                await page.value
            }
            if let first = shuffle.media.first { viewing = Start(model: shuffle, item: first, running: true) }
        }
    }

    private func change(_ edit: (inout PhotoQuery) -> Void) {
        var edited = query
        edit(&edited)
        guard edited != query else { return }
        query = edited
        PhotoPreferences.setQuery(edited, for: library)
        model.listing.query = edited
    }

    private var optionsMenu: some View {
        let sorts = model.listing.source()?.provider.photoSorts ?? [query.sort]
        return Menu {
            Picker("Sort", selection: Binding(get: { query.sort }, set: { sort in
                change { $0.sort = sort; $0.ascending = sort == .name }
            })) {
                ForEach(sorts, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Direction", selection: Binding(get: { query.ascending }, set: { ascending in
                change { $0.ascending = ascending }
            })) {
                if query.sort == .name {
                    Text("A to Z").tag(true)
                    Text("Z to A").tag(false)
                } else {
                    Text("Newest First").tag(false)
                    Text("Oldest First").tag(true)
                }
            }
            .pickerStyle(.inline)
            Picker("Show", selection: Binding(get: { query.show }, set: { show in change { $0.show = show } })) {
                Text("All").tag(PhotoQuery.Show.all)
                Text("Photos").tag(PhotoQuery.Show.photos)
                Text("Videos").tag(PhotoQuery.Show.videos)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort and Show", systemImage: "arrow.up.arrow.down")
        }
    }

    private static func title(_ sort: PhotoQuery.Sort) -> LocalizedStringKey {
        switch sort {
        case .dateTaken: "Date Taken"
        case .dateAdded: "Date Added"
        case .name: "Name"
        }
    }

    @ViewBuilder
    private var status: some View {
        if model.failed, model.folders.isEmpty, model.media.isEmpty {
            ContentUnavailableView {
                Label("Couldn't Load Photos", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Try Again") { model.listing.loadFirst() }
            }
        } else if !model.isLoading, !model.failed, model.folders.isEmpty, model.media.isEmpty {
            ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle")
        }
    }
}

/// A square thumbnail; an album carries its name, a clip a play glyph.
struct IOSPhotoTile: View {
    let item: PhotoItem
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if item.kind == .folder {
                    Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.kind == .folder {
                    Text(verbatim: item.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(.white)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.45))
                }
            }
            .overlay {
                if item.kind == .clip {
                    Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white).shadow(radius: 2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isFavorite {
                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(6)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: item.thumbnail) {
                guard let url = item.thumbnail else { return }
                image = IOSArtworkCache.shared.cachedImage(for: url)
                if image == nil { image = await IOSArtworkCache.shared.image(for: url) }
            }
            .accessibilityLabel(item.title)
    }
}

/// A library's page: the photo grid for a photo library, else the video library view.
struct IOSLibraryPage: View {
    let library: MediaLibrary
    var showsAccount = false

    var body: some View {
        if library.kind == .photos {
            IOSPhotoLibraryView(library: library, showsAccount: showsAccount)
        } else {
            IOSPlexLibraryView(library: library, showsAccount: showsAccount)
        }
    }
}

extension MediaLibrary {
    /// The list and sidebar icon: photo libraries get their own.
    var iosIcon: String { kind == .photos ? "photo.on.rectangle" : icon }
}
