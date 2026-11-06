// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The library grid's header: title and item count on the left, Shuffle and the Sort
//  and View (Titles, Collections, Folders) menu buttons on the right. Only the buttons take focus,
//  and Up and Down reach them only from beneath.

import UIKit

// MARK: - SortOption display name

extension SortOption {
    var displayName: String {
        switch self {
        case .titleAsc:        String(localized: "Title A-Z")
        case .titleDesc:       String(localized: "Title Z-A")
        case .releaseDateDesc: String(localized: "Release Date")
        case .addedAtDesc:     String(localized: "Date Added")
        case .addedAtAsc:      String(localized: "Date Added (Oldest)")
        case .releaseDateAsc:  String(localized: "Release Date (Oldest)")
        case .lastContentAddedDesc: String(localized: "Recently Updated")
        case .ratingDesc:      String(localized: "Rating")
        }
    }
}

// MARK: - LibraryViewMode

/// How a library tab shows its contents, saved per library and profile.
enum LibraryViewMode: String {
    case titles, collections, folders

    // Display name; rawValue is persisted.
    var title: String {
        switch self {
        case .titles: String(localized: "Titles")
        case .collections: String(localized: "Collections")
        case .folders: String(localized: "Folders")
        }
    }

    var symbol: String {
        switch self {
        case .titles: "square.grid.2x2"
        case .collections: "square.stack"
        case .folders: "folder"
        }
    }

    /// The View button's menu; nil when there is nothing to switch to.
    static func menu(_ modes: [LibraryViewMode], current: LibraryViewMode,
                     select: @escaping (LibraryViewMode) -> Void) -> UIMenu? {
        guard modes.count > 1 else { return nil }
        return UIMenu(children: modes.map { mode in
            UIAction(title: mode.title, image: UIImage(systemName: mode.symbol),
                     state: mode == current ? .on : .off) { _ in select(mode) }
        })
    }
}

// MARK: - SortButton

/// A focusable glass pill with an SF Symbol and a label, on the hero's pill
/// metrics (66 tall, 29 pt label) so it matches every other button.
/// A UIButton so it can carry a `menu`, which Select then opens.
final class SortButton: UIButton {

    private static let iconConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)

    // MARK: - Subviews

    private let iconView: UIImageView = {
        let iv = UIImageView()
        iv.tintColor = .white
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let sortLabel: UILabel = {
        let lb = UILabel()
        lb.font = HeroPillButton.titleFont
        lb.textColor = .white
        lb.translatesAutoresizingMaskIntoConstraints = false
        return lb
    }()

    private let bgView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        v.layer.cornerRadius = HeroPillButton.buttonHeight / 2
        v.layer.cornerCurve = .continuous
        v.isUserInteractionEnabled = false
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let glassView: UIVisualEffectView = {
        let v = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        v.layer.cornerRadius = HeroPillButton.buttonHeight / 2
        v.layer.cornerCurve = .continuous
        v.clipsToBounds = true
        v.isUserInteractionEnabled = false
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    /// Whether a focus move may land here; nil always allows it.
    var isReachable: (() -> Bool)?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        for v in [bgView, glassView, iconView, sortLabel] as [UIView] { addSubview(v) }
        let pad = HeroPillButton.sidePadding

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: HeroPillButton.buttonHeight),
            bgView.topAnchor.constraint(equalTo: topAnchor),
            bgView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bgView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            sortLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: HeroPillButton.iconGap),
            sortLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            sortLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Configure

    /// The View button: shows `current` and opens `menu`; hidden without one.
    func configure(view current: LibraryViewMode, menu: UIMenu?) {
        configure(sortName: current.title, symbol: current.symbol)
        self.menu = menu
        showsMenuAsPrimaryAction = true
        isHidden = menu == nil
    }

    func configure(sortName: String, symbol: String = "arrow.up.arrow.down") {
        sortLabel.text = sortName
        iconView.image = UIImage(systemName: symbol, withConfiguration: Self.iconConfig)
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { isReachable?() ?? true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { [weak self] in
            guard let self else { return }
            let scale = HeroPillButton.focusScale
            self.transform = focused ? CGAffineTransform(scaleX: scale, y: scale) : .identity
            self.bgView.backgroundColor = focused ? .white : UIColor.white.withAlphaComponent(0.2)
            self.glassView.alpha = focused ? 0 : 1
            self.iconView.tintColor = focused ? .black : .white
            self.sortLabel.textColor = focused ? .black : .white
        }
    }
}

// MARK: - MediaLibrarySortControl

/// Full-width UICollectionViewCell hosting the library title, item count, a
/// focusable sort button and the View menu button. The CELL is not focusable;
/// only the two SortButtons are.
final class MediaLibrarySortControl: UICollectionViewCell {

    static let reuseID = "library.sortHeader"

    // MARK: - Subviews

