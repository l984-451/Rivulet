//
//  PlexSearchView.swift
//  Rivulet
//
//  Search view for Plex libraries with tvOS-style results
//

import SwiftUI

struct PlexSearchView: View {
    @StateObject private var authManager = PlexAuthManager.shared
    @StateObject private var dataStore = PlexDataStore.shared
    @Environment(\.nestedNavigationState) private var nestedNavState

    @State private var query = ""
    @State private var results: [PlexMetadata] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedItem: MediaItem?
    @State private var selectedMusicItem: PlexMetadata?   // music-only routing (artist/album)
    @State private var searchTask: Task<Void, Never>?
    @State private var searchToken = 0
    @State private var lastSubmittedQuery = ""
    @AppStorage("recentSearches") private var recentSearchesData: Data = Data()

    @FocusState private var isSearchFieldFocused: Bool
    @FocusState private var focusedRecentSearch: String?

    private let networkManager = PlexNetworkManager.shared
    private let minQueryLength = 2
    private let debounceIntervalNs: UInt64 = 350_000_000
    private let maxRecentSearches = 10

    private var recentSearches: [String] {
        get {
            (try? JSONDecoder().decode([String].self, from: recentSearchesData)) ?? []
        }
    }

    private func saveRecentSearch(_ query: String) {
        var searches = recentSearches
        // Remove if already exists (to move to front)
        searches.removeAll { $0.lowercased() == query.lowercased() }
        // Add to front
        searches.insert(query, at: 0)
        // Limit to max
        if searches.count > maxRecentSearches {
            searches = Array(searches.prefix(maxRecentSearches))
        }
        recentSearchesData = (try? JSONEncoder().encode(searches)) ?? Data()
    }

    private func removeRecentSearch(_ query: String) {
        var searches = recentSearches
        searches.removeAll { $0 == query }
        recentSearchesData = (try? JSONEncoder().encode(searches)) ?? Data()
    }

    private func clearRecentSearches() {
        recentSearchesData = Data()
    }

