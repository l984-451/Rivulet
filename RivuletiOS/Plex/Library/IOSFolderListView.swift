// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// One folder level of a library as it sits on disk: folders first, then files, paged.
/// A folder pushes another of these; a video plays; a photo opens the viewer.
struct IOSFolderListView: View {
    let library: MediaLibrary
    let folder: MediaItemRef?
    let title: String?
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.plexActions) private var actions
    @StateObject private var model: FolderListingModel
    @State private var viewing: Viewing?
    @State private var pendingClip: PhotoItem?

    private struct Viewing: Identifiable {
        let model: PhotoListingModel
        let item: PhotoItem
        var id: MediaItemRef { item.ref }
    }

    init(library: MediaLibrary, folder: MediaItemRef? = nil, title: String? = nil) {
        self.library = library
        self.folder = folder
        self.title = title
        _model = StateObject(wrappedValue: FolderListingModel(
            listing: FolderListing(folder: folder, source: FolderListing.source(for: library))))
    }

    var body: some View {
        content
            .navigationTitle(title ?? browse.labels.title(library.title, providerID: library.providerID))
            .task { if model.entries.isEmpty, !model.isLoading { model.listing.loadFirst() } }
            .onChange(of: browse.watchStateRevision) { model.listing.refresh() }
            .toolbar {
                // Shuffle at the root, as on the other pages.
                if folder == nil, library.canShuffle {
                    ToolbarItem(placement: .topBarTrailing) {
                        if actions.preparingID == IOSPlexActions.shuffleID(providerID: library.providerID, itemID: library.id) {
                            ProgressView()
                        } else {
                            Button("Shuffle", systemImage: "shuffle") { actions.shuffleLibrary(library, false) }
                        }
                    }
                }
            }
            .fullScreenCover(item: $viewing, onDismiss: {
                if let playable = pendingClip?.playable { pendingClip = nil; actions.play(playable) }
            }, content: { shown in
                IOSPhotoViewer(model: shown.model, start: shown.item) { clip, _ in
                    pendingClip = clip
                    viewing = nil
                }
            })
    }

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty, model.failed {
            IOSPlexErrorView(title: "Couldn't Load Folder", message: model.listing.error?.localizedDescription ?? "",
                             offersDownloads: true) {
                await model.listing.loadFirst()?.value
            }
        } else if model.entries.isEmpty, model.isLoading || model.listing.hasMore {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty {
            ScrollView {
                ContentUnavailableView("Empty Folder", systemImage: "folder").containerRelativeFrame([.horizontal, .vertical])
            }
            .refreshable { await model.listing.loadFirst()?.value }
        } else {
            List(model.entries, id: \.id) { entry in
                row(entry).onAppear { model.loadMoreIfNeeded(after: entry) }
            }
            .listStyle(.plain)
            .refreshable { await model.listing.refresh()?.value }
        }
    }

    @ViewBuilder
    private func row(_ entry: FolderEntry) -> some View {
        switch entry.content {
        case .folder(let ref, _):
            NavigationLink {
                IOSFolderListView(library: library, folder: ref, title: entry.title).iosPlexActionHost()
            } label: {
                label(entry, detail: "") { Image(systemName: "folder.fill").font(.title2).foregroundStyle(.secondary) }
            }
        case .video(let item):
            Button { actions.play(item) } label: {
                label(entry, detail: FolderRowDetail.text(for: entry)) {
                    IOSItemArtwork(item: item, kind: .thumb, width: Self.thumbWidth, aspectRatio: 16 / 9)
                }
            }
            .plexContextMenu(item, showsDetails: true)
        case .photo(let photo):
            Button { open(photo) } label: {
                label(entry, detail: "") { IOSPlexImage(url: photo.thumbnail) }
            }
        }
    }

    private static let thumbWidth: CGFloat = 96

    private func label(_ entry: FolderEntry, detail: String, @ViewBuilder thumb: () -> some View) -> some View {
        HStack(spacing: 12) {
            Color.secondary.opacity(0.15)
                .overlay { thumb() }
                .frame(width: Self.thumbWidth, height: Self.thumbWidth * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(verbatim: entry.title).lineLimit(2).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(verbatim: detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func open(_ photo: PhotoItem) {
        Task {
            guard let (photos, index) = await model.listing.photos(openingAt: photo) else { return }
            viewing = Viewing(model: PhotoListingModel(listing: photos), item: photos.media[index])
        }
    }
}
