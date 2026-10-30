// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Full-width cells for `.search` mode: SearchRecentsCell (the empty-query "Recently Searched" row,
// #292) and SearchStateCell (searching, error, no results). Both are unfocusable containers; their
// FocusableActionButtons take focus. `.searchPrompt` hosts the recents and is blank with none.

import UIKit

// MARK: - Recently Searched

@MainActor
final class SearchRecentsCell: UICollectionViewCell {
    static let reuseID = "SearchRecentsCell"

    var onRecentSelected: ((MediaItem) -> Void)?

    /// The Apple TV app's recent-search card. Its corner radius is our own.
    private enum Metrics {
        static let cardWidth: CGFloat = MediaRowMetrics.gridWidth(columns: 3)
        static let cardHeight: CGFloat = 170   // card 560x170, measured on device (tvOS 27)
        static let cardSpacing: CGFloat = MediaRowMetrics.tileGap
        /// Poster inset inside the card. The poster is the card's full height
        /// minus this top and bottom, at the 2:3 poster ratio.
        static let posterInset: CGFloat = 20
        static let posterHeight: CGFloat = cardHeight - posterInset * 2
        static let posterWidth: CGFloat = (cardHeight - posterInset * 2) * 2 / 3
        static let posterToText: CGFloat = 20
        static let cardRadius: CGFloat = 28
        static let posterRadius: CGFloat = 9
        /// Gap below the keyboard's separator: the search controller leaves ~43pt, this adds the rest of
        /// the Apple TV app's ~57pt. The only top spacing; `contentInset.top` is 0 in search mode.
        static let topPadding: CGFloat = 17
        static let headerFont = UIFont.systemFont(ofSize: 31, weight: .semibold)
        /// Header baseline to card top is 21.5, measured on device (tvOS 27).
        static let headerToRow: CGFloat = 21.5 + headerFont.descender
    }

    private let headerLabel = UILabel()
    private let cardScroll = UIScrollView()
    private let cardStack = UIStackView()
    /// One per visible card, cancelled on reconfigure/reuse.
    private var artworkTasks: [Task<Void, Never>] = []
    private var recentItems: [MediaItem] = []

    /// The focused card's item and window frame, for its long-press menu.
    var focusedRecent: (item: MediaItem, frame: CGRect)? {
        guard let index = cardStack.arrangedSubviews.firstIndex(where: \.isFocused),
              let item = recentItems[safe: index] else { return nil }
        let card = cardStack.arrangedSubviews[index]
        return (item, card.convert(card.bounds, to: nil))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        backgroundColor = .clear

        // Matches the shelf row headers (ShelfRowCell) so Search reads as the
        // same page as Home, not a separate design.
        headerLabel.text = "Recently Searched"
        headerLabel.font = Metrics.headerFont
        headerLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        cardStack.axis = .horizontal
        cardStack.spacing = Metrics.cardSpacing
        cardStack.alignment = .center
        cardStack.translatesAutoresizingMaskIntoConstraints = false

        // clipsToBounds off so the focused card's scale is not cut off at the
        // scroller's edges.
        cardScroll.showsHorizontalScrollIndicator = false
        // The stack carries the margin; the safe area would add 80 more.
        cardScroll.contentInsetAdjustmentBehavior = .never
        cardScroll.clipsToBounds = false
        cardScroll.addSubview(cardStack)
        cardScroll.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(headerLabel)
        contentView.addSubview(cardScroll)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(
                equalTo: contentView.topAnchor, constant: Metrics.topPadding),
            headerLabel.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: MediaRowMetrics.rowLeading),

