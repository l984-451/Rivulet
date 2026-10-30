// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The detail's below-fold rows: a compositional collection of horizontal sections fed by
//  BelowFoldContentLoader. Its vertical scroll drives the hero fades through `onScroll`; at
//  rest a large top inset leaves the primary row peeking at the bottom.

import UIKit

// nonisolated + Sendable: required to be diffable identifiers under the
// project's SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor (matches HomeSectionID).
nonisolated enum BelowFoldSectionKind: Hashable, Sendable {
    case episodes
    case trailers
    case extras
    case collection
    case related
    case cast
    case about
    case info
}

nonisolated enum BelowFoldItem: Hashable, Sendable {
    case episode(String)
    /// Boundary marker between seasons in the flat rail, keyed by the season
    /// ref itemID it introduces. Structural only — never a focus stop.
    case seasonDivider(String)
    case trailer(String)
    case extra(String)
    /// The whole Related row as ONE item — a ShelfRowCell hosting its own
    /// horizontal collection view, so the row matches the home/library
    /// shelves exactly (geometry, peeks, pitch-aligned landings, glide).
    case relatedShelf
    /// The collection row, hosted exactly like `.relatedShelf`.
    case collectionShelf
    case cast(String)
    case about       // single full-width card block
    case info        // single full-width columns block
}

final class BelowFoldCollectionView: UIView, UICollectionViewDelegate {

    /// The first row's FRAME peek at rest: Apple's 40 of artwork, plus the half of
    /// `focusGrowth` a lockup rests its artwork below its frame top.
    private static let episodePeek: CGFloat = 40 + MediaRowMetrics.focusGrowth / 2
    /// Where every row's content rests in the untransformed collection: under
    /// the collapsed card's metadata. The host pulls the collection left on
    /// expand, which lands it on the expanded margin. Sections measure from
    /// the collection's edges, not its safe area, which changes with the state.
    static let rowLeading: CGFloat = PreviewCarouselGeometry.collapsedChromeInset
    /// The collection is wider than the screen by that pull, so this ends a
    /// row's content on the expanded margin; rails still scroll past it.
    private static let rowTrailing: CGFloat = PreviewCarouselGeometry.expandedChromeInset
    private static let episodeWidth: CGFloat = EpisodeCell.cardWidth
    /// Spacing between episode cards (and season dividers).
    static let episodeGap: CGFloat = MediaRowMetrics.tileGap
    /// The thumb frame plus the text block below it.
    private static let episodeHeight: CGFloat = EpisodeCell.thumbHeight + 190
    private static let trailerWidth: CGFloat = EpisodeCell.cardWidth
    // The trailer frame: 410 x 278 artwork plus the focus reserve, title inside.
    private static let trailerHeight: CGFloat = EpisodeCell.trailerThumbHeight
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
    /// Related or collection-row poster Select (the trailing collection tile
    /// included) → open that item's detail page (blur-fade).
    var onShowRelatedDetails: ((MediaItem) -> Void)?
    /// Episode description Select → open the episode detail page.
    var onShowEpisodeDetails: ((MediaItem) -> Void)?
    /// Held Select on an episode → its tile menu, anchored at the thumb's window frame.
    var onEpisodeMenu: ((MediaItem, CGRect) -> Void)?
    /// Cast / crew cell Select → open the person detail page.
    var onSelectPerson: ((MediaPerson) -> Void)?
    /// Selecting the About cards opens the matching popup (synopsis / advisory).
    var onSelectSynopsis: ((MediaItemDetail) -> Void)?
    var onSelectAdvisory: ((ContentAdvisory) -> Void)?
    /// The loader's seasons, published as soon as they land, with the index of
    /// the season it resolved as selected. The container builds the season pills
    /// from this instead of fetching `/children` a second time of its own.
    var onSeasonsLoaded: (([MediaItem], Int) -> Void)?

    /// Which sub-target of the focused episode card is focused (thumb vs
    /// description). Set from the cell's focus reporting.
    private(set) var focusedEpisodeKind: EpisodeFocusKind = .none
    /// When the episode thumb last took focus; see `episodeThumbJustTookFocus`.
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
    /// True while `configureEpisodesOnly` is fetching; `onEpisodesApplied`
    /// fires once when its snapshot is in, so the host's fade waits for content.
    private(set) var isLoadingEpisodes = false
    var onEpisodesApplied: (() -> Void)?

