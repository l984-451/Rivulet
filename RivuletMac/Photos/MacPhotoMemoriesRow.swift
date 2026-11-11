// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// The library root's memories, as a sideways row of 420 pt cards. Shows nothing until it has a memory.
/// Its view appears only once the grid has content, so it never delays the first page.
struct MacPhotoMemoriesRow: View {
    let library: MediaLibrary
    @Environment(\.macOpen) private var open
    @State private var memories: [PhotoMemory] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if !memories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: MacMetrics.tileGap) {
                        ForEach(memories, id: \.self) { memory in
                            Button { open(.photoMemory(library, memory)) } label: { card(memory) }
                                .buttonStyle(.plain)
                                .macTileHover()
                        }
                    }
                    .padding(.horizontal, MacMetrics.pageMargin)
                }
                .padding(.top, MacMetrics.pageMargin)
            }
        }
        .task {
            guard !loaded, let (provider, library) = PhotoListing.source(for: library)() else { return }
            loaded = true
            let found = await PhotoMemories.load(provider: provider, library: library, today: .now)
            guard !Task.isCancelled else { loaded = false; return }
            memories = found
        }
    }

    private func card(_ memory: PhotoMemory) -> some View {
        MacImage(url: memory.cover?.full ?? memory.cover?.thumbnail)
            .frame(width: 420, height: 236)
            .overlay {
                if memory.cover == nil { Image(systemName: "map.fill").font(.largeTitle).foregroundStyle(.secondary) }
            }
            .overlay(alignment: .bottomLeading) {
                Text(verbatim: memory.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
    }
}
