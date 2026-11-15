// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MacPhotoMapView.swift
//  Rivulet
//
//  A library's located photos on a map, grouped by the visible span. A photo
//  opens the viewer on it; a group opens a grid of its members.
//

import MapKit
import SwiftUI

struct MacPhotoMapView: View {
    let provider: any PhotoProvider
    let library: MediaLibrary
    @State private var photos: [PhotoItem] = []
    @State private var position: MapCameraPosition = .automatic
    @State private var span = 10.0
    @State private var group: PhotoMemory?
    @State private var viewing: Viewing?

    private struct Viewing {
        let model: PhotoListingModel
        let item: PhotoItem
    }

    var body: some View {
        Map(position: $position) {
            ForEach(PhotoMapLoader.clusters(photos, cell: span / 8), id: \.first!.ref) { members in
                if let first = members.first, let point = first.coordinate {
                    Annotation(String(), coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) {
                        Button { open(members) } label: { MacPhotoMapPin(members: members) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .onMapCameraChange(frequency: .onEnd) { span = max($0.region.span.latitudeDelta, 0.0005) }
        .navigationTitle(library.title)
        .task {
            await PhotoMapLoader(provider: provider, library: library).load { photos += $0 }
            position = .automatic
        }
        .navigationDestination(item: $group) { MacPhotoLibraryView(library: library, memory: $0, title: library.title) }
        .overlay {
            if let shown = viewing {
                MacPhotoViewer(model: shown.model, start: shown.item) { viewing = nil }
                    .transition(.opacity)
            }
        }
        .toolbar(viewing == nil ? .automatic : .hidden, for: .windowToolbar)
    }

    private func open(_ members: [PhotoItem]) {
        let items = members.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let memory = PhotoMemory(kind: .map, title: library.title, cover: items.first, content: .items(items))
        guard items.count == 1, let item = items.first else { group = memory; return }
        let listing = PhotoListing(folder: nil, source: memory.source(over: PhotoListing.source(for: library)))
        let model = PhotoListingModel(listing: listing)
        listing.loadFirst()
        viewing = Viewing(model: model, item: item)
    }
}

/// The newest member's thumbnail, with a count over a group.
private struct MacPhotoMapPin: View {
    let members: [PhotoItem]
    @State private var image: NSImage?

    private var cover: PhotoItem {
        members.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) } ?? members[0]
    }

    var body: some View {
        Color.gray
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if members.count > 1 {
                    Text(verbatim: "\(members.count)")
                        .font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.blue))
                        .offset(x: 8, y: -8)
                }
            }
            .shadow(radius: 2)
            .task(id: cover.thumbnail) {
                guard let url = cover.thumbnail else { return }
                image = MacArtworkCache.shared.cachedImage(for: url)
                if image == nil { image = await MacArtworkCache.shared.image(for: url) }
            }
    }
}
