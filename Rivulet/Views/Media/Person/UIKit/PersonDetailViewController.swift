// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The cast and crew page (Docs/atv_ref/actor_details_ref.JPG): a biography header over
//  Movies and Shows `ShelfRowCell` shelves, fed by `PersonFilmographyProvider`. Vertical
//  focus scroll is `FocusScrollControlledCollectionView`'s, every row centred.

import UIKit

@MainActor
final class PersonDetailViewController: UIViewController {

    // MARK: - Public

    /// Reports the MediaItem behind a tapped poster (server or metadata-only).
    var onSelectItem: ((MediaItem) -> Void)?

    // MARK: - Section / item model

    private enum Section: Int, CaseIterable {
        case header
        case movies
        case shows
        case knownFor
    }

    /// One item per shelf, as on Home. `nonisolated` and `Sendable` for the diffable
    /// data source's Swift 6 requirement; the VC is @MainActor.
    nonisolated private struct ItemID: Hashable, Sendable {
        let section: Int
        let token: String
    }

    private static let headerItem = ItemID(section: Section.header.rawValue, token: "header")
    private static let moviesItem = ItemID(section: Section.movies.rawValue, token: "movies-row")
    private static let showsItem = ItemID(section: Section.shows.rawValue, token: "shows-row")
    private static let knownForItem = ItemID(section: Section.knownFor.rawValue, token: "known-for-row")

    // MARK: - Dependencies / state

    private let person: MediaPerson
    private let provider: PersonFilmographyProviding

    private var detail: PersonDetail?
    private var movies: [FilmographyEntry] = []
    private var shows: [FilmographyEntry] = []
    private var knownFor: [FilmographyEntry] = []
    /// True from first paint until the provider returns — drives the header's
    /// loading dots so the page reads as "working".
    private var isLoading = true

    /// The current section layout, in display order. Recomputed on every
    /// reload so empty shelves drop out.
    private var sections: [Section] = [.header]

    private var loadTask: Task<Void, Never>?

    /// Resting horizontal offset per shelf, restored across cell reuse.
    private var shelfOffsets: [Section: CGFloat] = [:]

    // MARK: - Views

    private let gradientLayer = CAGradientLayer()
    /// Full-bleed backdrop image from the originating title. Hidden when no URL.
    private let backdropImageView = UIImageView()
    /// Dark blur over the backdrop to keep text readable.
    private let backdropBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    /// Subtle dark scrim (0.35 alpha black) on top of the blur for legibility.
    private let backdropScrimView = UIView()
    private var collectionView: FocusScrollControlledCollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, ItemID>!

    /// Blur-fade dissolve in/out (same transition as navigating to a related
    /// item from the expanded detail). Retained for the lifetime of the VC —
    /// the transitioning delegate is held weakly by UIKit.
    private let blurFade = BlurFadeTransitioningDelegate()

    // MARK: - Init

    init(person: MediaPerson, provider: PersonFilmographyProviding = PersonFilmographyProvider()) {
        self.person = person
        self.provider = provider
        super.init(nibName: nil, bundle: nil)
        // Blur-fade dissolve over whatever's behind (the previous detail), kept
        // visible because it's presented over another modal — same as the
        // standalone related-item detail. .overFullScreen so the blur reads.
        modalPresentationStyle = .overFullScreen
        transitioningDelegate = blurFade
    }

    /// Native Silo entry point. The result's opaque identity is validated by
    /// the injected provider; it never reaches the default Plex adapter.
    static func silo(result: MediaPersonResult, provider: SiloProvider,
                     inLibraries libraryIDs: [String]) throws -> PersonDetailViewController {
        guard result.providerID == provider.id,
              SiloPersonContext.personID(result.person.id, provider: provider) != nil else {
            throw SiloPeopleError.staleAuthority
        }
        return PersonDetailViewController(
            person: result.person,
            provider: provider.personFilmographyProvider(inLibraries: libraryIDs))
    }

