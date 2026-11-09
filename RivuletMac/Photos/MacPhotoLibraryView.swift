// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// One folder level of a photo library: sub-folders, then photos and clips, paged as you scroll.
/// A folder pushes another of these; a photo opens the viewer over the same listing.
struct MacPhotoLibraryView: View {
    let library: MediaLibrary
    let folder: MediaItemRef?
    let title: String
    @Environment(\.macOpen) private var open
    @StateObject private var model: PhotoListingModel
    @State private var viewing: PhotoItem?

    init(library: MediaLibrary, folder: MediaItemRef? = nil, title: String) {
        self.library = library
        self.folder = folder
        self.title = title
        _model = StateObject(wrappedValue: PhotoListingModel(
            listing: PhotoListing(folder: folder, source: PhotoListing.source(for: library))))
    }

    private let columns = [GridItem(.adaptive(minimum: MacMetrics.posterWidth), spacing: MacMetrics.tileGap)]

    var body: some View {
        content
            .navigationTitle(title)
            .macPageRefresh { model.listing.loadFirst() }
            .task { if model.media.isEmpty, model.folders.isEmpty, !model.isLoading { model.listing.loadFirst() } }
            .overlay {
                if let item = viewing {
                    MacPhotoViewer(model: model, start: item) { viewing = nil }
                        .transition(.opacity)
                }
            }
            .toolbar(viewing == nil ? .automatic : .hidden, for: .windowToolbar)
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
            viewing = item
        } label: {
            MacImage(url: item.thumbnail)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if item.kind == .clip {
                        Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .macTileHover()
        .help(item.title)
        .onAppear { model.loadMoreIfNeeded(after: item) }
    }
}
