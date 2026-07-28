// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  BelowFoldCollectionView.swift
//  Rivulet
//
//  The focus-driven below-fold for the expanded detail: a compositional
//  UICollectionView (vertical sections, each an orthogonal horizontal row).
//  Sections this pass: Episodes, Related, Cast & Crew (season pills are a
//  follow-up). Fed by BelowFoldContentLoader. The outer vertical
//  scrollViewDidScroll drives the hero choreography via `onScroll`
//  (contentOffset.y + adjustedContentInset.top). See
//  perf-spike/EXPANDED_DETAIL_CONVERSION_SPIKE.md §1.
//
//  Coexistence: this lives inside ExpandedDetailContainerView, hidden in
//  carousel-stable, and is cross-faded in AFTER the expand morph completes
//  (never on the morph clock — §6). At rest its episodes row peeks at the
//  bottom (large top content inset), matching the placeholder peek position.
//

import UIKit

// nonisolated + Sendable: required to be diffable identifiers under the
// project's SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor (matches HomeSectionID).
nonisolated enum BelowFoldSectionKind: Hashable, Sendable {
    case episodes
    case trailers
    case extras
    case related
    case cast
    case about
    case info
}

nonisolated enum BelowFoldItem: Hashable, Sendable {
    case episode(String)
    case trailer(String)
    case extra(String)
    case related(String)
    /// The whole Related row as ONE item — a ShelfRowCell hosting its own
    /// horizontal collection view, so the row matches the home/library
    /// shelves exactly (geometry, peeks, pitch-aligned landings, glide).
    case relatedShelf
    case cast(String)
    case about       // single full-width card block
    case info        // single full-width columns block
}

final class BelowFoldCollectionView: UIView, UICollectionViewDelegate {

    /// How much of the episode thumbnails peeks at rest (matches the placeholder peek).
    private static let episodePeek: CGFloat = 40
    /// Shared left margin for the WHOLE detail: the season pills, every
    /// below-fold row, AND the expanded hero metadata all align to this edge
    /// (single source of truth = the hero's chrome inset).
    private static let rowLeading: CGFloat = PreviewCarouselGeometry.expandedChromeInset
    // 0 = content (rails + full-width cards) runs to the right screen edge. The
    // left margin is intentional (rowLeading); the right should not mirror it.
    private static let rowTrailing: CGFloat = 0
    private static let episodeWidth: CGFloat = EpisodeCell.cardWidth
    private static let episodeHeight: CGFloat = 435
    private static let trailerWidth: CGFloat = EpisodeCell.cardWidth
    // Same episode card, minus the episode-number / summary / footer rows — so the
    // card hugs thumbnail (245) + 8 + title block (~64).
    private static let trailerHeight: CGFloat = 318
    private static let relatedWidth: CGFloat = MediaRowMetrics.posterWidth
    private static let castWidth: CGFloat = CastCell.circleSize   // cell == circle; labels overflow into the gap

    /// contentOffset.y + adjustedContentInset.top (0 at rest, grows as scrolled).
    var onScroll: ((CGFloat) -> Void)?
    /// Fires when focus lands on an episode cell (the episode), or nil for any
    /// other cell / focus leaving. Drives season-pill tracking in the container.
    var onEpisodeFocused: ((MediaItem?) -> Void)?
    /// Episode thumb Select → play the episode.
    var onPlayEpisode: ((MediaItem) -> Void)?
    /// Trailer / extra Select → play that video (by Plex ratingKey).
    var onPlayTrailer: ((BelowFoldTrailer) -> Void)?
    /// Related poster Select → open that item's detail page (blur-fade).
    var onShowRelatedDetails: ((MediaItem) -> Void)?
    /// Episode description Select → open the episode detail page.
    var onShowEpisodeDetails: ((MediaItem) -> Void)?
    /// Cast / crew cell Select → open the person detail page.
    var onSelectPerson: ((MediaPerson) -> Void)?
    /// Selecting the About cards opens the matching popup (synopsis / advisory).
    var onSelectSynopsis: ((MediaItemDetail) -> Void)?
    var onSelectAdvisory: ((ContentAdvisory) -> Void)?

    /// Which sub-target of the focused episode card is focused (thumb vs
    /// description). Set from the cell's focus reporting.
    private(set) var focusedEpisodeKind: EpisodeFocusKind = .none
    /// When the episode thumb most recently took focus. Up that lands on the
    /// thumb within the same-press window (coming up from the description or a
    /// lower row) must STICK on the thumb; only a deliberate Up from a resting
    /// thumb lifts to the season pills.
    private var lastThumbFocusTime: CFTimeInterval = 0

    private var collectionView: FocusScrollControlledCollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<BelowFoldSectionKind, BelowFoldItem>!
    private var sectionKinds: [BelowFoldSectionKind] = []

    private let loader = BelowFoldContentLoader()
    private var loadToken: UInt64 = 0
    /// Last item handed to `configure`/`configureEpisodesOnly`. Held so a
    /// watch-state refresh can re-run the episode fetch without the host
    /// having to re-plumb the item (issue #228).
    private var configuredItem: MediaItem?

    private var episodesByID: [String: MediaItem] = [:]
    private var trailersByID: [String: BelowFoldTrailer] = [:]
    private var extrasByID: [String: BelowFoldTrailer] = [:]
    private var relatedByID: [String: MediaItem] = [:]
    private var castEntriesByID: [String: CastEntry] = [:]
    private var multiSeason = false
    /// Full detail for the About + Information/Languages/Accessibility blocks.
    private var detail: MediaItemDetail?
    /// SHOW detail for episode/season opens (the About card describes the show);
    /// nil for movies/show-level (use `detail`).
    private var showDetail: MediaItemDetail?

