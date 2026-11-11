// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// The library root's memories, as a sideways row of large cards. Loads once `ready` (the grid's
/// first page is in), and shows nothing until it has a memory.
struct IOSPhotoMemoriesRow: View {
    let library: MediaLibrary
    let ready: Bool
    @State private var memories: [PhotoMemory] = []
    @State private var loaded = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if !memories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(memories, id: \.self) { memory in
                            NavigationLink {
                                if memory.kind == .map, let (provider, library) = PhotoListing.source(for: library)() {
                                    IOSPhotoMapView(provider: provider, library: library)
                                } else {
                                    IOSPhotoLibraryView(library: library, memory: memory).iosPlexActionHost()
                                }
                            } label: {
                                card(memory)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .padding(.vertical, 12)
            }
        }
        .task(id: ready) {
            guard ready, !loaded, let (provider, library) = PhotoListing.source(for: library)() else { return }
            loaded = true
            let found = await PhotoMemories.load(provider: provider, library: library, today: .now)
            guard !Task.isCancelled else { loaded = false; return }
            memories = found
        }
    }

    /// About two-thirds of the width on iPhone, 420 pt on iPad.
    private func card(_ memory: PhotoMemory) -> some View {
        IOSPhotoMemoryArt(cover: memory.cover)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                Text(verbatim: memory.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .containerRelativeFrame(.horizontal) { width, _ in
                sizeClass == .regular ? 420 : (width * 2 / 3).rounded()
            }
            .contentShape(Rectangle())
    }
}

/// A memory's cover filled: the thumbnail first, then the full photo.
private struct IOSPhotoMemoryArt: View {
    let cover: PhotoItem?
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if cover == nil {
                    Image(systemName: "map.fill").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: cover?.ref) {
                for url in [cover?.thumbnail, cover?.full].compactMap({ $0 }) {
                    let loaded = await IOSArtworkCache.shared.image(for: url)
                    guard !Task.isCancelled else { return }
                    if let loaded { image = loaded }
                }
            }
    }
}
