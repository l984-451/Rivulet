// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaLibrarySortControl.swift
//  Rivulet
//
//  Full-width sort header cell for MediaLibraryViewController.
//
//  Layout: library title (left, 34pt bold) + item count (below, 17pt dimmed) and,
//  on the right in glass style, a focusable sort button and the Titles /
//  Collections switch (outermost). The CELL itself is not focusable; only the
//  two embedded SortButtons receive focus.
//
//  Glass + focus appearance mirrors FocusableActionButton.swift and the
//  AppStoreActionButtonStyle values in GlassRowStyle.swift:
//    - resting fill: white.withAlphaComponent(0.15), border white 0.2
//    - focused fill: .white, content inverted to black
//    - scale: 1.0 -> 1.06 via UIFocusAnimationCoordinator
//
//  Select handling: bare UIButton.primaryActionTriggered is unreliable on tvOS
//  (press goes to the FOCUSED VIEW's press handlers). We override pressesEnded
//  for .select on SortButton, debounced the same way as FocusableActionButton
//  to prevent double-fire with primaryActionTriggered.
//

import UIKit

// MARK: - SortOption display name

extension SortOption {
    var displayName: String {
        switch self {
        case .titleAsc:        "Title A-Z"
        case .titleDesc:       "Title Z-A"
        case .releaseDateDesc: "Release Date"
        case .addedAtDesc:     "Date Added"
        case .addedAtAsc:      "Date Added (Oldest)"
        case .releaseDateAsc:  "Release Date (Oldest)"
        case .lastContentAddedDesc: "Recently Updated"
        case .ratingDesc:      "Rating"
        }
    }
}

// MARK: - SortButton

/// A focusable rounded button that renders a sort label + SF Symbol icon.
/// Manages its own glass/focus appearance via UIFocusAnimationCoordinator.
/// Exposed as a non-private type so MediaLibraryViewController can detect it
/// in cell(for:at:in:) if needed, but otherwise opaque to callers.
final class SortButton: UIControl {

    // MARK: - Subviews

    private let iconView: UIImageView = {
        let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let img = UIImage(systemName: "arrow.up.arrow.down", withConfiguration: cfg)
        let iv = UIImageView(image: img)
        iv.tintColor = .white
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let sortLabel: UILabel = {
        let lb = UILabel()
        lb.font = .systemFont(ofSize: 17, weight: .semibold)
        lb.textColor = .white
        lb.translatesAutoresizingMaskIntoConstraints = false
        return lb
    }()

    private let bgView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        v.layer.cornerRadius = 14
        v.layer.cornerCurve = .continuous
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        v.isUserInteractionEnabled = false
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    // MARK: - Callback

    var onSortTapped: (() -> Void)?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        addTarget(self, action: #selector(primary), for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        addSubview(bgView)
        bgView.addSubview(iconView)
        bgView.addSubview(sortLabel)

        NSLayoutConstraint.activate([
            bgView.topAnchor.constraint(equalTo: topAnchor),
            bgView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bgView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: trailingAnchor),

            iconView.leadingAnchor.constraint(equalTo: bgView.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            sortLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            sortLabel.trailingAnchor.constraint(equalTo: bgView.trailingAnchor, constant: -16),
            sortLabel.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
        ])
    }

    // MARK: - Configure

    func configure(sortName: String, symbol: String = "arrow.up.arrow.down") {
        sortLabel.text = sortName
        iconView.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { [weak self] in
            guard let self else { return }
            self.transform = focused ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
            self.bgView.backgroundColor = focused ? .white : UIColor.white.withAlphaComponent(0.15)
            self.bgView.layer.borderColor = focused
                ? UIColor.white.withAlphaComponent(0.0).cgColor
                : UIColor.white.withAlphaComponent(0.2).cgColor
            self.iconView.tintColor = focused ? .black : .white
            self.sortLabel.textColor = focused ? .black : .white
        }
    }

    // MARK: - Select press handling
    //
    // On tvOS, bare UIControl.primaryActionTriggered is unreliable for the Siri Remote
    // Select press: the press goes to the FOCUSED view's press handlers, not
    // primaryActionTriggered. We handle pressesEnded(.select) directly, debounced
    // so both paths can't double-fire. Mirrors FocusableActionButton.swift.

    private var lastFireTime: CFTimeInterval = 0

    private func fireOnce() {
        let now = CACurrentMediaTime()
        guard now - lastFireTime > 0.3 else { return }
        lastFireTime = now
        onSortTapped?()
    }

    @objc private func primary() { fireOnce() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { fireOnce(); return }
        super.pressesEnded(presses, with: event)
    }
}

// MARK: - MediaLibrarySortControl

/// Full-width UICollectionViewCell hosting the library title, item count, a
/// focusable sort button and the Titles / Collections switch. The CELL is not
/// focusable; only the two SortButtons are.
final class MediaLibrarySortControl: UICollectionViewCell {