    private struct CastEntry { let person: MediaPerson; let subtitle: String? }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        collectionView = FocusScrollControlledCollectionView(frame: bounds, collectionViewLayout: makeLayout())
        collectionView.topBand = Self.detailsTopY
        // Disable the collection's own (vertical) scrolling so the focus engine
        // can't spin up its centering "focus scroll animator". We drive all
        // vertical scroll ourselves (slide on entry, didUpdateFocus per section).
        // Orthogonal (horizontal) row scrolling is a separate inner scroller.
        collectionView.isScrollEnabled = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.showsVerticalScrollIndicator = false
        // OFF: "remember last focused" would win over indexPathForPreferredFocusedView
        // and the geometric Down entry, so Down from a season pill snapped focus
        // back to the remembered episode (season 1 ep0). Without it, Down enters
        // the current season's first episode (nearest-visible / preferred index).
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.register(EpisodeCollectionCell.self, forCellWithReuseIdentifier: EpisodeCollectionCell.reuseID)
        collectionView.register(TrailerCollectionCell.self, forCellWithReuseIdentifier: TrailerCollectionCell.reuseID)
        collectionView.register(RelatedPosterCell.self, forCellWithReuseIdentifier: RelatedPosterCell.reuseID)
        collectionView.register(ShelfRowCell.self, forCellWithReuseIdentifier: ShelfRowCell.reuseID)
        collectionView.register(CastCollectionCell.self, forCellWithReuseIdentifier: CastCollectionCell.reuseID)
        collectionView.register(AboutCollectionCell.self, forCellWithReuseIdentifier: AboutCollectionCell.reuseID)
        collectionView.register(InfoColumnsCollectionCell.self, forCellWithReuseIdentifier: InfoColumnsCollectionCell.reuseID)
        collectionView.register(
            BelowFoldSectionHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: BelowFoldSectionHeader.reuseID
        )
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        configureDataSource()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("BelowFoldCollectionView is not Storyboard-backed") }

    /// Forward focus into the collection (the engine finds the first focusable cell).
    override var preferredFocusEnvironments: [UIFocusEnvironment] { [collectionView] }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // Small top inset = where episodes land in details (so the focus engine
        // aligns them there). The carousel-stable peek offset is provided by the
        // large TOP INSET on the episodes section (see makeLayout), not by this.
        let topInset = Self.detailsTopY
        if collectionView.contentInset.top != topInset {
            collectionView.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
            collectionView.setContentOffset(CGPoint(x: 0, y: -topInset), animated: false)
        }
        // Position the rail at the carousel item's season BEFORE first render
        // (no visible scroll). Retry until the orthogonal scroller is built.
        if let target = pendingInitialScroll {
            collectionView.layoutIfNeeded()   // ensure the orthogonal scroller exists
            if scrollOrthogonalEpisodes(toItem: target.item, epSection: target.section, animated: false) {
                pendingInitialScroll = nil
            }
        }
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, _ in
            guard let self, self.sectionKinds.indices.contains(index) else { return nil }
            // The FIRST section is the "primary peek row" — Episodes for shows,
            // Related for movies. A large TOP inset on it provides the carousel-
            // stable peek (it peeks at the bottom) AND the scroll distance that
            // drives the Down slide + backdrop blur + chrome fade. Without this on
            // the first section, movies (Trailers first) had a tiny inset, so the
            // slide barely moved and the blur/fade never triggered.
            let isPrimary = (index == 0)
            let peek = max(0, self.bounds.height - Self.episodePeek - Self.detailsTopY)
            switch self.sectionKinds[index] {
            // Episodes: LEFT-aligned (ATV+), first card at the metadata inset
            // (leading 128). The collection's small contentInset.top (= detailsTopY)
            // lets the focus engine land them at ~detailsTopY in details.
            case .episodes:
                return self.shelfSection(
                    itemW: Self.episodeWidth,
                    itemH: Self.episodeHeight,
                    leading: Self.rowLeading,
                    gap: 16,
                    header: false,
                    topInset: isPrimary ? peek : 0,
                    sectionBottomInset: 36
                )
            case .trailers:
                return self.shelfSection(
                    itemW: Self.trailerWidth,
                    itemH: Self.trailerHeight,
                    leading: Self.rowLeading,
                    gap: 36,
                    header: !isPrimary,
                    topInset: isPrimary ? peek : 0,
                    headerTopInset: 8,
                    headerHeight: 44,
                    sectionBottomInset: 96
                )
            case .extras:
                return self.shelfSection(
                    itemW: Self.trailerWidth,
                    itemH: Self.trailerHeight,
                    leading: Self.rowLeading,
                    gap: 36,
                    header: !isPrimary,
                    topInset: isPrimary ? peek : 0,
                    headerTopInset: 8,
                    headerHeight: 44,
                    sectionBottomInset: 96
                )
            case .related:
                // Home-identical shelf: one full-width ShelfRowCell hosting
                // the posters (margin 40, symmetric peeks, pitch landings).
                // As the primary row, lift the section by its own header (+ the
                // section's 8pt pad) so the 40pt peek strip is POSTER, like the
                // episodes row — the "Related" title rides just above it.
                let relatedLift = ShelfRowCell.headerHeight + 8
                return self.homeShelfHostSection(
                    topInset: isPrimary ? max(0, peek - relatedLift) : 0,
                    sectionBottomInset: isPrimary ? 36 : 56
                )
            case .cast:
                return self.shelfSection(
                    itemW: Self.castWidth,
                    itemH: 355,
                    leading: Self.rowLeading,
                    gap: 40,   // circle-to-circle = castWidth(263) + gap → ~6 across + 7th peeking
                    header: true
                )
            case .about: return self.fullWidthSection(height: 370)
            case .info:  return self.fullWidthSection(height: 460, band: true)
            }
        }
        layout.register(InfoBandDecorationView.self, forDecorationViewOfKind: InfoBandDecorationView.kind)
        return layout
    }

    /// One full-width item hosting a ShelfRowCell (the Related row). NOT an
    /// orthogonal section — the shelf cell drives its own horizontal scroll
    /// with the home shelf's exact geometry and landings. The item spans the
    /// whole (panel + overshoot) collection width; panel alignment happens
    /// inside the cell via panelOvershoot.
    private func homeShelfHostSection(topInset: CGFloat = 0,
                                      sectionBottomInset: CGFloat = 56) -> NSCollectionLayoutSection {
        // The ShelfRowCell draws its own header (self-aligned with the tiles),
        // so there's NO supplementary header — just one full-width item tall
        // enough for the header + the row.
        let rowHeight = ShelfRowCell.headerHeight + MediaRowMetrics.posterHeight + MediaRowMetrics.focusGrowthPadding
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .absolute(rowHeight))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = .init(
            top: 8 + topInset,
            leading: 0,
            bottom: sectionBottomInset,
            trailing: 0
        )
        return section
    }

    /// A single full-width block (About / Info columns) — no orthogonal scroll,
    /// left/right gutters matching the rails.
    private func fullWidthSection(height: CGFloat, band: Bool = false) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = .init(top: 24, leading: Self.rowLeading, bottom: 56, trailing: Self.rowTrailing)
        if band {
            // Full-width darkened band behind the section (spans the section rect,
            // edge to edge — the columns stay inset via contentInsets).
            section.decorationItems = [.background(elementKind: InfoBandDecorationView.kind)]
        }
        return section
    }

    private func shelfSection(
        itemW: CGFloat,
        itemH: CGFloat,
        leading: CGFloat,
        gap: CGFloat,
        header: Bool,
        topInset: CGFloat = 0,
        headerTopInset: CGFloat = 16,
        headerHeight: CGFloat = 44,
        sectionBottomInset: CGFloat = 56
    ) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .absolute(itemW), heightDimension: .absolute(itemH)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .absolute(itemW), heightDimension: .absolute(itemH)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = gap
        section.contentInsets = .init(
            top: (header ? headerTopInset : 0) + topInset,
            leading: leading,
            bottom: sectionBottomInset,
            trailing: Self.rowTrailing
        )
        if header {
            let headerItem = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(headerHeight)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
            // Do not apply the row leading again here. The section already owns
            // the leading inset; adding it to the boundary header double-indents
            // titles away from their cards.
            headerItem.contentInsets = .zero
            section.boundarySupplementaryItems = [headerItem]
        }
        return section
    }

    // MARK: - Data source

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<BelowFoldSectionKind, BelowFoldItem>(
            collectionView: collectionView
        ) { [weak self] cv, indexPath, item in
            guard let self else { return UICollectionViewCell() }
            switch item {
            case .episode(let id):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: EpisodeCollectionCell.reuseID, for: indexPath) as! EpisodeCollectionCell
                if let ep = self.episodesByID[id] {
                    cell.configure(episode: ep, showSeasonPrefix: self.multiSeason)
                    // Per-cell focus drives season-pill tracking (fires on every
                    // horizontal move; the collection's didUpdateFocus does not).
                    cell.onFocused = { [weak self] focused in
                        if focused { self?.pendingInitialFocus = nil; self?.onEpisodeFocused?(ep) }
                    }
                    // Two focus stops: thumb = play, description = detail page.
                    cell.onPlay = { [weak self] in self?.onPlayEpisode?(ep) }
                    cell.onShowDetails = { [weak self] in self?.onShowEpisodeDetails?(ep) }
                    cell.onFocusKind = { [weak self] kind in
                        guard let self else { return }
                        if kind == .thumb { self.lastThumbFocusTime = CACurrentMediaTime() }
                        self.focusedEpisodeKind = kind
                    }
                }
                return cell
            case .trailer(let id):
                // Trailers reuse the EpisodeCollectionCell so they match episodes
                // exactly (TVCardView thumbnail + sheen + frosted focus panel).
                let cell = cv.dequeueReusableCell(withReuseIdentifier: EpisodeCollectionCell.reuseID, for: indexPath) as! EpisodeCollectionCell
                cell.onFocused = nil   // trailers don't drive season-pill tracking
                if let trailer = self.trailersByID[id] {
                    cell.configure(trailer: trailer)
                    cell.onPlay = { [weak self] in self?.onPlayTrailer?(trailer) }
                }
                return cell
            case .extra(let id):
                // Extras render exactly like trailers (same cell + playback path).
                let cell = cv.dequeueReusableCell(withReuseIdentifier: EpisodeCollectionCell.reuseID, for: indexPath) as! EpisodeCollectionCell
                cell.onFocused = nil
                if let extra = self.extrasByID[id] {
                    cell.configure(trailer: extra)
                    cell.onPlay = { [weak self] in self?.onPlayTrailer?(extra) }
                }
                return cell
            case .related(let id):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: RelatedPosterCell.reuseID, for: indexPath) as! RelatedPosterCell
                if let it = self.relatedByID[id] { cell.configure(item: it) }
                return cell

            case .relatedShelf:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
                let items = self.relatedItems
                var hasher = Hasher()
                for it in items { hasher.combine(it.ref.itemID) }
                cell.cellProvider = { innerCV, ip in
                    let poster = innerCV.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: ip) as! PosterCell
                    if ip.item < items.count { poster.configure(item: items[ip.item]) }
                    return poster
                }
                cell.onSelect = { [weak self] idx in
                    guard let self, idx < self.relatedItems.count else { return }
                    self.onShowRelatedDetails?(self.relatedItems[idx])
                }
                cell.onWillDisplayItem = nil
                cell.onLongPressItem = nil
                cell.onOffsetChanged = nil
                // Self-align to the screen's rowLeading (robust to the
                // below-fold's state-dependent translation), and draw the
                // header in-cell so it aligns with the tiles.
                cell.screenAlignsLeading = true
                cell.headerTitle = "Related"
                cell.configure(
                    kind: .poster,
                    realCount: items.count,
                    hasSkeleton: false,
                    contentToken: hasher.finalize(),
                    initialOffset: 0
                )
                return cell
            case .cast(let id):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: CastCollectionCell.reuseID, for: indexPath) as! CastCollectionCell
                if let e = self.castEntriesByID[id] { cell.configure(person: e.person, fallbackSubtitle: e.subtitle) }
                return cell
            case .about:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: AboutCollectionCell.reuseID, for: indexPath) as! AboutCollectionCell
                cell.onSelectSynopsis = { [weak self] d in self?.onSelectSynopsis?(d) }
                cell.onSelectAdvisory = { [weak self] a in self?.onSelectAdvisory?(a) }
                // About always describes the SHOW (show detail for episodes/seasons).
                if let d = self.showDetail ?? self.detail { cell.configure(detail: d) }
                return cell
            case .info:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: InfoColumnsCollectionCell.reuseID, for: indexPath) as! InfoColumnsCollectionCell
                if let d = self.detail { cell.configure(detail: d) }
                return cell
            }
        }

        dataSource.supplementaryViewProvider = { [weak self] cv, kind, indexPath in
            guard let self, kind == UICollectionView.elementKindSectionHeader,
                  self.sectionKinds.indices.contains(indexPath.section) else { return nil }
            let header = cv.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: BelowFoldSectionHeader.reuseID, for: indexPath) as! BelowFoldSectionHeader
            switch self.sectionKinds[indexPath.section] {
            case .trailers: header.configure(title: "Trailers")
            case .extras:  header.configure(title: "Extras")
            case .related: header.configure(title: "Related")
            case .cast:    header.configure(title: "Cast & Crew")
            case .episodes, .about, .info: header.configure(title: "")
            }
            return header
        }
    }

    // MARK: - Configure (fetch + populate)

    /// Load + render the below-fold for `item`. `detail` (if the chrome already
    /// fetched it) supplies cast without a second round-trip.
    func configure(item: MediaItem, detail: MediaItemDetail?) {
        loadToken &+= 1
        let token = loadToken
        configuredItem = item
        Task { [weak self] in
            guard let self else { return }
            let content = await self.loader.load(for: item, detail: detail)
            guard self.loadToken == token else { return }
            self.ingest(content)
            self.applySnapshot()
            self.scrollToInitialEpisode(item: item)
            // CHAINED (not a racing Task): the full content advisory is fetched
            // AFTER ingest, so it can't be clobbered by `ingest` overwriting
            // `self.detail` with the partial. Render already happened at
            // applySnapshot, so this is still non-blocking. Patch the About cell.
            let advisory = await self.loader.loadAdvisory(for: item)
            guard self.loadToken == token, let advisory else { return }
            self.applyContentAdvisory(advisory)
        }
    }

    /// Patch the About cell with the rich advisory after it arrives, without a
    /// full snapshot rebuild (focus-preserving). No-op if About isn't present.
    private func applyContentAdvisory(_ advisory: ContentAdvisory) {
        guard detail != nil else { return }
        // Set on whichever detail the About card renders (show detail for
        // episodes/seasons, else the item detail).
        if showDetail != nil { showDetail?.contentAdvisory = advisory }
        else { detail?.contentAdvisory = advisory }
        var snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(.about) else { return }
        snapshot.reconfigureItems([.about])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Episodes-only load for the carousel-stable peek (per page) — skips the
    /// heavier cast/related fetch until expand.
    func configureEpisodesOnly(item: MediaItem) {
        loadToken &+= 1
        let token = loadToken
        configuredItem = item
        let showRef: MediaItemRef?
        switch item.kind {
        case .show: showRef = item.ref
        case .episode: showRef = item.grandparentRef
        default: showRef = nil
        }
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else {
            ingestEpisodesOnly([]); applySnapshot(); return
        }
        Task { [weak self] in
            guard let self else { return }
            let eps: [MediaItem]
            if let showRef {
                eps = (try? await provider.allEpisodes(of: showRef)) ?? []
            } else if item.kind == .season {
                eps = (try? await provider.children(of: item.ref)) ?? []
            } else {
                eps = []
            }
            guard self.loadToken == token else { return }
            self.ingestEpisodesOnly(eps)
            self.applySnapshot()
            self.scrollToInitialEpisode(item: item)
        }
    }

    /// Re-read the episode rail's watch state from the server and repaint the
    /// cards in place (issue #228: the rail kept rendering the pre-playback
    /// snapshot after the player dismissed).
    ///
    /// Deliberately NOT a re-`configure`: the diffable identifiers are
    /// `.episode(ratingKey)`, so a plain re-apply is an empty diff and the
    /// cells never redraw. Instead the fresh items are swapped into
    /// `episodesByID` and the same identifiers are `reconfigureItems`-ed, which
    /// re-runs `cellForItemAt` on the EXISTING cells — no insert/delete, so the
    /// focus engine keeps whatever is focused. `allEpisodes` is an uncached GET,
    /// so this always reads the committed server state.
    func refreshWatchState() {
        guard let item = configuredItem else { return }
        let showRef: MediaItemRef?
        switch item.kind {
        case .show: showRef = item.ref
        case .episode: showRef = item.grandparentRef
        default: showRef = nil
        }
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return }
        // Its OWN token, not `loadToken`: bumping that one would invalidate an
        // in-flight `configure`. Both the refresh token AND the load token are
        // checked on landing, so a refresh is dropped if a newer refresh or ANY
        // configure has started since.
        refreshToken &+= 1
        let refresh = refreshToken
        let load = loadToken
        Task { [weak self] in
            guard let self else { return }
            let eps: [MediaItem]
            if let showRef {
                eps = (try? await provider.allEpisodes(of: showRef)) ?? []
            } else if item.kind == .season {
                eps = (try? await provider.children(of: item.ref)) ?? []
            } else {
                eps = []
            }
            guard self.refreshToken == refresh, self.loadToken == load, !eps.isEmpty else { return }
            self.applyRefreshedEpisodes(eps)
        }
    }

    private var refreshToken: UInt64 = 0

    /// Swap freshly-fetched episodes into the lookup and reconfigure only the
    /// identifiers whose content actually changed.
    private func applyRefreshedEpisodes(_ episodes: [MediaItem]) {
        var changed: [BelowFoldItem] = []
        for episode in episodes {
            let id = episode.ref.itemID
            guard let existing = episodesByID[id] else { continue }
            guard existing != episode else { continue }
            episodesByID[id] = episode
            changed.append(.episode(id))
        }
        guard !changed.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        // Only reconfigure identifiers the snapshot still holds — a refresh can
        // land after the rail has been re-configured for a different show.
        let present = Set(snapshot.itemIdentifiers)
        let targets = changed.filter { present.contains($0) }
        guard !targets.isEmpty else { return }
        snapshot.reconfigureItems(targets)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func ingestEpisodesOnly(_ episodes: [MediaItem]) {
        // Match the full-ingest label format: a multi-season show shows "S01E01"
        // prefixes, not "Episode N". (Derived from the episodes themselves since
        // the lighter peek load doesn't fetch the seasons list.)
        multiSeason = Set(episodes.compactMap { $0.seasonNumber }).count > 1
        episodesByID = Dictionary(episodes.map { ($0.ref.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        cachedEpisodes = episodes.map { BelowFoldItem.episode($0.ref.itemID) }
        // Cast/related/about are loaded only on expand.
        trailersByID = [:]; extrasByID = [:]; relatedByID = [:]; castEntriesByID = [:]
        cachedTrailers = []; cachedExtras = []; cachedRelated = []; cachedCastOrder = []
        detail = nil
    }

    private func ingest(_ content: BelowFoldContent) {
        detail = content.detail
        showDetail = content.showDetail
        multiSeason = content.seasons.count > 1
        episodesByID = Dictionary(content.episodes.map { ($0.ref.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        trailersByID = Dictionary(content.trailers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        extrasByID = Dictionary(content.extras.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        relatedByID = Dictionary(content.related.map { ($0.ref.itemID, $0) }, uniquingKeysWith: { a, _ in a })

        var entries: [String: CastEntry] = [:]
        cachedCastOrder = []
        // Dedup by id: two credits can collapse to the same identifier (e.g. the
        // same name in the same role, "cast:Mike Desilets-(voice)-"). Appending
        // both would feed duplicate identifiers into the diffable snapshot and
        // trip NSDiffableDataSourceSnapshot's uniqueness assertion (RIVULET-4R).
        // First occurrence wins, keeping order and entry data consistent.
        var seenCastIDs = Set<String>()
        for d in content.directors {
            let id = "dir:\(d.id)"
            guard seenCastIDs.insert(id).inserted else { continue }
            entries[id] = CastEntry(person: d, subtitle: "Director")
            cachedCastOrder.append((id, .cast(id)))
        }
        for c in content.cast {
            let id = "cast:\(c.id)"
            guard seenCastIDs.insert(id).inserted else { continue }
            entries[id] = CastEntry(person: c, subtitle: c.role)
            cachedCastOrder.append((id, .cast(id)))
        }
        castEntriesByID = entries
        cachedEpisodes = content.episodes.map { BelowFoldItem.episode($0.ref.itemID) }
        cachedTrailers = content.trailers.map { BelowFoldItem.trailer($0.id) }
        cachedExtras = content.extras.map { BelowFoldItem.extra($0.id) }
        relatedItems = content.related
        cachedRelated = content.related.isEmpty ? [] : [BelowFoldItem.relatedShelf]
    }

    private var cachedEpisodes: [BelowFoldItem] = []
    private var cachedTrailers: [BelowFoldItem] = []
    private var cachedExtras: [BelowFoldItem] = []
    private var cachedRelated: [BelowFoldItem] = []
    /// Ordered Related items backing the shelf (index == shelf tile index).
    private var relatedItems: [MediaItem] = []
    private var cachedCastOrder: [(String, BelowFoldItem)] = []

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<BelowFoldSectionKind, BelowFoldItem>()
        sectionKinds = []
        func add(_ kind: BelowFoldSectionKind, _ items: [BelowFoldItem]) {
            snapshot.appendSections([kind]); snapshot.appendItems(items, toSection: kind); sectionKinds.append(kind)
        }
        // TV-show order, minus whatever's absent. The FIRST section (Episodes for
        // shows, Trailers for movies) is the primary peek row (gets the big peek
        // inset in makeLayout). Related is always a normal row below Trailers.
        if !cachedEpisodes.isEmpty { add(.episodes, cachedEpisodes) }
        if !cachedTrailers.isEmpty { add(.trailers, cachedTrailers) }
        if !cachedExtras.isEmpty { add(.extras, cachedExtras) }
        if !cachedRelated.isEmpty { add(.related, cachedRelated) }
        if !cachedCastOrder.isEmpty { add(.cast, cachedCastOrder.map { $0.1 }) }
        // About + Information/Languages/Accessibility — only when the full detail
        // is present (the episodes-only peek load has no detail).
        if detail != nil {
            add(.about, [.about])
            add(.info, [.info])
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        // The primary peek row is section 0 (when any content exists). Drives the
        // focus-scroll "top section" logic for episodes OR a movie's related row.
        collectionView.topSectionIndex = sectionKinds.isEmpty ? nil : 0
    }

    /// Reset scroll to the rest (peek) position — used on collapse. Rest offset
    /// is -contentInset.top (= -detailsTopY); the episodes peek at the bottom via
    /// the episodes-section top inset.
    /// Scroll the episode rail so the first episode of the given season sits at
    /// the leading edge — ATV+ jumps the rail to that season when its pill is
    /// focused. Focus stays on the pill (this only moves the orthogonal scroller).
    func scrollEpisodesToSeason(seasonRefID: String) {
        guard let epSection = sectionKinds.firstIndex(of: .episodes) else { return }
        guard let itemIdx = cachedEpisodes.firstIndex(where: {
            if case let .episode(id) = $0, let ep = episodesByID[id] {
                return ep.parentRef?.itemID == seasonRefID
            }
            return false
        }) else { return }
        scrollOrthogonalEpisodes(toItem: itemIdx, epSection: epSection, animated: true)
    }

    /// On load, position the rail at the carousel item's own episode (or, for a
    /// season, that season's first episode) and make it the initial focus target,
    /// so opening an episode/season lands on its season in view — not season 0/1.
    /// The actual positioning is done in `layoutSubviews` (instant, before the
    /// first render) so the user never sees it scroll there.
    func scrollToInitialEpisode(item: MediaItem) {
        guard let epSection = sectionKinds.firstIndex(of: .episodes) else { return }
        let targetIdx: Int?
        switch item.kind {
        case .episode:
            targetIdx = cachedEpisodes.firstIndex(where: {
                if case let .episode(id) = $0 { return id == item.ref.itemID }
                return false
            })
        case .season:
            targetIdx = cachedEpisodes.firstIndex(where: {
                if case let .episode(id) = $0, let ep = episodesByID[id] {
                    return ep.parentRef?.itemID == item.ref.itemID
                }
                return false
            })
        default:
            return
        }
        guard let idx = targetIdx, idx > 0 else { return }
        let target = IndexPath(item: idx, section: epSection)
        pendingInitialScroll = target
        // Land focus here on the first Down into the rail (else the engine focuses
        // item 0 and scrolls back, undoing this).
        pendingInitialFocus = target
        currentSeasonFirstEpisode = target
        // Position within this layout pass so the rail is already there on the
        // first render. If the orthogonal scroller isn't built yet, layoutSubviews
        // retries each pass until it is — always before the frame is shown.
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Drive the orthogonal episode scroller's contentOffset.x to a given episode.
    /// Returns false if the scroller doesn't exist yet (caller may retry).
    @discardableResult
    private func scrollOrthogonalEpisodes(toItem itemIdx: Int, epSection: Int, animated: Bool) -> Bool {
        // Remember this as the Down-from-pills focus target.
        currentSeasonFirstEpisode = IndexPath(item: itemIdx, section: epSection)

        // An orthogonal compositional section scrolls in its OWN embedded scroll
        // view, which `collectionView.scrollToItem` does not drive. Drive that
        // scroller's contentOffset.x directly.
        guard let scroller = orthogonalScrollView(forSection: epSection) else { return false }

        // The section's leading inset is the scroller's contentInset, so its
        // natural resting offset is -contentInset.left (NOT 0).
        let base = -scroller.contentInset.left
        let layout = collectionView.collectionViewLayout
        let delta: CGFloat
        if let attrTarget = layout.layoutAttributesForItem(at: IndexPath(item: itemIdx, section: epSection)),
           let attrFirst = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: epSection)) {
            delta = attrTarget.frame.minX - attrFirst.frame.minX
        } else {
            delta = CGFloat(itemIdx) * (Self.episodeWidth + 16)
        }
        let maxX = max(base, scroller.contentSize.width - scroller.bounds.width + scroller.contentInset.right)
        let clampedX = min(max(base, base + delta), maxX)
        scroller.setContentOffset(CGPoint(x: clampedX, y: scroller.contentOffset.y), animated: animated)
        return true
    }

    /// The embedded UIScrollView backing an orthogonal compositional section.
    /// Found via a currently-visible cell in that section (walk up to the nearest
    /// UIScrollView that isn't the collection view itself).
    private func orthogonalScrollView(forSection section: Int) -> UIScrollView? {
        guard let ip = collectionView.indexPathsForVisibleItems.first(where: { $0.section == section }),
              let cell = collectionView.cellForItem(at: ip) else { return nil }
        var v: UIView? = cell.superview
        while let cur = v {
            if let sv = cur as? UIScrollView, sv !== collectionView { return sv }
            v = cur.superview
        }
        return nil
    }

    func resetScroll() {
        collectionView.setContentOffset(CGPoint(x: 0, y: -Self.detailsTopY), animated: false)
    }

    /// Screen-y where the first episode lands in details (under the logo + the
    /// season-pills row, per the ATV+ reference). Also the collection's
    /// contentInset.top, so the focus engine aligns the focused episode here.
    static let detailsTopY: CGFloat = 230

    /// The `onScroll` value when the episodes sit at their details-rest (topBand)
    /// position — i.e. where the season-pills row is at its resting Y. Above this
    /// the pills scroll UP with the rail; below it (entry/collapse) they follow it
    /// down. Equals the episodes section's top inset (the carousel peek).
    var detailsRestOff: CGFloat { max(0, bounds.height - Self.episodePeek - Self.detailsTopY) }

    /// Whether focus is on the episodes (top) row vs a lower section. Drives the
    /// Up handler: episodes → pills; lower section → let the engine move up.
    var focusIsOnEpisodes: Bool { collectionView.focusedCellIsTopSection }
    /// True briefly after the episode thumb took focus (same-press guard for the
    /// thumb → season-pills lift). Covers BOTH coming up from a lower row AND
    /// coming up from the description (a within-row move the section-based guard
    /// `episodesJustTookFocus` misses).
    var episodeThumbJustTookFocus: Bool { CACurrentMediaTime() - lastThumbFocusTime < 0.06 }
    /// True while focus is on an episode description (vs a thumb). The VC uses
    /// this to redirect Left/Right to the adjacent episode's thumb.
    var episodeDescriptionFocused: Bool { collectionView.focusedViewIsEpisodeDescription }
    /// One-shot preferred-focus override: the engine focuses this episode cell's
    /// thumb on the next focus update (used for the description→adjacent-thumb
    /// redirect). Cleared by the caller after the update.
    private var armedEpisodeFocusIndexPath: IndexPath?

    /// Arm focus on the episode thumb adjacent (Left/Right) to the focused
    /// description, and reveal it in the orthogonal row. The VC then triggers the
    /// focus update. Returns false if there's no adjacent episode.
    func armAdjacentEpisodeThumb(forward: Bool) -> Bool {
        guard let epSection = sectionKinds.firstIndex(of: .episodes),
              let current = collectionView.focusedEpisodeIndexPath,
              current.section == epSection else { return false }
        let count = collectionView.numberOfItems(inSection: epSection)
        let targetItem = current.item + (forward ? 1 : -1)
        guard targetItem >= 0, targetItem < count else { return false }
        armedEpisodeFocusIndexPath = IndexPath(item: targetItem, section: epSection)
        // No manual scroll: the engine scrolls the orthogonal row to the focused
        // thumb itself (minimal scroll-to-visible). There's a slight "catch-up"
        // beat when the target was off-screen — a known polish item; a deferred
        // (non-forced) focus update may coordinate the scroll better. Revisit.
        return true
    }

    /// Clear the one-shot armed target after the focus update has run.
    func clearArmedEpisodeFocus() { armedEpisodeFocusIndexPath = nil }

    /// True briefly after focus first lands on the episodes row — used to gate the
    /// episodes→pills jump against the same-press arrival from a lower row.
    var episodesJustTookFocus: Bool { collectionView.topSectionJustTookFocus }

    /// Timed slide of the episodes UP to the details-top position. Driven by a
    /// CADisplayLink (see animateOffsetY) so scrollViewDidScroll fires per frame
    /// and the hero choreography (blur + metadata fade + logo) rides this single
    /// movement in lockstep. Completion fires at the end.
    func slideToDetailsTop(animated: Bool, completion: (() -> Void)? = nil) {
        // Scroll so the first episode lands at detailsTopY — which is the focus
        // engine's preferred position (contentInset.top == detailsTopY), so
        // handing focus in afterward causes no re-scroll bounce.
        let targetY = max(0, bounds.height - Self.episodePeek - 2 * Self.detailsTopY)
        guard animated else { setOffsetY(targetY); completion?(); return }
        animateOffsetY(to: targetY, duration: 0.6, completion: completion)
    }

    /// Reverse of slideToDetailsTop: slide the episodes back down to the hero
    /// peek rest (drives the reverse choreography). Completion fires at the end.
    func slideToHeroRest(animated: Bool, completion: (() -> Void)? = nil) {
        let targetY = -Self.detailsTopY
        guard animated else { setOffsetY(targetY); completion?(); return }
        animateOffsetY(to: targetY, duration: 0.6, completion: completion)
    }

    // MARK: - One-clock vertical scroll (CADisplayLink)

    // UIView.animate { contentOffset = } fires scrollViewDidScroll only ONCE
    // (with the final value) — verified by trace — so a hero fade riding the
    // scroll delegate would SNAP. A CADisplayLink that sets contentOffset every
    // frame fires scrollViewDidScroll per frame, so the rail slide and the hero
    // fade run on a SINGLE clock, in lockstep (the one-morph-one-clock rule).
    private var offsetLink: CADisplayLink?
    private var offsetStartY: CGFloat = 0
    private var offsetTargetY: CGFloat = 0
    private var offsetStartTime: CFTimeInterval = 0
    private var offsetDuration: CFTimeInterval = 0.6
    private var offsetCompletion: (() -> Void)?

    private func setOffsetY(_ y: CGFloat) {
        collectionView.contentOffset.y = y
    }

    private func animateOffsetY(to targetY: CGFloat, duration: CFTimeInterval, completion: (() -> Void)?) {
        // Supersede any in-flight scroll; drop its completion (don't double-fire).
        offsetLink?.invalidate()
        offsetLink = nil
        offsetCompletion = nil
        offsetStartY = collectionView.contentOffset.y
        offsetTargetY = targetY
        offsetDuration = max(0.0001, duration)
        offsetCompletion = completion
        offsetStartTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepOffset))
        link.add(to: .main, forMode: .common)
        offsetLink = link
    }

    @objc private func stepOffset(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - offsetStartTime
        let t = min(1, max(0, elapsed / offsetDuration))
        // Quadratic ease-in-out — visually matches UIView's .curveEaseInOut.
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        setOffsetY(offsetStartY + (offsetTargetY - offsetStartY) * CGFloat(eased))
        guard t >= 1 else { return }
        link.invalidate()
        offsetLink = nil
        let done = offsetCompletion
        offsetCompletion = nil
        done?()
    }

    deinit { offsetLink?.invalidate() }

    // MARK: - Season-pill → episodes focus entry

    /// The selected season's first episode, updated on each pill scroll. When the
    /// user presses Down from the season pills, focus must land on THIS episode —
    /// not the collection's remembered index path (still episode 0 / season 1),
    /// which would snap the rail back and re-select season 1.
    private var currentSeasonFirstEpisode: IndexPath?
    /// Armed (by the Down-from-pills handler) only for the synchronous focus
    /// update, so normal episode navigation still uses the remembered index path.
    var pillEntryArmed = false
    /// The carousel item's episode, positioned in `layoutSubviews` before first
    /// render so the rail opens on the right season with no visible scroll.
    private var pendingInitialScroll: IndexPath?
    /// One-shot: the episode the first Down-into-rail should focus (the carousel
    /// item's), so the engine doesn't focus item 0 and scroll the rail back.
    /// Cleared once focus lands on an episode.
    private var pendingInitialFocus: IndexPath?
    func clearPendingInitialFocus() { pendingInitialFocus = nil }

    // MARK: - UICollectionViewDelegate

    /// Episodes and trailers host their own focusable subviews (thumb +, for
    /// episodes, the description). The cell itself must be non-focusable so the
    /// focus engine targets those subviews directly — giving episodes two focus
    /// stops and trailers one (the thumb). All other sections stay whole-cell.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .episode, .trailer, .extra: return false
        default: return true
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // Related poster Select → open that item's detail page.
        if case let .related(id) = dataSource.itemIdentifier(for: indexPath),
           let item = relatedByID[id] {
            onShowRelatedDetails?(item)
        }
        // Cast / crew cell Select → open the person detail page.
        if case let .cast(id) = dataSource.itemIdentifier(for: indexPath),
           let entry = castEntriesByID[id] {
            onSelectPerson?(entry.person)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let off = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        onScroll?(max(0, off))
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        let candidate = armedEpisodeFocusIndexPath
            ?? pendingInitialFocus
            ?? (pillEntryArmed ? currentSeasonFirstEpisode : nil)
        guard let candidate else { return nil }
        return realizedFocusTarget(candidate, in: collectionView)
    }

    /// UIKit requires that this delegate return an index path whose CELL EXISTS
    /// right now — not merely a valid data-source index. Episodes live in an
    /// orthogonal scrolling section, so a target deep in the rail (say episode
    /// 22) has no cell until that part of the rail is scrolled into view, and
    /// returning it raises:
    ///
    ///     NSInternalInconsistencyException: no cell for index path {0, 21} —
    ///     the collection view's delegate must return an index path for a valid
    ///     UICollectionViewCell
    ///
    /// So: drop paths that are stale or not yet realized, and return nil to let
    /// the focus engine pick. This is a pure query — UIKit calls it mid focus
    /// update, so it must not scroll, lay out, or mutate our tracking state.
    /// Realizing the cell is the job of `pendingInitialScroll` in
    /// `layoutSubviews`, which runs before focus is handed in.
    private func realizedFocusTarget(_ indexPath: IndexPath, in collectionView: UICollectionView) -> IndexPath? {
        // Stale across a snapshot change — the item may no longer exist at all.
        guard dataSource.itemIdentifier(for: indexPath) != nil else { return nil }
        // Deep episodes live in an orthogonal rail and have no cell until that
        // stretch is scrolled in. Preferring an unrealized path is the crash.
        return collectionView.cellForItem(at: indexPath) != nil ? indexPath : nil
    }
}
