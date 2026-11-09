// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// A photo library's root or one folder of it: albums first, then photos and clips, paged.
struct IOSPhotoLibraryView: View {
    let library: MediaLibrary
    var folder: PhotoItem?
    var showsAccount = false
    /// Played once the viewer has finished dismissing.
    @State private var pendingClip: MediaItem?
    @StateObject private var model: PhotoListingModel
    @State private var viewing: Start?
    @Environment(\.plexActions) private var actions

    private struct Start: Identifiable {
        let item: PhotoItem
        var id: MediaItemRef { item.ref }
    }

    init(library: MediaLibrary, folder: PhotoItem? = nil, showsAccount: Bool = false) {
        self.library = library
        self.folder = folder
        self.showsAccount = showsAccount
        _model = StateObject(wrappedValue: PhotoListingModel(
            listing: PhotoListing(folder: folder?.ref, source: PhotoListing.source(for: library))))
    }

    var body: some View {
        ScrollView {
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
                    Button { viewing = Start(item: item) } label: { IOSPhotoTile(item: item) }
                        .buttonStyle(.plain)
                        .onAppear { model.loadMoreIfNeeded(after: item) }
                }
            }
            if model.isLoading { ProgressView().padding() }
        }
        .overlay { status }
        .navigationTitle(folder?.title ?? library.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.listing.loadFirst()?.value }
        .task {
            if model.folders.isEmpty, model.media.isEmpty, !model.isLoading { model.listing.loadFirst() }
        }
        .toolbar { if showsAccount { IOSAccountToolbarItem() } }
        .fullScreenCover(item: $viewing, onDismiss: {
            if let clip = pendingClip { pendingClip = nil; actions.play(clip) }
        }, content: { start in
            IOSPhotoViewer(model: model, start: start.item) { clip in
                pendingClip = clip
                viewing = nil
            }
        })
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
