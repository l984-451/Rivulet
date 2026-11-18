// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CarPlay
import Combine
import CoreMedia

/// The app on a CarPlay screen or Apple HomeView: Home and Library as lists, a library's titles,
/// a show's seasons, search, and playback as video where the car allows it. iOS draws the
/// templates; this only fills them. The deepest stack is tab bar, library, show, season: four of
/// the five the system allows.
@available(iOS 27.0, *)
@objc(CarPlaySceneDelegate)
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPSearchTemplateDelegate {
    /// A list and how to rebuild its rows, so one pass keeps every open page current.
    private struct Screen {
        let template: CPListTemplate
        let load: () async throws -> [CPListSection]
    }

    /// Only the first page of a library: a car list is short, and a page of art is 100 downloads.
    private static let libraryPageSize = 100

    private var interfaceController: CPInterfaceController?
    private var roots: [Screen] = []
    private var pushed: [Screen] = []
    private var observation: AnyCancellable?
    private var failure: AnyCancellable?
    private var searching: Task<[CPListItem], Never>?
    private var searchResults: [CPListItem] = []
    /// CarPlay can launch the app with no window, so the first load runs after the scene connects.
    private var isStarting = true

    private var browse: BrowseStore? { IOSPlaybackController.shared.plex?.browse }
    /// A locked profile's titles stay off this screen, as they do on the phone.
    private var isLocked: Bool { PlexUserProfileManager.shared.needsProfileSelection }

    // MARK: - Scene

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        DiagLog.notice(.launch, "CarPlay scene connected")
        self.interfaceController = interfaceController
        let home = makeScreen(title: String(localized: "Home")) { self.homeSections() }
        home.template.tabImage = UIImage(systemName: "house")
        let library = makeScreen(title: String(localized: "Library")) { self.librarySections() }
        library.template.tabImage = UIImage(systemName: "rectangle.stack")
        roots = [home, library]
        setRoot(CPTabBarTemplate(templates: roots.map(\.template)))
        // The phone's alert may have no window to show in.
        failure = IOSPlaybackController.shared.$playbackError.compactMap { $0 }
            .sink { [weak self] message in Task { await self?.alert(message) } }
        guard let plex = IOSPlaybackController.shared.plex else {
            isStarting = false
            return
        }
        // Playback or a sync changes what is listed; rows are rebuilt in place, never re-rooted.
        observation = plex.browse.objectWillChange.merge(with: PlexUserProfileManager.shared.objectWillChange)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] in Task { await self?.reload() } }
        Task {
            await plex.verifyConnection()
            if plex.browse.continueWatching.isEmpty { await plex.refresh() }
            isStarting = false
            await reload()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        observation = nil
        failure = nil
        searching?.cancel()
        searchResults = []
        self.interfaceController = nil
        roots = []
        pushed = []
    }

    /// A failed start, as the phone words it. OK here answers the phone's alert too.
    private func alert(_ message: String) async {
        let dismiss = CPAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
            IOSPlaybackController.shared.playbackError = nil
            self?.interfaceController?.dismissTemplate(animated: true) { _, _ in }
        }
        let alert = CPAlertTemplate(titleVariants: [message, String(localized: "Couldn't Play")], actions: [dismiss])
        _ = try? await interfaceController?.presentTemplate(alert, animated: true)
    }

    /// A completion block is required: CarPlay throws when a presentation fails without one.
    private func setRoot(_ tabs: CPTabBarTemplate) {
        Task {
            do { _ = try await interfaceController?.setRootTemplate(tabs, animated: false) } catch {
                DiagLog.error(.launch, "CarPlay root failed: \(error.localizedDescription)")
            }
            await reload()
        }
    }

    // MARK: - Screens

    private func makeScreen(title: String, header: CPListTemplateDetailsHeader? = nil,
                            load: @escaping () async throws -> [CPListSection]) -> Screen {
        let list = header.map { CPListTemplate(title: title, listHeader: $0, sections: [], assistantCellConfiguration: nil) }
            ?? CPListTemplate(title: title, sections: [])
        list.showsSpinnerWhileEmpty = true
        return Screen(template: list, load: load)
    }

    /// Pushes at once with a spinner, then fills; the tapped row spins until the rows are in.
    private func push(title: String, header: CPListTemplateDetailsHeader? = nil,
                      load: @escaping () async throws -> [CPListSection]) async {
        guard let interfaceController, !isLocked else { return }
        let screen = makeScreen(title: title, header: header, load: load)
        do {
            _ = try await interfaceController.pushTemplate(screen.template, animated: true)
        } catch {
            DiagLog.error(.launch, "CarPlay push failed: \(error.localizedDescription)")
            return
        }
        pushed.append(screen)
        await fill(screen)
    }

    private func fill(_ screen: Screen) async {
        var sections: [CPListSection]? = []
        if !isLocked { sections = try? await screen.load() }
        // A failed refresh keeps the rows already shown.
        if let sections { screen.template.updateSections(sections) }
        // The empty text draws beside the spinner, so it waits until loading ends.
        let loading = isStarting || browse?.isLoadingContent == true
        screen.template.showsSpinnerWhileEmpty = loading
        screen.template.emptyViewTitleVariants = loading ? [] : [emptyTitle(failed: sections == nil)]
    }

    /// Why a list is empty. Signing in and choosing a profile happen on the phone.
    private func emptyTitle(failed: Bool) -> String {
        if isLocked { return String(localized: "Choose a Profile on iPhone") }
        if browse?.hasServers != true { return String(localized: "Sign In on iPhone") }
        return failed ? String(localized: "Couldn't Load") : String(localized: "No Items")
    }

    /// Rebuilds every open list from the library, leaving the stack where the driver put it.
    private func reload() async {
        guard let interfaceController else { return }
        if isLocked { _ = try? await interfaceController.popToRootTemplate(animated: false) }
        if !pushed.isEmpty {
            let open = interfaceController.templates
            pushed.removeAll { screen in !open.contains { $0 === screen.template } }
        }
        for screen in roots + pushed { await fill(screen) }
    }

    // MARK: - Home and Library

    /// Home's rows as the phone arranges them (hidden and ordered by the user), Continue Watching first by default.
    private func homeSections() -> [CPListSection] {
        guard let browse else { return [] }
        var budget = CPListTemplate.maximumItemCount
        var sections: [CPListSection] = []
        for hub in browse.homeRows {
            guard sections.count < CPListTemplate.maximumSectionCount, budget > 0 else { break }
            let items = hub.items.filter(isListable).prefix(min(HomeFeed.railLimit, budget))
            guard !items.isEmpty else { continue }
            budget -= items.count
            sections.append(CPListSection(items: items.map(row),
                                          header: browse.labels.title(hub.title, providerID: hub.providerID),
                                          sectionIndexTitle: nil))
        }
        return sections
    }

    /// Search, then the video libraries the phone's Library list shows. `libraries` never holds photo or music libraries.
    private func librarySections() -> [CPListSection] {
        guard let browse else { return [] }
        let rows = browse.sidebarLibraries.sidebarOrder(servers: browse.providerOrder).map { library in
            let title = browse.labels.title(library.title, providerID: library.providerID)
            let row = CPListItem(text: title, detailText: nil, image: UIImage(systemName: library.iosIcon),
                                 accessoryImage: nil, accessoryType: .disclosureIndicator)
            row.handler = { [weak self] _, done in Task { await self?.openLibrary(library, title: title); done() } }
            return row
        }
        guard !rows.isEmpty else { return [] }
        // A row, not a tab: a tab holds a list or a grid, and the search template is pushed.
        let search = CPListItem(text: String(localized: "Search"), detailText: nil, image: UIImage(systemName: "magnifyingglass"),
                                accessoryImage: nil, accessoryType: .disclosureIndicator)
        search.handler = { [weak self] _, done in Task { await self?.openSearch(); done() } }
        return [CPListSection(items: [search] + rows)]
    }

    // MARK: - Library and show pages

    private func openLibrary(_ library: MediaLibrary, title: String) async {
        await push(title: title) { try await self.titles(in: library) }
    }

    /// The phone's Browse grid for this library: its sort and filter, first page.
    private func titles(in library: MediaLibrary) async throws -> [CPListSection] {
        guard let browse else { return [] }
        guard let provider = browse.provider(for: library.providerID) else { throw MediaProviderError.unreachable }
        let sort = UserDefaults.standard.string(forKey: LibrarySortOption.iosKey(library.settingKey))
            .flatMap(LibrarySortOption.init(rawValue:)) ?? .titleAsc
        let limit = min(CPListTemplate.maximumItemCount, Self.libraryPageSize)
        let page = try await provider.items(in: library, sort: sort.seamSort, filter: .remembered(library.settingKey),
                                            page: Page(offset: 0, limit: limit))
        return [CPListSection(items: page.items.filter(isListable).map(row))]
    }

    private func openShow(_ show: MediaItem) async {
        let header = await header(for: show)
        await push(title: show.displayTitle, header: header) { try await self.seasons(of: show) }
    }

    /// A section per season. A show too long for one list (some cars allow 12 rows) gets a row per season.
    private func seasons(of show: MediaItem) async throws -> [CPListSection] {
        let seasons = try await episodesBySeason(of: show)
        let fits = seasons.reduce(0) { $0 + $1.count } <= CPListTemplate.maximumItemCount
            && seasons.count <= CPListTemplate.maximumSectionCount
        if fits || seasons.count == 1 {
            return seasons.map { CPListSection(items: $0.map(episodeRow), header: seasonName($0), sectionIndexTitle: nil) }
        }
        let rows = seasons.map { season in
            let name = seasonName(season) ?? show.displayTitle
            let number = season[0].seasonNumber
            let row = CPListItem(text: name, detailText: nil, image: nil, accessoryImage: nil, accessoryType: .disclosureIndicator)
            row.handler = { [weak self] _, done in Task { await self?.openSeason(number, named: name, of: show); done() } }
            return row
        }
        return [CPListSection(items: rows)]
    }

    private func openSeason(_ number: Int?, named name: String, of show: MediaItem) async {
        await push(title: name) {
            let season = try await self.episodesBySeason(of: show).first { $0[0].seasonNumber == number } ?? []
            return [CPListSection(items: season.map(self.episodeRow))]
        }
    }

    /// Every episode in one request, by season. The server's order stands (Plex lists Specials last).
    private func episodesBySeason(of show: MediaItem) async throws -> [[MediaItem]] {
        guard let browse else { return [] }
        return try await browse.provider(for: show.ref).allEpisodes(of: show.ref).filter(\.isPlayable).groupedBySeason()
    }

    /// "Season 2", from the season's episodes. Nil where the server numbers no season.
    private func seasonName(_ season: [MediaItem]) -> String? {
        season[0].seasonNumber == nil ? nil : season[0].seasonLabel
    }

    // MARK: - Search

    private func openSearch() async {
        guard let interfaceController, !isLocked else { return }
        let search = CPSearchTemplate()
        search.delegate = self
        do {
            _ = try await interfaceController.pushTemplate(search, animated: true)
        } catch {
            DiagLog.error(.launch, "CarPlay search failed: \(error.localizedDescription)")
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String) async -> [CPListItem] {
        searching?.cancel()
        let search = Task { await results(for: searchText) }
        searching = search
        return await search.value
    }

    /// A result carries the handler its row has in a list.
    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem) async {
        guard let handler = item.handler else { return }
        await withCheckedContinuation { done in handler(item) { done.resume() } }
    }

    /// The phone's search over every server, titles only. A query that was typed over, or that
    /// failed, answers with the rows already shown.
    private func results(for text: String) async -> [CPListItem] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let browse, !isLocked, !query.isEmpty else {
            searchResults = []
            return []
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, let hits = try? await SearchResults.search(query, providers: browse.searchProviders),
              !Task.isCancelled else { return searchResults }
        searchResults = hits.titles.filter(isListable).prefix(CPListTemplate.maximumItemCount).map(row)
        return searchResults
    }

    /// Artwork, title and one Play button. Without artwork there is no header: it needs a thumbnail.
    private func header(for show: MediaItem) async -> CPListTemplateDetailsHeader? {
        guard let url = browse?.artworkURL(for: show, kind: .backdrop, width: 960, height: 540),
              let art = await IOSArtworkCache.shared.image(for: url),
              let symbol = UIImage(systemName: "play.fill") else { return nil }
        let play = CPButton(image: symbol) { _ in IOSPlaybackController.shared.play(show) }
        play.title = String(localized: "Play")
        return CPListTemplateDetailsHeader(thumbnail: CPThumbnailImage(image: art), title: show.displayTitle,
                                           subtitle: show.subtitle, actionButtons: [play])
    }

    // MARK: - Rows

    /// What a row can do: play a movie or episode, or open a show.
    private func isListable(_ item: MediaItem) -> Bool {
        item.isPlayable || item.kind == .show || item.kind == .season
    }

    /// On its show's page an episode shows its still and no show name.
    private func episodeRow(_ episode: MediaItem) -> CPListItem {
        let row = row(episode, still: true)
        row.setDetailText(episode.episodeCode)
        return row
    }

    /// Every other row shows a poster: an episode its season's, falling back to the show's.
    private func row(_ item: MediaItem) -> CPListItem { row(item, still: false) }

    private func row(_ item: MediaItem, still: Bool) -> CPListItem {
        let seasonPoster = item.kind == .episode ? item.parentArtwork?.poster : nil
        let url = still ? browse?.artworkURL(for: item, kind: .thumb, width: 480, height: 270)
            : seasonPoster.flatMap { browse?.imageURL($0, providerID: item.ref.providerID, width: 300, height: 450) }
                ?? browse?.artworkURL(for: item, kind: .poster, width: 300, height: 450)
        // A season is listed under its show's name, as a tile opens the show.
        let show = item.seasonShow
        let row = CPListItem(text: show?.displayTitle ?? item.displayTitle,
                             detailText: show == nil ? item.subtitle : item.seasonLabel,
                             image: url.flatMap { IOSArtworkCache.shared.cachedImage(for: $0) })
        if item.isPlayable {
            row.playbackConfiguration = CPPlaybackConfiguration(
                preferredPresentation: .video,
                playbackAction: .play,
                elapsedTime: CMTime(seconds: item.userState.viewOffset, preferredTimescale: 600),
                duration: CMTime(seconds: item.runtime ?? 0, preferredTimescale: 600)
            )
            row.handler = { _, done in
                let playback = IOSPlaybackController.shared
                playback.play(item)
                // The row spins until the player has the title or has given up.
                Task {
                    for await preparing in playback.$isPreparing.values where !preparing { break }
                    done()
                }
            }
        } else {
            row.accessoryType = .disclosureIndicator
            let target = show ?? item
            row.handler = { [weak self] _, done in Task { await self?.openShow(target); done() } }
        }
        if row.image == nil, let url { Task { row.setImage(await IOSArtworkCache.shared.image(for: url)) } }
        return row
    }
}