    private let titleLabel: UILabel = {
        let lb = UILabel()
        // The folder and photo library pages' title size.
        lb.font = .systemFont(ofSize: 48, weight: .bold)
        lb.textColor = .white
        lb.translatesAutoresizingMaskIntoConstraints = false
        return lb
    }()

    private let countLabel: UILabel = {
        let lb = UILabel()
        lb.font = .systemFont(ofSize: 29)
        lb.textColor = UIColor.white.withAlphaComponent(0.6)
        lb.translatesAutoresizingMaskIntoConstraints = false
        return lb
    }()

    private let sortButton: SortButton = {
        let b = SortButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    /// The View menu: Titles, Collections, Folders.
    private let viewButton: SortButton = {
        let b = SortButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    /// Plays the library shuffled; shows beside Sort when the page has a handler.
    private let shuffleButton: SortButton = {
        let b = SortButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.configure(sortName: String(localized: "Shuffle"), symbol: "shuffle")
        return b
    }()
    private var onShuffle: (() -> Void)?
    /// Off while Shuffle is hidden, so a hidden button never squeezes the title.
    private lazy var shuffleClearsTitle: NSLayoutConstraint = shuffleButton.leadingAnchor.constraint(
        greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16)

    /// The sort button's trailing edge: beside the View button while both
    /// show, otherwise at the cell edge. Not a UIStackView: its hiding
    /// constraint (width 0, required) fights SortButton's required internal
    /// padding and logs a conflict each toggle.
    private lazy var sortBesideView: NSLayoutConstraint = sortButton.trailingAnchor.constraint(
        equalTo: viewButton.leadingAnchor, constant: -16)
    private lazy var sortAtEdge: NSLayoutConstraint = sortButton.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor)

    // MARK: - Public API


    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        for button in [shuffleButton, sortButton, viewButton] {
            button.isReachable = { [weak self] in self?.buttonsReachable() ?? true }
        }
        shuffleButton.addAction(UIAction { [weak self] _ in self?.onShuffle?() }, for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func setup() {
        // Cell must NOT be focusable; only the two buttons are.
        contentView.addSubview(titleLabel)
        contentView.addSubview(countLabel)
        contentView.addSubview(sortButton)
        contentView.addSubview(viewButton)
        contentView.addSubview(shuffleButton)

        NSLayoutConstraint.activate([
            // Shuffle: left of Sort, and shown only with it.
            shuffleButton.trailingAnchor.constraint(equalTo: sortButton.leadingAnchor, constant: -16),
            shuffleButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            shuffleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            // Title: left-aligned, vertically centered on the top text cluster.
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),

            // Count: just below the title, same left edge.
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            countLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            // View button: pinned to the right edge, so it never moves under
            // focus when the sort button hides.
            viewButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            viewButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            viewButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            // Sort button: left of the View button, or at the edge
            // (configure() swaps these two).
            sortAtEdge,
            sortButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            sortButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            // Keep the buttons from overrunning the title. Both stay active: a
            // hidden sort button parks under the View button, so either way the
            // leftmost visible button binds.
            sortButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
            viewButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),

        ])
    }

    // MARK: - Configure

    /// In Collections the count reads "N collections" and the sort and shuffle
    /// buttons hide, which also takes them out of the focus graph.
    func configure(title: String, count: Int, sortName: String, sortMenu: UIMenu,
                   view: LibraryViewMode, viewMenu: UIMenu?, onShuffle: (() -> Void)? = nil) {
        titleLabel.text = title
        countLabel.text = view == .collections ? String(localized: "\(count) collections") : String(localized: "\(count) items")
        sortButton.configure(sortName: sortName)
        sortButton.menu = sortMenu
        sortButton.showsMenuAsPrimaryAction = true
        sortButton.isHidden = view == .collections
        self.onShuffle = onShuffle
        shuffleButton.isHidden = sortButton.isHidden || onShuffle == nil
        shuffleClearsTitle.isActive = !shuffleButton.isHidden
        viewButton.configure(view: view, menu: viewMenu)
        // Deactivate before activate, so the two are never active together.
        let beside = !viewButton.isHidden
        NSLayoutConstraint.deactivate([beside ? sortAtEdge : sortBesideView])
        NSLayoutConstraint.activate([beside ? sortBesideView : sortAtEdge])
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { false }

    /// Reachable from inside the header, or from a view whose column overlaps the buttons.
    private func buttonsReachable() -> Bool {
        guard let window, let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView else { return true }
        if focused.isDescendant(of: self) { return true }
        let left = [shuffleButton, sortButton, viewButton].filter { !$0.isHidden }.map { $0.convert($0.bounds, to: window).minX }.min()
        guard let left else { return false }
        return focused.convert(focused.bounds, to: window).maxX > left
    }

    // Forward focus to the buttons (so the engine moves there on Up/Down into
    // this section rather than skipping past it entirely). A hidden sort button
    // is not focusable, so a programmatic request falls through to the View button.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [sortButton, viewButton, shuffleButton]
    }
}
