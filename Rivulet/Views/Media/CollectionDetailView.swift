//
//  CollectionDetailView.swift
//  Rivulet
//
//  Items in a single Plex collection, presented as a poster grid.
//  Pushed from the Collections mode of `PlexLibraryView`. Item taps go
//  through the same `selectedItem`/`MediaDetailView` path as anywhere
//  else.
//

import SwiftUI


struct CollectionDetailView: View {
    let collection: PlexMetadata

    @Environment(\.uiScale) private var scale
    @Environment(MediaProviderRegistry.self) private var providerRegistry
    @StateObject private var authManager = PlexAuthManager.shared
    private let networkManager = PlexNetworkManager.shared

    @State private var items: [PlexMetadata] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var selectedItem: MediaItem?
    @FocusState private var focusedItemRk: String?

    private var columns: [GridItem] {
        let minWidth = ScaledDimensions.gridMinWidth * scale
        let maxWidth = ScaledDimensions.gridMaxWidth * scale
        return [GridItem(.adaptive(minimum: minWidth, maximum: maxWidth), spacing: ScaledDimensions.gridSpacing)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                gridContent
            }
        }
        .task(id: collection.ratingKey) {
            await loadItems()
        }
        .navigationDestination(item: $selectedItem) { item in
            MediaDetailView(item: item)
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(collection.title ?? "Collection")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)

            if let count = collection.childCount {
                Text("\(count) item\(count == 1 ? "" : "s")")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }

            if let summary = collection.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
        .padding(.top, 60)
        .padding(.bottom, 28)
    }

    @ViewBuilder
    private var gridContent: some View {
        if isLoading && items.isEmpty {
            ProgressView()
                .progressViewStyle(.circular)
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if let error {
            errorView(error)
        } else if items.isEmpty {
            Text("No items in this collection.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            LazyVGrid(columns: columns, spacing: 40) {
                ForEach(items, id: \.ratingKey) { item in
                    gridItem(item)
                }
            }
            .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
            .padding(.vertical, 28)
        }
    }

    @ViewBuilder
    private func gridItem(_ item: PlexMetadata) -> some View {
        let id = item.ratingKey ?? ""
        let isFocused = focusedItemRk == id
        Button {
            selectedItem = mediaItem(from: item)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                EquatableView(content: MediaPosterCard(
                    item: item,
                    serverURL: authManager.selectedServerURL ?? "",
                    authToken: authManager.selectedServerToken ?? ""
                ))
                .hoverEffectDisabled()
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title ?? "")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    if let year = item.year, item.type == "movie" {
                        Text(verbatim: "\(year)")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .frame(height: 40, alignment: .top)
            }
            .scaleEffect(isFocused ? 1.10 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFocused)
        }
        .buttonStyle(CardButtonStyle())
        .focused($focusedItemRk, equals: id)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Unable to Load Collection")
                .font(.title3)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            Button("Try Again") {
                Task { await loadItems() }
            }
            .buttonStyle(AppStoreButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func loadItems() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = collection.ratingKey else {
            error = "Missing connection or collection id"
            return
        }

        isLoading = true
        error = nil

        do {
            let fetched = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            items = fetched
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    private func mediaItem(from meta: PlexMetadata) -> MediaItem {
        // The real Plex provider id is "plex:<machineId>" (see PlexProvider
        // init); without it MediaDetailView can't resolve the provider via
        // the registry, so fullDetail() never runs and the page degrades
        // to a stub (no trailer/audio/subtitle controls, summary instead of
        // tagline). Pull the canonical id from the registry.
        let providerID = providerRegistry.primaryProvider?.id ?? "plex"
        return PlexMediaMapper.item(
            meta,
            providerID: providerID,
            serverURL: authManager.selectedServerURL ?? "",
            authToken: authManager.selectedServerToken ?? ""
        )
    }
}