    var body: some View {
        NavigationStack {
            if !authManager.isAuthenticated {
                notConnectedView
            } else {
                VStack(spacing: 0) {
                    headerView

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            contentBody
                        }
                        .padding(.bottom, 80)
                    }
                    .scrollClipDisabled()
                }
                .navigationDestination(item: $selectedItem) { item in
                    MediaDetailView(item: item)
                }
                .navigationDestination(item: $selectedMusicItem) { item in
                    switch item.type {
                    case "artist": MusicSearchDetailRouter(plexMeta: item, kind: .artist)
                    case "album": MusicSearchDetailRouter(plexMeta: item, kind: .album)
                    default: EmptyView()
                    }
                }
            }
        }
        .modifier(SearchableModifier(isActive: authManager.isAuthenticated && selectedItem == nil, query: $query))
        .task {
            if authManager.isAuthenticated {
                await dataStore.loadLibrariesIfNeeded()
            }
        }
        .onChange(of: query) { _, newValue in
            scheduleSearch(for: newValue)
        }
        .onChange(of: selectedItem) { _, newValue in
            nestedNavState.isNested = newValue != nil
        }
        .onReceive(nestedNavState.popToRootSubject) { _ in
            // Sidebar tab swap from inside a detail push: clear our
            // nav-stack @State so the push pops to root, unblocking
            // the tab swap. See NestedNavigationState.popToRootSubject.
            selectedItem = nil
            selectedMusicItem = nil
        }
        .onSubmit {
            submitSearch()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 10) {

            if let summary = resultSummary {
                Text(summary)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
        .padding(.top, 16)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))

            TextField("Search your libraries", text: $query)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    submitSearch()
                }

            if !query.isEmpty {
                Button {
                    clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(isSearchFieldFocused ? 0.35 : 0.18), lineWidth: 1)
        )
        .defaultFocus($isSearchFieldFocused, true)
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        if !authManager.isAuthenticated {
            EmptyView()
        } else if trimmedQuery.isEmpty || trimmedQuery.count < minQueryLength {
            searchPromptView
        } else if isAwaitingResults {
            loadingView
        } else if let errorMessage {
            errorView(errorMessage)
        } else if filteredResults.isEmpty {
            noResultsView
        } else {
            resultsView
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 40) {
            ForEach(groupedResults, id: \.title) { group in
                MediaRow(
                    title: group.title,
                    items: group.items,
                    serverURL: serverURL,
                    authToken: authToken,
                    onItemSelected: { item in selectItem(item) }
                )
            }
        }
        .padding(.bottom, 80)
    }

    private var groupedResults: [(title: String, items: [PlexMetadata])] {
        let titleItems = filteredResults.filter { $0.type == "movie" || $0.type == "show" }
        let episodeItems = filteredResults.filter { $0.type == "episode" || $0.type == "season" }
        let musicItems = filteredResults.filter { $0.type == "artist" || $0.type == "album" || $0.type == "track" }
        var groups: [(title: String, items: [PlexMetadata])] = []

        if !titleItems.isEmpty {
            groups.append((title: "Movies & TV", items: titleItems))
        }

        if !episodeItems.isEmpty {
            groups.append((title: "Episodes & Seasons", items: episodeItems))
        }

        if !musicItems.isEmpty {
            groups.append((title: "Music", items: musicItems))
        }

        return groups
    }

    private var filteredResults: [PlexMetadata] {
        let visibleKeys = Set(dataStore.visibleLibraries.map { $0.key })
        let types = Set(["movie", "show", "season", "episode", "artist", "album", "track"])
        var seen = Set<String>()

        return results.filter { item in
            guard let type = item.type, types.contains(type) else { return false }
            guard let key = item.ratingKey else { return false }
            guard !seen.contains(key) else { return false }
            seen.insert(key)

            // Filter to only pinned/visible libraries
            if !visibleKeys.isEmpty {
                if let sectionKey = item.librarySectionKey {
                    return visibleKeys.contains(sectionKey)
                }
                if let sectionId = item.librarySectionID {
                    return visibleKeys.contains(String(sectionId))
                }
            }

            return true
        }
    }

    private var resultSummary: String? {
        guard trimmedQuery.count >= minQueryLength else { return nil }
        if isAwaitingResults || errorMessage != nil {
            return nil
        }
        return "\(filteredResults.count) result\(filteredResults.count == 1 ? "" : "s")"
    }

    private var isAwaitingResults: Bool {
        guard trimmedQuery.count >= minQueryLength else { return false }
        return isLoading || lastSubmittedQuery != trimmedQuery
    }

    // MARK: - State Views

    private var searchPromptView: some View {
        VStack(spacing: 32) {
            // Main prompt
            VStack(spacing: 16) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)

                Text("Search Your Libraries")
                    .font(.title2)
                    .fontWeight(.medium)
            }

            // Recent searches
            if !recentSearches.isEmpty {
                recentSearchesView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recentSearchesView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header (non-focusable label + Clear button at end)
            Text("Recent")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(1)
                .padding(.horizontal, 4)

            // Horizontal scroll for tvOS - Clear first, then searches
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ClearRecentSearchesButton {
                        clearRecentSearches()
                    }

                    ForEach(recentSearches, id: \.self) { search in
                        RecentSearchButton(text: search) {
                            query = search
                            submitSearch()
                        }
                        .focused($focusedRecentSearch, equals: search)
                    }
                }
                .padding(.horizontal, 8)   // Room for scale effect on edges
                .padding(.vertical, 12)    // Room for scale effect top/bottom
            }
            .scrollClipDisabled()  // Allow scale overflow
            .defaultFocus($focusedRecentSearch, recentSearches.first)
        }
        .frame(maxWidth: 800)
        .padding(.top, 32)
    }

    private var loadingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Searching")
                .font(.title3)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            Text("Search Failed")
                .font(.title2)
                .fontWeight(.medium)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            Button {
                submitSearch()
            } label: {
                Text("Try Again")
                    .fontWeight(.medium)
            }
            .buttonStyle(AppStoreButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 24) {
            Image(systemName: "sparkles")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            Text("No Results")
                .font(.title2)
                .fontWeight(.medium)

            Text("Try a different title or check your spelling.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notConnectedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "server.rack")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            Text("Not Connected")
                .font(.title2)
                .fontWeight(.medium)

            Text("Connect to your Plex server in Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Navigation Helpers

    /// Route PlexMetadata to the correct navigation target.
    private func selectItem(_ meta: PlexMetadata) {
        switch meta.type {
        case "artist", "album":
            selectedMusicItem = meta
        case "track":
            playMusicTrack(meta)
        default:
            guard let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else { return }
            let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
            selectedItem = PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: token)
        }
    }

    // MARK: - Music Helpers

    private func playMusicTrack(_ plexMeta: PlexMetadata) {
        guard let provider = MusicProviderRegistry.shared.primaryProvider,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        let track = PlexMusicMapper.track(
            plexMeta,
            providerID: provider.id,
            serverURL: serverURL,
            authToken: token
        )
        MusicQueue.shared.playNow(track: track)
    }

    // MARK: - Search Helpers

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var serverURL: String {
        authManager.selectedServerURL ?? ""
    }

    private var authToken: String {
        authManager.selectedServerToken ?? ""
    }

    private func scheduleSearch(for rawQuery: String) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count >= minQueryLength else {
            searchTask?.cancel()
            searchToken += 1
            isLoading = false
            errorMessage = nil
            results = []
            lastSubmittedQuery = ""
            return
        }

        searchTask?.cancel()
        searchToken += 1
        let currentToken = searchToken

        searchTask = Task {
            try? await Task.sleep(nanoseconds: debounceIntervalNs)
            if Task.isCancelled {
                return
            }
            await performSearch(query: trimmed, token: currentToken)
        }
    }

    private func submitSearch() {
        let trimmed = trimmedQuery
        guard trimmed.count >= minQueryLength else { return }
        if trimmed == lastSubmittedQuery && !results.isEmpty {
            return
        }

        searchTask?.cancel()
        searchToken += 1
        let currentToken = searchToken

        Task {
            await performSearch(query: trimmed, token: currentToken)
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        searchToken += 1
        query = ""
        results = []
        errorMessage = nil
        isLoading = false
        lastSubmittedQuery = ""
    }

    private func performSearch(query: String, token: Int) async {
        guard let serverURL = authManager.selectedServerURL,
              let authToken = authManager.selectedServerToken else {
            return
        }

        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }

        do {
            let items = try await networkManager.search(
                serverURL: serverURL,
                authToken: authToken,
                query: query,
                start: 0,
                size: 80
            )

            await MainActor.run {
                guard token == searchToken else { return }
                results = items
                isLoading = false
                errorMessage = nil
                lastSubmittedQuery = query
                // Save to recent searches if we got results
                if !items.isEmpty {
                    saveRecentSearch(query)
                }
            }
        } catch {
            await MainActor.run {
                guard token == searchToken else { return }
                results = []
                isLoading = false
                errorMessage = error.localizedDescription
                lastSubmittedQuery = query
            }
        }
    }
}

private struct SearchableModifier: ViewModifier {
    let isActive: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if isActive {
            content.searchable(text: $query, prompt: "Search your libraries")
        } else {
            content
        }
    }
}

// MARK: - Recent Search Button

private struct RecentSearchButton: View {
    let text: String
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 22, weight: .medium))
                Text(text)
                    .font(.system(size: 26, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(SettingsButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

private struct ClearRecentSearchesButton: View {
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .medium))
                Text("Clear")
                    .font(.system(size: 24, weight: .medium))
            }
            .foregroundStyle(.white.opacity(isFocused ? 1.0 : 0.6))
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(SettingsButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}


#Preview {
    PlexSearchView()
}