            // Full-bleed scroller: cards scroll past both screen edges, and the
            // row's left margin comes from the stack's own leading inset, the
            // way the shelf rows do it.
            cardScroll.topAnchor.constraint(
                equalTo: headerLabel.bottomAnchor, constant: Metrics.headerToRow),
            cardScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cardScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cardScroll.heightAnchor.constraint(equalToConstant: Metrics.cardHeight),
            cardScroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40),

            cardStack.leadingAnchor.constraint(
                equalTo: cardScroll.contentLayoutGuide.leadingAnchor,
                constant: MediaRowMetrics.rowLeading),
            cardStack.trailingAnchor.constraint(
                equalTo: cardScroll.contentLayoutGuide.trailingAnchor,
                constant: -MediaRowMetrics.rowLeading),
            cardStack.centerYAnchor.constraint(equalTo: cardScroll.frameLayoutGuide.centerYAnchor),
            cardScroll.contentLayoutGuide.heightAnchor.constraint(
                equalTo: cardScroll.frameLayoutGuide.heightAnchor)
        ])
    }

    /// The cell is the collection view's focus item, but it is a big empty area
    /// and should never hold focus itself — redirect straight into the cards.
    /// (A collection view enumerates focus items as CELLS, so a non-focusable
    /// cell would hide the cards from the engine entirely.)
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        cardScroll.isHidden ? super.preferredFocusEnvironments : cardStack.arrangedSubviews
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelArtwork()
    }

    private func cancelArtwork() {
        artworkTasks.forEach { $0.cancel() }
        artworkTasks.removeAll()
    }

    func configure(recentItems: [MediaItem]) {
        cancelArtwork()
        self.recentItems = recentItems
        cardStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hasRecents = !recentItems.isEmpty
        headerLabel.isHidden = !hasRecents
        cardScroll.isHidden = !hasRecents
        guard hasRecents else { return }

        for item in recentItems {
            let (card, poster) = Self.makeCard(for: item)
            card.onPrimaryAction = { [weak self] in self?.onRecentSelected?(item) }
            cardStack.addArrangedSubview(card)
            guard let url = item.artwork.poster else { continue }
            // @MainActor class, so the task inherits the main actor and the
            // assignment needs no hop. Cancelled on reuse via `artworkTasks`.
            artworkTasks.append(Task { [weak poster] in
                let image = await ImageCacheManager.shared.image(for: url)
                guard !Task.isCancelled else { return }
                poster?.image = image
            })
        }
        cardScroll.layoutIfNeeded()
    }

    /// One Recently Searched card: poster, title, "Movie · 1977". `.glass` focus, since a white
    /// inversion under a colour poster reads as a bug. Returns the poster view to fill async.
    private static func makeCard(for item: MediaItem) -> (FocusableActionButton, UIImageView) {
        let button = FocusableActionButton()
        button.focusStyle = .glass
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer.cornerRadius = Metrics.cardRadius

        let poster = UIImageView()
        poster.contentMode = .scaleAspectFill
        poster.clipsToBounds = true
        poster.layer.cornerRadius = Metrics.posterRadius
        poster.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        poster.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = item.title
        title.font = .preferredFont(forTextStyle: .body)
        title.textColor = .white
        title.numberOfLines = 2
        title.lineBreakMode = .byTruncatingTail

        let subtitle = UILabel()
        subtitle.text = subtitleText(for: item)
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = UIColor.white.withAlphaComponent(0.5)
        subtitle.numberOfLines = 2
        subtitle.lineBreakMode = .byTruncatingTail

        let text = UIStackView(arrangedSubviews: [title, subtitle])
        text.axis = .vertical
        text.spacing = 6
        text.alignment = .leading
        text.isUserInteractionEnabled = false
        text.translatesAutoresizingMaskIntoConstraints = false

        button.addSubview(poster)
        button.addSubview(text)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Metrics.cardWidth),
            button.heightAnchor.constraint(equalToConstant: Metrics.cardHeight),

            poster.leadingAnchor.constraint(
                equalTo: button.leadingAnchor, constant: Metrics.posterInset),
            poster.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            poster.widthAnchor.constraint(equalToConstant: Metrics.posterWidth),
            poster.heightAnchor.constraint(equalToConstant: Metrics.posterHeight),

            text.leadingAnchor.constraint(
                equalTo: poster.trailingAnchor, constant: Metrics.posterToText),
            text.trailingAnchor.constraint(
                lessThanOrEqualTo: button.trailingAnchor, constant: -Metrics.posterInset),
            text.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])

        return (button, poster)
    }

    /// "Movie · 1977" / "TV Show". Apple puts a genre in the middle slot;
    /// `MediaItem` carries no genre, and fetching one per card would be a
    /// metadata round trip per recent, so the kind and year are the whole line.
    private static func subtitleText(for item: MediaItem) -> String {
        var parts: [String] = []
        switch item.kind {
        case .movie: parts.append("Movie")
        case .show: parts.append("TV Show")
        case .season: parts.append("Season")
        case .episode: parts.append("Episode")
        case .collection: parts.append("Collection")
        case .playlist: parts.append("Playlist")
        case .person, .unknown: break
        }
        if let year = item.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Searching / error / no-results states

@MainActor
final class SearchStateCell: UICollectionViewCell {
    static let reuseID = "SearchStateCell"

    enum State {
        case searching
        case error(message: String)
        case noResults
        case noResultsWithRequests

        /// Only the error state renders Try Again, so only it is worth making
        /// the cell focusable for.
        var hasFocusableAction: Bool {
            switch self {
            case .error, .noResultsWithRequests: return true
            default: return false
            }
        }
    }

    var onRetry: (() -> Void)?
    var onRequests: (() -> Void)?

    private let spinner = UIActivityIndicatorView(style: .large)
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let retryButton = FocusableActionButton()
    private let retryLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        backgroundColor = .clear

        spinner.color = .white

        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit

        titleLabel.font = .systemFont(ofSize: 48, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center

        messageLabel.font = .systemFont(ofSize: 25, weight: .regular)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = 520

        retryLabel.text = "Try Again"
        retryLabel.font = .systemFont(ofSize: 26, weight: .medium)
        retryLabel.textColor = .white
        retryLabel.translatesAutoresizingMaskIntoConstraints = false
        retryButton.layer.cornerRadius = 16
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.addSubview(retryLabel)
        retryButton.invertOnFocus = [retryLabel]
        retryButton.onPrimaryAction = { [weak self] in self?.onRetry?() }
        NSLayoutConstraint.activate([
            retryLabel.leadingAnchor.constraint(equalTo: retryButton.leadingAnchor, constant: 32),
            retryLabel.trailingAnchor.constraint(equalTo: retryButton.trailingAnchor, constant: -32),
            retryLabel.topAnchor.constraint(equalTo: retryButton.topAnchor, constant: 18),
            retryLabel.bottomAnchor.constraint(equalTo: retryButton.bottomAnchor, constant: -18)
        ])

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(retryButton)
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 140),
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40)
        ])
    }

    /// Same redirect as `SearchRecentsCell`: the cell is the focus item the
    /// collection view offers, Try Again is what should actually take focus.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        retryButton.isHidden ? super.preferredFocusEnvironments : [retryButton]
    }

    func configure(state: State) {
        switch state {
        case .searching:
            spinner.isHidden = false
            spinner.startAnimating()
            iconView.isHidden = true
            titleLabel.text = "Searching"
            messageLabel.isHidden = true
            retryButton.isHidden = true
        case .error:
            spinner.stopAnimating()
            spinner.isHidden = true
            iconView.isHidden = false
            iconView.image = UIImage(systemName: "exclamationmark.triangle")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 48, weight: .light))
            // The Apple TV app's wording.
            titleLabel.text = "Search Not Available"
            messageLabel.isHidden = false
            messageLabel.text = "This request wasn’t completed. Wait a moment and try again."
            retryLabel.text = "Try Again"
            retryButton.onPrimaryAction = { [weak self] in self?.onRetry?() }
            retryButton.isHidden = false
        case .noResults:
            spinner.stopAnimating()
            spinner.isHidden = true
            iconView.isHidden = false
            iconView.image = UIImage(systemName: "sparkles")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 48, weight: .light))
            titleLabel.text = "No Results"
            messageLabel.isHidden = false
            messageLabel.text = "Try a different title or check your spelling."
            retryButton.isHidden = true
        case .noResultsWithRequests:
            spinner.stopAnimating()
            spinner.isHidden = true
            iconView.isHidden = false
            iconView.image = UIImage(systemName: "magnifyingglass")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 48, weight: .light))
            titleLabel.text = "No Results"
            messageLabel.isHidden = false
            messageLabel.text = "Search available titles to request."
            retryLabel.text = "Search Requests"
            retryButton.onPrimaryAction = { [weak self] in self?.onRequests?() }
            retryButton.isHidden = false
        }
    }
}