    static let reuseID = "library.sortHeader"

    // MARK: - Subviews

    private let titleLabel: UILabel = {
        let lb = UILabel()
        lb.font = .systemFont(ofSize: 34, weight: .bold)
        lb.textColor = .white
        lb.translatesAutoresizingMaskIntoConstraints = false
        return lb
    }()

    private let countLabel: UILabel = {
        let lb = UILabel()
        lb.font = .systemFont(ofSize: 17)
        lb.textColor = UIColor.white.withAlphaComponent(0.5)
        lb.translatesAutoresizingMaskIntoConstraints = false
        return lb
    }()

    private let sortButton: SortButton = {
        let b = SortButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    /// Titles / Collections switch: shows the current state, Select flips it.
    /// A SortButton, so the glass focus, select debounce and press overrides
    /// come with it.
    private let viewButton: SortButton = {
        let b = SortButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    /// The sort button's trailing edge: beside the switch while both show,
    /// otherwise at the cell edge (alone, or hidden under the switch). Not a
    /// UIStackView: its hiding constraint (width 0, required) fights
    /// SortButton's required internal padding and logs a conflict each toggle.
    private lazy var sortBesideSwitch: NSLayoutConstraint = sortButton.trailingAnchor.constraint(
        equalTo: viewButton.leadingAnchor, constant: -16)
    private lazy var sortAtEdge: NSLayoutConstraint = sortButton.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor, constant: -32)

    // MARK: - Public API

    /// Called by the ViewController when the sort action sheet should appear (Task 10).
    var onSortTapped: (() -> Void)? {
        get { sortButton.onSortTapped }
        set { sortButton.onSortTapped = newValue }
    }

    /// Called when the Titles / Collections switch is selected.
    var onViewTapped: (() -> Void)? {
        get { viewButton.onSortTapped }
        set { viewButton.onSortTapped = newValue }
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
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

        NSLayoutConstraint.activate([
            // Title: left-aligned, vertically centered on the top text cluster.
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),

            // Count: just below the title, same left edge.
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            // Switch: pinned to the right edge, so it never moves under focus
            // when the sort button hides.
            viewButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
            viewButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            viewButton.heightAnchor.constraint(equalToConstant: 44),
            viewButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            // Sort button: left of the switch, or at the edge (configure()
            // swaps these two). Starts at the edge: no switch until the
            // collection list arrives.
            sortAtEdge,
            sortButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            sortButton.heightAnchor.constraint(equalToConstant: 44),
            sortButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            // Keep the buttons from overrunning the title. Both stay active: a
            // hidden sort button parks under the switch, so either way the
            // leftmost visible button binds.
            sortButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
            viewButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
        ])
    }

    // MARK: - Configure

    /// `collections`: nil hides the switch (the library has no non-empty
    /// collection); false shows "Titles" with "N items"; true shows
    /// "Collections" with "N collections" and hides the sort button, which
    /// also takes it out of the focus graph.
    func configure(title: String, count: Int, sortName: String, collections: Bool?) {
        titleLabel.text = title
        countLabel.text = collections == true ? "\(count) collections" : "\(count) items"
        sortButton.configure(sortName: sortName)
        sortButton.isHidden = collections == true
        viewButton.isHidden = collections == nil
        viewButton.configure(
            sortName: collections == true ? "Collections" : "Titles",
            symbol: collections == true ? "square.stack" : "square.grid.2x2")
        // Deactivate before activate, so the two are never active together.
        let beside = collections == false
        NSLayoutConstraint.deactivate([beside ? sortAtEdge : sortBesideSwitch])
        NSLayoutConstraint.activate([beside ? sortBesideSwitch : sortAtEdge])
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { false }

    // Forward focus to the buttons (so the engine moves there on Up/Down into
    // this section rather than skipping past it entirely). A hidden sort button
    // is not focusable, so a programmatic request falls through to the switch.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [sortButton, viewButton]
    }
}