    /// Cast and crew IDs from a Silo detail page use this same native route.
    static func silo(cast person: MediaPerson, provider: SiloProvider,
                     inLibraries libraryIDs: [String]) throws -> PersonDetailViewController {
        try silo(result: MediaPersonResult(person: person, providerID: provider.id),
                 provider: provider, inLibraries: libraryIDs)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PersonDetailViewController is not Storyboard-backed") }

    deinit {
        loadTask?.cancel()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureBackdrop()
        configureGradient()
        configureCollectionView()
        configureDataSource()

        // Show the skeleton/empty state immediately, then fetch.
        applySnapshot(animated: false)
        loadTask = Task { [weak self] in await self?.reload() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradientLayer.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Express focus here (not viewDidLoad/viewWillAppear): the view is in
        // the window now, so setNeedsFocusUpdate resolves to a real target.
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
        loadTask = nil
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Start on the bio panel, focusable from first paint; the collection if the header is not realized.
        let headerPath = IndexPath(item: 0, section: 0)
        if sections.first == .header,
           let header = collectionView.cellForItem(at: headerPath) {
            return [header]
        }
        return [collectionView]
    }

    // MARK: - Setup

    /// Blurred backdrop layer — the originating title's art behind everything.
    /// Falls back to the existing gradient when `person.backdropURL` is nil.
    private func configureBackdrop() {
        guard let url = person.backdropURL else { return }

        // All three views are pinned full-bleed (ignore safe area — backdrops
        // should reach screen edges, matching the tvOS HIG backdrop convention).
        backdropImageView.translatesAutoresizingMaskIntoConstraints = false
        backdropImageView.contentMode = .scaleAspectFill
        backdropImageView.clipsToBounds = true
        backdropImageView.alpha = 0  // Fade in once the image loads

        backdropBlurView.translatesAutoresizingMaskIntoConstraints = false

        backdropScrimView.translatesAutoresizingMaskIntoConstraints = false
        backdropScrimView.backgroundColor = UIColor.black.withAlphaComponent(0.35)

        // Insert below the gradient and collection view so focus/interaction is
        // unaffected. Insertion order: imageView → blurView → scrimView, then the
        // existing gradientLayer (a sublayer) sits on top for color-grading.
        view.insertSubview(backdropImageView, at: 0)
        view.insertSubview(backdropBlurView, aboveSubview: backdropImageView)
        view.insertSubview(backdropScrimView, aboveSubview: backdropBlurView)

        let edgeConstraints: (UIView) -> [NSLayoutConstraint] = { v in
            [
                v.topAnchor.constraint(equalTo: self.view.topAnchor),
                v.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            ]
        }
        NSLayoutConstraint.activate(
            edgeConstraints(backdropImageView) +
            edgeConstraints(backdropBlurView) +
            edgeConstraints(backdropScrimView)
        )

        // Load the image off-main using the same ImageCacheManager pattern as
        // CastCell / PersonHeaderCell — no new dependency.
        Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            await MainActor.run {
                guard let self, let image else { return }
                self.backdropImageView.image = image
                UIView.animate(withDuration: 0.4) {
                    self.backdropImageView.alpha = 1
                }
            }
        }
    }

    /// Dark blue → black vertical gradient, less artwork-specific than the show
    /// detail pages (ref: "dark blue/black gradient").
    private func configureGradient() {
        gradientLayer.colors = [
            UIColor(red: 0.05, green: 0.07, blue: 0.16, alpha: 1).cgColor,
            UIColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1).cgColor,
            UIColor.black.cgColor,
        ]
        gradientLayer.locations = [0.0, 0.6, 1.0]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        view.layer.insertSublayer(gradientLayer, at: 0)
    }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            self?.layoutSection(at: sectionIndex, environment: environment)
        }
        collectionView = FocusScrollControlledCollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.clipsToBounds = false
        // The engine's scroll animator would race the subclass's display-link scroll.
        collectionView.isScrollEnabled = false
        collectionView.register(PersonHeaderCell.self, forCellWithReuseIdentifier: PersonHeaderCell.reuseID)
        collectionView.register(ShelfRowCell.self, forCellWithReuseIdentifier: ShelfRowCell.reuseID)
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Int, ItemID>(collectionView: collectionView) {
            [weak self] collectionView, indexPath, itemID in
            self?.cell(for: itemID, at: indexPath, in: collectionView)
        }
    }

    // MARK: - Layout

    private func layoutSection(at sectionIndex: Int, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? {
        guard sectionIndex < sections.count else { return nil }
        switch sections[sectionIndex] {
        case .header:        return makeHeaderSectionLayout()
        case .movies, .shows, .knownFor: return makeShelfSectionLayout()
        }
    }

    /// Full-width header (portrait + name + bio + MORE). Estimated height; the
    /// cell hugs its content. Leading/trailing match the shared content margin.
    private func makeHeaderSectionLayout() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                          heightDimension: .estimated(250))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsetsReference = .none
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 120,   // portrait top, measured on device (tvOS 27)
            leading: MediaRowMetrics.rowLeading,
            bottom: 48,   // puts the first shelf header's cap top 67.5 below the portrait
            trailing: MediaRowMetrics.rowTrailing)
        return section
    }

    /// One full-bleed ShelfRowCell per shelf, titled by the cell. Height is its header (44),
    /// the poster tile and focus-growth padding.
    private func makeShelfSectionLayout() -> NSCollectionLayoutSection {
        let shelfHeaderHeight: CGFloat = 44   // ShelfRowCell.headerHeight
        let rowHeight = shelfHeaderHeight + MediaRowMetrics.posterHeight + MediaRowMetrics.focusGrowthPadding
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                          heightDimension: .absolute(rowHeight))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        // Full-bleed: ShelfRowCell owns the leading margin + peeking slivers
        // internally.
        section.contentInsetsReference = .none
        section.contentInsets = NSDirectionalEdgeInsets(
            top: MediaRowMetrics.rowTopInset,
            leading: 0,
            bottom: MediaRowMetrics.rowBottomInset,
            trailing: 0)
        return section
    }

    // MARK: - Cells

    private func cell(for itemID: ItemID, at indexPath: IndexPath, in collectionView: UICollectionView) -> UICollectionViewCell {
        guard indexPath.section < sections.count else {
            return collectionView.dequeueReusableCell(withReuseIdentifier: PersonHeaderCell.reuseID, for: indexPath)
        }
        switch sections[indexPath.section] {
        case .header:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PersonHeaderCell.reuseID, for: indexPath) as! PersonHeaderCell
            cell.configure(
                name: detail?.name ?? person.name,
                biography: detail?.biography,
                // Always the Plex thumb — identical before/after load so the
                // portrait never visibly swaps when the bio arrives.
                portraitURL: person.imageURL,
                isLoading: isLoading,
                onMore: { [weak self] in self?.presentBiography() })
            return cell
        case .movies:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
            configureShelf(cell, section: .movies, title: "Movies", entries: movies)
            return cell
        case .shows:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
            configureShelf(cell, section: .shows, title: "Shows", entries: shows)
            return cell
        case .knownFor:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
            configureShelf(cell, section: .knownFor, title: "Known For", entries: knownFor)
            return cell
        }
    }

    private func configureShelf(_ cell: ShelfRowCell, section: Section, title: String, entries: [FilmographyEntry]) {
        cell.headerTitle = title
        cell.cellProvider = { [weak self] innerCV, indexPath in
            guard let self else {
                return innerCV.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath)
            }
            let poster = innerCV.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath) as! PosterCell
            let entries = self.entries(for: section)
            if indexPath.item < entries.count {
                poster.configure(item: entries[indexPath.item].item)
            }
            return poster
        }
        cell.onSelect = { [weak self] index in
            guard let self else { return }
            let entries = self.entries(for: section)
            guard index < entries.count else { return }
            self.onSelectItem?(entries[index].item)
        }
        // No tile menu: Home's builders take watchlist item types, not a bare MediaItem.
        cell.onOffsetChanged = { [weak self] offset in
            self?.shelfOffsets[section] = offset
        }
        cell.configure(
            kind: .poster,
            realCount: entries.count,
            hasSkeleton: false,
            contentToken: contentToken(for: entries),
            initialOffset: shelfOffsets[section] ?? 0)
    }

    private func entries(for section: Section) -> [FilmographyEntry] {
        switch section {
        case .header: return []
        case .movies: return movies
        case .shows: return shows
        case .knownFor: return knownFor
        }
    }

    /// Content identity for a shelf — reload its tiles only when this changes.
    private func contentToken(for entries: [FilmographyEntry]) -> Int {
        var hasher = Hasher()
        for entry in entries { hasher.combine(entry.item.ref.itemID) }
        return hasher.finalize()
    }

    // MARK: - Data

    private func reload() async {
        async let knownForTask = provider.knownFor(person: person)
        let loaded: PersonDetail
        do {
            loaded = try await provider.load(person: person)
        } catch {
            // The provider degrades gracefully for the no-token / fetch-error
            // case, but can still throw — show name + portrait with empty rows
            // rather than crashing.
            loaded = PersonDetail(
                id: person.tagKey ?? person.id,
                name: person.name,
                biography: nil,
                portraitURL: person.imageURL,
                movies: [],
                shows: [])
        }
        if Task.isCancelled { return }

        detail = loaded
        movies = loaded.movies
        shows = loaded.shows
        isLoading = false
        applySnapshot(animated: false)

        let titles = await knownForTask
        if Task.isCancelled { return }
        knownFor = FilmographyEntry.excluding(movies + shows, from: titles)
        if !knownFor.isEmpty { applySnapshot(animated: false) }
    }

    private func applySnapshot(animated: Bool) {
        // Fixed section set: header always; a shelf only when it has entries.
        var visible: [Section] = [.header]
        if !movies.isEmpty { visible.append(.movies) }
        if !shows.isEmpty { visible.append(.shows) }
        if !knownFor.isEmpty { visible.append(.knownFor) }
        sections = visible

        var snapshot = NSDiffableDataSourceSnapshot<Int, ItemID>()
        for section in visible {
            snapshot.appendSections([section.rawValue])
            switch section {
            case .header: snapshot.appendItems([Self.headerItem], toSection: section.rawValue)
            case .movies: snapshot.appendItems([Self.moviesItem], toSection: section.rawValue)
            case .shows:  snapshot.appendItems([Self.showsItem], toSection: section.rawValue)
            case .knownFor: snapshot.appendItems([Self.knownForItem], toSection: section.rawValue)
            }
        }
        dataSource.apply(snapshot, animatingDifferences: animated)

        // Shelf rows keep a single diffable identity, so pushing fresh content
        // into already-visible rows must be done by hand (mirrors the home).
        refreshVisibleCells()
    }

    /// Re-push current data into visible cells whose diffable identity didn't
    /// change (the header text/portrait after load; shelf tiles after load).
    private func refreshVisibleCells() {
        for cell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell),
                  indexPath.section < sections.count else { continue }
            switch sections[indexPath.section] {
            case .header:
                (cell as? PersonHeaderCell)?.configure(
                    name: detail?.name ?? person.name,
                    biography: detail?.biography,
                    portraitURL: person.imageURL,
                    isLoading: isLoading,
                    onMore: { [weak self] in self?.presentBiography() })
            case .movies:
                if let row = cell as? ShelfRowCell {
                    configureShelf(row, section: .movies, title: "Movies", entries: movies)
                }
            case .shows:
                if let row = cell as? ShelfRowCell {
                    configureShelf(row, section: .shows, title: "Shows", entries: shows)
                }
            case .knownFor:
                if let row = cell as? ShelfRowCell {
                    configureShelf(row, section: .knownFor, title: "Known For", entries: knownFor)
                }
            }
        }
    }

    // MARK: - Biography popup

    private func presentBiography() {
        guard let detail, let bio = detail.biography, !bio.isEmpty else { return }
        let content = InfoPopupContent.description(title: detail.name, subtitle: nil, body: bio)
        let popup = InfoPopupViewController(content: content, width: InfoPopupViewController.descriptionSize.width, height: InfoPopupViewController.descriptionSize.height, scrollable: true)
        present(popup, animated: true)
    }
}
