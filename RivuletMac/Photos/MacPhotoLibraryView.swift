// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// One folder level of a photo library: sub-folders, then photos and clips, paged as you scroll.
/// A folder pushes another of these; a photo opens the viewer over the same listing.
struct MacPhotoLibraryView: View {
    let library: MediaLibrary
    let folder: MediaItemRef?
    /// One of the root's memories, opened as a flat grid with no albums.
    let memory: PhotoMemory?
    let title: String
    @Environment(\.macOpen) private var open
    @StateObject private var model: PhotoListingModel
    @State private var query: PhotoQuery
    @State private var viewing: Viewing?
    @State private var shuffling = false

    private struct Viewing {
        let model: PhotoListingModel
        let item: PhotoItem
        var running = false
    }

    init(library: MediaLibrary, folder: MediaItemRef? = nil, memory: PhotoMemory? = nil, title: String) {
        self.library = library
        self.folder = folder
        self.memory = memory
        self.title = title
        let query = PhotoPreferences.query(for: library, narrowedBy: memory?.query ?? .default)
        _query = State(initialValue: query)
        let source = PhotoListing.source(for: library)
        _model = StateObject(wrappedValue: PhotoListingModel(
            listing: PhotoListing(folder: folder, query: query, source: memory?.source(over: source) ?? source)))
    }

    private let columns = [GridItem(.adaptive(minimum: MacMetrics.posterWidth), spacing: MacMetrics.tileGap)]

    var body: some View {
        content
            .navigationTitle(title)
            .macPageRefresh { model.listing.loadFirst() }
            .task { if model.media.isEmpty, model.folders.isEmpty, !model.isLoading { model.listing.loadFirst() } }
            .onAppear {
                // Back from a folder, whose Sort or Show may have changed the library's.
                let saved = PhotoPreferences.query(for: library, narrowedBy: query)
                if saved != query { query = saved; model.listing.query = saved }
            }
            .overlay {
                if let shown = viewing {
                    MacPhotoViewer(model: shown.model, start: shown.item, running: shown.running) { viewing = nil }
                        .transition(.opacity)
                }
            }
            .toolbar {
                if viewing == nil {
                    ToolbarItemGroup {
                        Button("Slideshow", systemImage: "play.rectangle") { startSlideshow() }
                            .disabled(model.media.isEmpty)
                        Button("Shuffle", systemImage: "shuffle") { startShuffle() }
                            .disabled(model.media.isEmpty)
                        // Photos already in hand (On This Day) have no order or filter to change.
                        if model.listing.source()?.provider.photoSorts.isEmpty != true { optionsMenu }
                    }
                }
            }
            .toolbar(viewing == nil ? .automatic : .hidden, for: .windowToolbar)
    }

    private func startSlideshow() {
        guard let first = model.media.first else { return }
        viewing = Viewing(model: model, item: first, running: true)
    }

    /// The same folder in a random order, in the viewer; the grid keeps its own.
    private func startShuffle() {
        var shuffled = query
        shuffled.shuffled = true
        let listing = PhotoListing(folder: model.listing.folder, query: shuffled, source: model.listing.source)
        let shuffle = PhotoListingModel(listing: listing)
        guard !shuffling else { return }
        shuffling = true
        Task {
            defer { shuffling = false }
            await listing.loadFirst()?.value
            while shuffle.media.isEmpty, listing.hasMore, listing.error == nil, let page = listing.loadMore() {
                await page.value
            }
            if let first = shuffle.media.first { viewing = Viewing(model: shuffle, item: first, running: true) }
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
    private var content: some View {
        if model.media.isEmpty, model.folders.isEmpty {
            if model.failed {
                MacErrorView(title: "Couldn't Load Photos", message: String(localized: "The server did not answer.")) {
                    model.listing.loadFirst()
                }
            } else if model.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle")
            }
        } else {
            ScrollView {
                if folder == nil, memory == nil {
                    MacPhotoMemoriesRow(library: library)
                }
                LazyVGrid(columns: columns, spacing: MacMetrics.tileGap) {
                    ForEach(model.folders, id: \.ref) { folderTile($0) }
                    ForEach(model.media, id: \.ref) { mediaTile($0) }
                }
                .padding(MacMetrics.pageMargin)
            }
        }
    }

    private func folderTile(_ item: PhotoItem) -> some View {
        Button { open(.photos(library, folder: item.ref, title: item.title)) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    MacImage(url: item.thumbnail)
                    if item.thumbnail == nil {
                        Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(verbatim: item.title).font(.callout).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .macTileHover()
    }

    private func mediaTile(_ item: PhotoItem) -> some View {
        Button {
            viewing = Viewing(model: model, item: item)
        } label: {
            MacImage(url: item.thumbnail)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if item.kind == .clip {
                        Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if item.isFavorite {
                        Image(systemName: "heart.fill").foregroundStyle(.white).shadow(radius: 2).padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(item.isFavorite ? String(localized: "Unfavorite") : String(localized: "Favorite"),
                   systemImage: item.isFavorite ? "heart.slash" : "heart") { model.toggleFavorite(item) }
        }
        .macTileHover()
        .help(item.title)
        .onAppear { model.loadMoreIfNeeded(after: item) }
    }
}