    private var episodesByID: [String: MediaItem] = [:]
    private var trailersByID: [String: BelowFoldTrailer] = [:]
    private var extrasByID: [String: BelowFoldTrailer] = [:]
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
        // We drive vertical scroll, so the engine's centring focus-scroll animator stays off.
        collectionView.isScrollEnabled = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.showsVerticalScrollIndicator = false
        // Off: it beats the preferred index path, so Down from a pill would land on season 1.
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.register(EpisodeCollectionCell.self, forCellWithReuseIdentifier: EpisodeCollectionCell.reuseID)
        collectionView.register(SeasonDividerCell.self, forCellWithReuseIdentifier: SeasonDividerCell.reuseID)
        collectionView.register(TrailerCollectionCell.self, forCellWithReuseIdentifier: TrailerCollectionCell.reuseID)
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

    /// The collection, or when restoring a shelf row (Related) the host cell itself, whose
    /// armed `preferredFocusEnvironments` lands the tile. Its index path would restart at item 0.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let shelf = armedShelfRestoreCell { return [shelf] }
        return [collectionView]
    }

    /// Shelf-host cell armed for focus restore, consumed by the next focus update.
    private weak var armedShelfRestoreCell: ShelfRowCell?

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
        let layout = UICollectionViewCompositionalLayout { [weak self] index, env in
            guard let self, self.sectionKinds.indices.contains(index) else { return nil }
            // The first section's large top inset is both the peek and the scroll
            // distance the Down slide and hero fades ride on.
            let isPrimary = (index == 0)
            let peek = max(0, self.bounds.height - Self.episodePeek - Self.detailsTopY)
            switch self.sectionKinds[index] {
            // Episodes: LEFT-aligned (ATV+), first card at the metadata inset.
            // The collection's small contentInset.top (= detailsTopY)
            // lets the focus engine land them at ~detailsTopY in details.
            case .episodes:
                return self.episodesRailSection(
                    topInset: isPrimary ? peek : 0,
                    sectionBottomInset: 36
                )
            case .trailers:
                return self.shelfSection(
                    itemW: Self.trailerWidth,
                    itemH: Self.trailerHeight,
                    gap: MediaRowMetrics.tileGap,
                    header: !isPrimary,
                    topInset: isPrimary ? peek : 0,
                    headerTopInset: 8,
                    headerHeight: 44,
                    // Measured on device, tvOS 27: 105 from card bottom to the next header baseline.
                    sectionBottomInset: 91.5
                )
            case .extras:
                return self.shelfSection(
                    itemW: Self.trailerWidth,
                    itemH: Self.trailerHeight,
                    gap: MediaRowMetrics.tileGap,
                    header: !isPrimary,
                    topInset: isPrimary ? peek : 0,
                    headerTopInset: 8,
                    headerHeight: 44,
                    // Measured on device, tvOS 27: 105 from card bottom to the next header baseline.
                    sectionBottomInset: 91.5
                )
            case .related, .collection:
                // As the primary row (also the collection row's case), lift by the header
                // and 8 pt pad so the 40 pt peek strip shows posters, not the title.
                let relatedLift = ShelfRowCell.headerHeight + 8
                return self.homeShelfHostSection(
                    topInset: isPrimary ? max(0, peek - relatedLift) : 0,
                    sectionBottomInset: isPrimary ? 36 : 56
                )
            case .cast:
                return self.shelfSection(
                    itemW: Self.castWidth,
                    itemH: 355,
                    gap: MediaRowMetrics.tileGap,   // six across on the grid, the seventh peeking
                    header: true,
                    // Primary on a title with no extras or related: same peek,
                    // less the header gap, so the strip is the cast row.
                    topInset: isPrimary ? max(0, peek - 16) : 0,
                    // The header stays put; the circles rest 41.5 below its baseline.
                    headerTopInset: 46,
                    headerHeight: 72,
                    headerBaseline: BelowFoldSectionHeader.castBaseline
                )
            case .about:
                return self.fullWidthSection(height: AboutCollectionCell.height(for: self.showDetail ?? self.detail),
                                             topInset: isPrimary ? peek : 0)
            case .info:
                // Sized to its rows, so a short title leaves no empty band below them.
                let columnsWidth = env.container.contentSize.width - Self.rowLeading - Self.rowTrailing
                let height = self.detail.map { InfoColumnsCollectionCell.height(for: $0, columnsWidth: columnsWidth) }
                return self.fullWidthSection(height: height ?? 605, band: true)
            }
        }
        return layout
    }

    /// One full-width ShelfRowCell, not an orthogonal section, so the row scrolls and lands
    /// exactly like Home's. Alignment happens inside the cell via panelOvershoot.
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
        section.contentInsetsReference = .none
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
    private func fullWidthSection(height: CGFloat, band: Bool = false,
                                  topInset: CGFloat = 0) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsetsReference = .none
        section.contentInsets = .init(top: 24 + topInset, leading: Self.rowLeading, bottom: 56,
                                      trailing: Self.rowTrailing)
        if band {
            // The cell paints the band itself, so it spans the whole collection
            // width and insets its own content.
            section.contentInsets = .zero
        }
        return section
    }

    /// A custom group, since episode cards and season dividers differ in width. Frames come
    /// eagerly from `cachedEpisodes`, so season scrolls and landings read exact attributes.
    private func episodesRailSection(topInset: CGFloat, sectionBottomInset: CGFloat) -> NSCollectionLayoutSection {
        let gap = Self.episodeGap
        var frames: [CGRect] = []
        var x: CGFloat = 0
        for railItem in cachedEpisodes {
            let w: CGFloat
            if case .seasonDivider = railItem { w = SeasonDividerCell.cardWidth } else { w = Self.episodeWidth }
            frames.append(CGRect(x: x, y: 0, width: w, height: Self.episodeHeight))
            x += w + gap
        }
        let total = max(x - gap, 1)
        let group = NSCollectionLayoutGroup.custom(layoutSize: .init(
            widthDimension: .absolute(total), heightDimension: .absolute(Self.episodeHeight))
        ) { _ in
            frames.map { NSCollectionLayoutGroupCustomItem(frame: $0) }
        }
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.contentInsetsReference = .none
        section.contentInsets = .init(
            top: topInset,
            leading: Self.rowLeading,
            bottom: sectionBottomInset,
            trailing: Self.rowTrailing
        )
        return section
    }

    private func shelfSection(
        itemW: CGFloat,
        itemH: CGFloat,
        gap: CGFloat,
        header: Bool,
        topInset: CGFloat = 0,
        headerTopInset: CGFloat = 16,
        headerHeight: CGFloat = 44,
        sectionBottomInset: CGFloat = 56,
        headerBaseline: CGFloat = BelowFoldSectionHeader.cardBaseline
    ) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .absolute(itemW), heightDimension: .absolute(itemH)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .absolute(itemW), heightDimension: .absolute(itemH)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = gap
        section.contentInsetsReference = .none
        section.contentInsets = .init(
            top: (header ? headerTopInset : 0) + topInset,
            leading: Self.rowLeading,
            bottom: sectionBottomInset,
            trailing: Self.rowTrailing
        )
        if header {
            let headerItem = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(headerHeight)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top,
                // The section's top inset does not move its header. Offset, the
                // header sits above that point and reserves no height of its own.
                absoluteOffset: CGPoint(x: 0, y: topInset))
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
                    cell.onLongPress = { [weak self] frame in self?.onEpisodeMenu?(ep, frame) }
                    cell.onFocusKind = { [weak self] kind in
                        guard let self else { return }
                        if kind == .thumb { self.lastThumbFocusTime = CACurrentMediaTime() }
                        self.focusedEpisodeKind = kind
                    }
                }
                return cell
            case .seasonDivider(let seasonID):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: SeasonDividerCell.reuseID, for: indexPath) as! SeasonDividerCell
                cell.configure(label: self.railDividerLabels[seasonID] ?? "·")
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
            case .collectionShelf:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
                let row = self.collectionRow
                self.configurePosterShelf(cell, section: .collection, title: row?.title ?? "",
                                          items: row?.members ?? [], trailing: row?.collection)
                return cell
            case .relatedShelf:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
                self.configurePosterShelf(cell, section: .related, title: "Related",
                                          items: self.relatedItems, trailing: nil)
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
            case .cast:    header.configure(title: "Cast & Crew", baseline: BelowFoldSectionHeader.castBaseline)
            case .episodes, .collection, .about, .info: header.configure(title: "")
            }
            return header
        }
    }

    /// Both poster shelves (Collection, Related); every tile opens through `onShowRelatedDetails`.
    /// The content token hashes ratingKeys and watch state, so a refresh reloads only when a glyph moved.
    private func configurePosterShelf(_ cell: ShelfRowCell,
                                      section: BelowFoldSectionKind,
                                      title: String,
                                      items: [MediaItem],
                                      trailing: MediaItem?) {
        let tiles = items + (trailing.map { [$0] } ?? [])
        var hasher = Hasher()
        for tile in tiles {
            hasher.combine(tile.ref.itemID)
            hasher.combine(tile.userState.isPlayed)
            hasher.combine(tile.userState.viewOffset)
        }
        cell.cellProvider = { innerCV, ip in
            let poster = innerCV.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: ip) as! PosterCell
            if ip.item < tiles.count { poster.configure(item: tiles[ip.item]) }
            return poster
        }
        cell.onSelect = { [weak self] idx in
            guard let self, idx < tiles.count else { return }
            self.onShowRelatedDetails?(tiles[idx])
        }
        cell.onWillDisplayItem = nil
        cell.onLongPressItem = nil
        cell.onOffsetChanged = { [weak self] offset in self?.shelfOffsets[section] = offset }
        // Rests under the collapsed metadata; the expand pull lands it on the margin.
        cell.headerTitle = title
        cell.configure(
            kind: .poster,
            realCount: tiles.count,
            hasSkeleton: false,
            contentToken: hasher.finalize(),
            initialOffset: shelfOffsets[section] ?? 0,
            panelOvershoot: (left: Self.rowLeading - MediaRowMetrics.rowLeading, right: 0)
        )
    }

    // MARK: - Configure (fetch + populate)

    /// Load + render the below-fold for `item`. `detail` (if the chrome already
    /// fetched it) supplies cast without a second round-trip.
    func configure(item: MediaItem, detail: MediaItemDetail?) {
        loadToken &+= 1
        let token = loadToken
        configuredItem = item
        isLoadingEpisodes = false
        Task { [weak self] in
            guard let self else { return }
            let content = await self.loader.load(for: item, detail: detail)
            guard self.loadToken == token else { return }
            self.ingest(content)
            self.applySnapshot()
            self.scrollToInitialEpisode(item: item)
            self.loadRatings(token: token)
            // Chained after ingest, which would otherwise overwrite it with the partial detail.
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

    /// Merges the ratings Worker's scores into the About card's detail. The
    /// provider's own scores win per source.
    private func loadRatings(token: UInt64) {
        guard let target = showDetail ?? detail else { return }
        Task { [weak self] in
            let extra = await RatingsClient.shared.ratings(for: target)
            guard let self, self.loadToken == token, !extra.isEmpty else { return }
            if let current = self.showDetail?.ratings {
                self.showDetail?.ratings = MediaRating.ordered(current + extra)
            } else if let current = self.detail?.ratings {
                self.detail?.ratings = MediaRating.ordered(current + extra)
            }
            var snapshot = self.dataSource.snapshot()
            guard snapshot.sectionIdentifiers.contains(.about) else { return }
            snapshot.reconfigureItems([.about])
            await self.dataSource.apply(snapshot, animatingDifferences: false)
            // Branded source marks wrap to their card width. Newly added
            // sources can increase the About section's measured height.
            self.collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    /// Episodes-only load for the carousel-stable peek (per page) — skips the
    /// heavier cast/related fetch until expand.
    func configureEpisodesOnly(item: MediaItem) {
        loadToken &+= 1
        let token = loadToken
        // A different item: empty the rail now, so the previous show's
        // episodes never sit under this card while the fetch runs.
        let itemChanged = configuredItem?.ref != item.ref
        configuredItem = item
        isLoadingEpisodes = false
        let showRef: MediaItemRef?
        switch item.kind {
        case .show: showRef = item.ref
        case .episode: showRef = item.grandparentRef
        default: showRef = nil
        }
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else {
            ingestEpisodesOnly([]); applySnapshot(); return
        }
        if itemChanged { ingestEpisodesOnly([]); applySnapshot() }
        // A movie fetches nothing here, so its fade does not wait.
        isLoadingEpisodes = showRef != nil || item.kind == .season
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
            self.isLoadingEpisodes = false
            // Realize the cells now, so the fade starts over a built rail.
            self.collectionView.layoutIfNeeded()
            let applied = self.onEpisodesApplied
            self.onEpisodesApplied = nil
            applied?()
        }
    }

    /// Re-reads the rail's watch state (#228) and reconfigures the same identifiers in place.
    /// A re-apply is an empty diff and never redraws; reconfiguring keeps focus.
    func refreshWatchState() {
        guard let item = configuredItem else { return }
        let showRef: MediaItemRef?
        switch item.kind {
        case .show: showRef = item.ref
        case .episode: showRef = item.grandparentRef
        default: showRef = nil
        }
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return }
        // Its own token, so it cannot cancel a `configure`; landing checks both.
        refreshToken &+= 1
        let refresh = refreshToken
        let load = loadToken
        // Nothing to repaint in the carousel-stable episodes-only phase
        // (`ingestEpisodesOnly` clears both), so skip /related and the
        // collection fetch. Read before the await: the stores can change under it.
        let hasShelves = collectionRow != nil || !cachedRelated.isEmpty
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
            guard self.refreshToken == refresh, self.loadToken == load else { return }
            if !eps.isEmpty { self.applyRefreshedEpisodes(eps) }
            // Collection and Related tiles carry watch glyphs too. Same call
            // and same kinds as the loader's collection row; it runs after the
            // rail repaint so the rail never waits on a second GET.
            guard hasShelves, item.kind == .movie || item.kind == .show,
                  let fresh = try? await provider.related(for: item.ref, kind: item.kind),
                  self.refreshToken == refresh, self.loadToken == load else { return }
            self.applyRefreshedShelves(fresh)
        }
    }

    private var refreshToken: UInt64 = 0

    /// Reconfigures the two shelf cells in place with refreshed items; only watch state is news.
    // ponytail: a refresh never adds or removes a row, so a collection or
    // Related row that appears or empties between load and refresh waits for
    // the next open; insert/delete with a focus hand-off if that ever matters.
    private func applyRefreshedShelves(_ fresh: RelatedContent) {
        var snapshot = dataSource.snapshot()
        let present = snapshot.itemIdentifiers
        var targets: [BelowFoldItem] = []
        if present.contains(.collectionShelf), let row = collectionRow,
           let members = fresh.collection?.members, !members.isEmpty {
            collectionRow = CollectionRow(title: row.title, members: members, collection: row.collection)
            targets.append(.collectionShelf)
        }
        if present.contains(.relatedShelf), !fresh.items.isEmpty {
            relatedItems = fresh.items
            targets.append(.relatedShelf)
        }
        guard !targets.isEmpty else { return }
        snapshot.reconfigureItems(targets)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

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
        cachedEpisodes = buildRailItems(from: episodes)
        // Cast/related/about are loaded only on expand.
        trailersByID = [:]; extrasByID = [:]; castEntriesByID = [:]
        cachedTrailers = []; cachedExtras = []; cachedRelated = []; cachedCastOrder = []
        collectionRow = nil; shelfOffsets = [:]
        detail = nil
    }

    private func ingest(_ content: BelowFoldContent) {
        detail = content.detail
        showDetail = content.showDetail
        multiSeason = content.seasons.count > 1
        episodesByID = Dictionary(content.episodes.map { ($0.ref.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        trailersByID = Dictionary(content.trailers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        extrasByID = Dictionary(content.extras.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var entries: [String: CastEntry] = [:]
        cachedCastOrder = []
        // Two credits can share an identifier, which trips the snapshot's uniqueness
        // assertion (RIVULET-4R). First occurrence wins.
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
        cachedEpisodes = buildRailItems(from: content.episodes)
        cachedTrailers = content.trailers.map { BelowFoldItem.trailer($0.id) }
        cachedExtras = content.extras.map { BelowFoldItem.extra($0.id) }
        relatedItems = content.related
        cachedRelated = content.related.isEmpty ? [] : [BelowFoldItem.relatedShelf]
        collectionRow = content.collection
        shelfOffsets = [:]

        // Last, so a handler reading back sees consistent state. The loader picked the season.
        let selectedSeasonIndex = content.selectedSeason
            .flatMap { sel in content.seasons.firstIndex(where: { $0.ref.itemID == sel.ref.itemID }) } ?? 0
        onSeasonsLoaded?(content.seasons, selectedSeasonIndex)
    }

    /// Build the flat rail: the episodes, with a season divider inserted at each
    /// boundary. A single-season rail gets none — the divider marks a
    /// transition, and with one season there is nothing to transition from.
    private func buildRailItems(from episodes: [MediaItem]) -> [BelowFoldItem] {
        let seasonIDs = Set(episodes.compactMap { $0.parentRef?.itemID })
        guard seasonIDs.count > 1 else {
            railDividerLabels = [:]
            return episodes.map { .episode($0.ref.itemID) }
        }
        var items: [BelowFoldItem] = []
        var labels: [String: String] = [:]
        var prevSeasonID: String?
        var seen: Set<String> = []
        for ep in episodes {
            if let sid = ep.parentRef?.itemID {
                if let prev = prevSeasonID, prev != sid, !seen.contains(sid) {
                    labels[sid] = Self.dividerLabel(for: ep)
                    items.append(.seasonDivider(sid))
                    seen.insert(sid)
                }
                prevSeasonID = sid
            }
            items.append(.episode(ep.ref.itemID))
        }
        railDividerLabels = labels
        return items
    }

    private static func dividerLabel(for episode: MediaItem) -> String {
        guard let n = episode.seasonNumber else { return "·" }
        return n == 0 ? "SP" : "S\(n)"
    }

    /// season ref itemID → chip label ("S3" / "SP"), for the divider cells.
    private var railDividerLabels: [String: String] = [:]

    /// The flat rail's items: episodes plus any season dividers.
    private var cachedEpisodes: [BelowFoldItem] = []
    private var cachedTrailers: [BelowFoldItem] = []
    private var cachedExtras: [BelowFoldItem] = []
    private var cachedRelated: [BelowFoldItem] = []
    /// Ordered Related items backing the shelf (index == shelf tile index).
    private var relatedItems: [MediaItem] = []
    /// The collection row (Plex's hub title, members, optional trailing
    /// collection tile). nil or no members: no row.
    private var collectionRow: CollectionRow?
    /// Each poster shelf's resting horizontal offset, so a content reload or
    /// a reused host cell does not throw the row back to its first tile.
    private var shelfOffsets: [BelowFoldSectionKind: CGFloat] = [:]
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
        if let row = collectionRow, !row.members.isEmpty { add(.collection, [.collectionShelf]) }
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

    /// Scrolls the rail to the season's first episode, as Apple's does on pill focus. Focus stays put.
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

    /// Targets the item's own episode (a season's first), positioned in `layoutSubviews` before first render.
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
            // Fallback for when the attributes aren't built yet. It cannot assume
            // a fixed pitch any more: the rail mixes episode cards with slimmer
            // season dividers, so sum the actual widths up to the target.
            delta = cachedEpisodes.prefix(itemIdx).reduce(CGFloat(0)) { acc, railItem in
                if case .seasonDivider = railItem { return acc + SeasonDividerCell.cardWidth + Self.episodeGap }
                return acc + Self.episodeWidth + Self.episodeGap
            }
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
    /// Artwork rests 96 under the pill top, and a card frame carries half the focus growth above it.
    static let detailsTopY: CGFloat = ExpandedDetailContainerView.seasonPillTop + 96 - MediaRowMetrics.focusGrowth / 2

    /// The `onScroll` value at the details rest, where the pills sit at their resting Y.
    var detailsRestOff: CGFloat { max(0, bounds.height - Self.episodePeek - Self.detailsTopY) }

    /// Whether focus is on the episodes (top) row vs a lower section. Drives the
    /// Up handler: episodes → pills; lower section → let the engine move up.
    var focusIsOnEpisodes: Bool { collectionView.focusedCellIsTopSection }
    /// Same-press guard for the thumb-to-pills lift; also covers description to thumb,
    /// which `episodesJustTookFocus` misses.
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
        // Step OVER season dividers. They occupy rail indices but are not focus
        // stops, so a bare ±1 would arm focus on one and the update would land
        // nowhere.
        func isDivider(_ i: Int) -> Bool {
            guard i >= 0, i < cachedEpisodes.count else { return false }
            if case .seasonDivider = cachedEpisodes[i] { return true }
            return false
        }
        var targetItem = current.item + (forward ? 1 : -1)
        while isDivider(targetItem) { targetItem += forward ? 1 : -1 }
        guard targetItem >= 0, targetItem < count else { return false }
        armedEpisodeFocusIndexPath = IndexPath(item: targetItem, section: epSection)
        // The engine scrolls the row; an off-screen target shows a slight catch-up beat.
        return true
    }

    /// Clear the one-shot armed target after the focus update has run.
    func clearArmedEpisodeFocus() { armedEpisodeFocusIndexPath = nil }

    /// True briefly after focus first lands on the episodes row — used to gate the
    /// episodes→pills jump against the same-press arrival from a lower row.
    var episodesJustTookFocus: Bool { collectionView.topSectionJustTookFocus }

    /// Slides the episodes up to the details top on the display link (see `offsetLink`).
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

    // UIView.animate on contentOffset fires scrollViewDidScroll once (traced), so the
    // hero fade would snap. Setting it per frame keeps the slide and fade on one clock.
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

    /// Where Down from the pills lands, updated on each pill scroll.
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

    /// Episode and trailer cells are unfocusable so the engine targets their thumb
    /// (and an episode's description) directly.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .episode, .trailer, .extra: return false
        // Same answer for a different reason: the others defer to focusable
        // subviews, the divider has none and is never a focus stop at all.
        case .seasonDivider: return false
        // The footer's three columns are the focus stops, not the cell.
        case .info: return false
        default: return true
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
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

    /// Puts a shelf row (Related) back on its tile and arms it, before the focus update
    /// resolves; `indexPathForPreferredFocusedView` is a pure query and cannot.
    func restoreShelfRowFocusIfNeeded(requestingFocus: Bool = true) {
        // The path names the row; the tile is the row's `lastFocusedItemIndex`. Do not pick
        // any shelf with a tile index: a stale one survives until `prepareForReuse`.
        guard let path = collectionView.lastFocusedIndexPath,
              let shelf = collectionView.cellForItem(at: path) as? ShelfRowCell,
              let item = shelf.lastFocusedItemIndex else { return }
        // The row's target cell may not be realized yet (the trace showed
        // cellRealized=false), and prepareFocusRestore silently no-ops when it
        // can't find the cell. Lay the collection out first so the tile exists.
        collectionView.layoutIfNeeded()
        // Position the row's horizontal window and arm the tile...
        if requestingFocus {
            shelf.prepareFocusRestore(on: item)
        } else {
            shelf.armFocusRestore(on: item)
        }
        // ...and route the pending focus update INTO this cell, so the engine
        // asks the row which tile it wants instead of picking the first
        // focusable cell in the whole collection (the primary row).
        armedShelfRestoreCell = shelf
        // Vertical position is NOT set here on purpose: the collection's own
        // didUpdateFocus drives that off the newly focused cell, and adding a
        // second scroll driver here would fight it mid-flight.
    }

    /// Clear the one-shot shelf restore target once focus has resolved.
    func clearArmedShelfRestore() { armedShelfRestoreCell = nil }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        // One-shot targets first; `lastFocusedIndexPath` is the after-modal fallback.
        let candidate = armedEpisodeFocusIndexPath
            ?? pendingInitialFocus
            ?? (pillEntryArmed ? currentSeasonFirstEpisode : nil)
            ?? self.collectionView.lastFocusedIndexPath
        guard let candidate else { return nil }
        return realizedFocusTarget(candidate, in: collectionView)
    }

    /// Nil unless the path's cell exists now: an unrealized one throws
    /// NSInternalInconsistencyException. Called mid-update, so it must not scroll or mutate state.
    private func realizedFocusTarget(_ indexPath: IndexPath, in collectionView: UICollectionView) -> IndexPath? {
        // Stale across a snapshot change — the item may no longer exist at all.
        guard dataSource.itemIdentifier(for: indexPath) != nil else { return nil }
        // Deep episodes live in an orthogonal rail and have no cell until that
        // stretch is scrolled in. Preferring an unrealized path is the crash.
        guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }

        // A shelf row's path would restart its tiles at item 0;
        // `restoreShelfRowFocusIfNeeded` restores it instead.
        if cell is ShelfRowCell { return nil }
        return indexPath
    }
}
