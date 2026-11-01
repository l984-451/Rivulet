// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The playlist page's header: its title over Play and Shuffle, in the library
//  header's `SortButton` style. Only the buttons take focus.

import UIKit

final class PlaylistHeaderCell: UICollectionViewCell {

    static let reuseID = "playlist.header"

    var onPlay: (() -> Void)?
    var onShuffle: (() -> Void)?

    private let titleLabel = UILabel()
    private let playButton = SortButton()
    private let shuffleButton = SortButton()
    /// Right of the buttons, so Up from any column of the grid's first row lands on Play.
    private let upGuide = UIFocusGuide()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: MediaRowMetrics.sectionTitleSize, weight: .bold)
        titleLabel.textColor = .white
        playButton.configure(sortName: String(localized: "Play"), symbol: "play.fill")
        shuffleButton.configure(sortName: String(localized: "Shuffle"), symbol: "shuffle")
        playButton.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .primaryActionTriggered)
        shuffleButton.addAction(UIAction { [weak self] _ in self?.onShuffle?() }, for: .primaryActionTriggered)
        for view in [titleLabel, playButton, shuffleButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        contentView.addLayoutGuide(upGuide)
        upGuide.preferredFocusEnvironments = [playButton]
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),

            playButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            playButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            shuffleButton.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 16),
            shuffleButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),

            upGuide.leadingAnchor.constraint(equalTo: shuffleButton.trailingAnchor, constant: 16),
            upGuide.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            upGuide.topAnchor.constraint(equalTo: playButton.topAnchor),
            upGuide.bottomAnchor.constraint(equalTo: playButton.bottomAnchor),
        ])
        for button in [playButton, shuffleButton] {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String) {
        titleLabel.text = title
    }

    override var canBecomeFocused: Bool { false }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [playButton] }

    /// Off while a button holds focus, or Right from Shuffle would bounce back to Play.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        upGuide.isEnabled = context.nextFocusedView?.isDescendant(of: self) != true
    }
}
