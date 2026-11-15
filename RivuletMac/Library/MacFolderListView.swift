// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// One folder level of a library as it sits on disk: folders first, then files, paged.
/// A folder pushes another of these; a video plays; a photo opens the viewer.
/// Parity source: RivuletiOS/Plex/Library/IOSFolderListView.swift.
struct MacFolderListView: View {
    let library: MediaLibrary
    let folder: MediaItemRef?
    let title: String?
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.macActions) private var actions
    @Environment(\.macOpen) private var open
    @StateObject private var model: FolderListingModel
    @State private var viewing: Viewing?

    private struct Viewing {
        let model: PhotoListingModel
        let item: PhotoItem
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
            .macPageRefresh { model.listing.refresh() }
            .task { if model.entries.isEmpty, !model.isLoading { model.listing.loadFirst() } }
            .onChange(of: browse.watchStateRevision) { model.listing.refresh() }
            .overlay {
                if let shown = viewing {
                    MacPhotoViewer(model: shown.model, start: shown.item) { viewing = nil }
                        .transition(.opacity)
                }
            }
            .toolbar {
                // Shuffle at the root, as on the other pages.
                if viewing == nil, folder == nil, library.canShuffle {
                    ToolbarItem {
                        if actions.preparingID == MacActions.shuffleID(providerID: library.providerID, itemID: library.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Shuffle", systemImage: "shuffle") { actions.shuffleLibrary(library, false) }
                        }
                    }
                }
            }
            .toolbar(viewing == nil ? .automatic : .hidden, for: .windowToolbar)
    }

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty, model.failed {
            MacErrorView(title: "Couldn't Load Folder", message: model.listing.error?.localizedDescription ?? "") {
                await model.listing.loadFirst()?.value
            }
        } else if model.entries.isEmpty, model.isLoading || model.listing.hasMore {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty {
            ContentUnavailableView("Empty Folder", systemImage: "folder")
        } else {
            List(model.entries, id: \.id) { entry in
                row(entry).onAppear { model.loadMoreIfNeeded(after: entry) }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: FolderEntry) -> some View {
        switch entry.content {
        case .folder(let ref, _):
            Button { open(.folder(library, folder: ref, title: entry.title)) } label: {
                label(entry, detail: "›") { Image(systemName: "folder.fill").font(.title2).foregroundStyle(.secondary) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: FolderRowDetail.spoken(for: entry)))
        case .video(let item):
            Button { actions.play(item) } label: {
                label(entry, detail: FolderRowDetail.text(for: entry)) {
                    MacItemArtwork(item: item, kind: .thumb, width: Self.thumbWidth, aspectRatio: 16 / 9)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: FolderRowDetail.spoken(for: entry)))
            .macContextMenu(item, showsDetails: true)
        case .photo(let photo):
            Button { show(photo) } label: {
                label(entry, detail: "") { MacImage(url: photo.thumbnail) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: FolderRowDetail.spoken(for: entry)))
        }
    }

    private static let thumbWidth: CGFloat = 96

    private func label(_ entry: FolderEntry, detail: String, @ViewBuilder thumb: () -> some View) -> some View {
        HStack(spacing: 12) {
            Color.secondary.opacity(0.15)
                .overlay { thumb() }
                .frame(width: Self.thumbWidth, height: Self.thumbWidth * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(verbatim: entry.title).lineLimit(2)
            Spacer(minLength: 8)
            Text(verbatim: detail).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func show(_ photo: PhotoItem) {
        Task {
            guard let (photos, index) = await model.listing.photos(openingAt: photo) else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                viewing = Viewing(model: PhotoListingModel(listing: photos), item: photos.media[index])
            }
        }
    }
}
