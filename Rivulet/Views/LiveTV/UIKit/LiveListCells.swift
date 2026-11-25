// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveListCells.swift
//  Rivulet
//
//  The List layout's two rows: a category, coloured as the sidebar's rows, and
//  a channel with what it airs now, on the Music and folder rows' glass platter.
//

import UIKit

// MARK: - Category row

/// Focused: the sidebar's near-white capsule with dark content. Selected: its
/// translucent capsule. A source's header is a quieter row that folds its section.
@MainActor
final class LiveCategoryCell: UICollectionViewCell {
    static let reuseID = "LiveCategoryCell"
    /// The sidebar's row pitch and focus capsule (`ShellSidebarViewController`).
    static let height: CGFloat = 78
    private static let capsuleHeight: CGFloat = 72

    var isSelectedRow = false {
        didSet { if oldValue != isSelectedRow { applyAppearance() } }
    }

    private let capsule = UIView()
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let chevron = UIImageView()
    private var isHeader = false
    private var showsFocus = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        capsule.layer.cornerRadius = Self.capsuleHeight / 2
        capsule.layer.cornerCurve = .continuous
        titleLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        countLabel.textAlignment = .right
        chevron.contentMode = .center
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        [capsule, titleLabel, countLabel, chevron].forEach(contentView.addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ category: LiveCategory, selected: Bool, collapsed: Bool) {
        isHeader = category.kind == .sourceHeader
        titleLabel.text = category.title
        titleLabel.font = isHeader ? .systemFont(ofSize: 24, weight: .semibold) : .preferredFont(forTextStyle: .caption1)
        countLabel.text = isHeader ? nil : category.channelCount.formatted()
        chevron.image = isHeader ? UIImage(systemName: collapsed ? "chevron.right" : "chevron.down") : nil
        isSelectedRow = selected && !isHeader
        applyAppearance()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        capsule.frame = CGRect(x: 0, y: (bounds.height - Self.capsuleHeight) / 2,
                               width: bounds.width, height: Self.capsuleHeight)
        let inset: CGFloat = 24
        let trailing: CGFloat = isHeader ? 32 : 90
        countLabel.frame = CGRect(x: bounds.width - inset - 80, y: 0, width: 80, height: bounds.height)
        chevron.frame = CGRect(x: bounds.width - inset - 24, y: 0, width: 24, height: bounds.height)
        titleLabel.frame = CGRect(x: inset, y: 0, width: bounds.width - inset * 2 - trailing, height: bounds.height)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        // As the sidebar: the old row clears at once, or its capsule ghosts behind the move.
        coordinator.animateFocusChange(gained: focused) {
            self.showsFocus = focused
            self.applyAppearance()
        }
    }

    private func applyAppearance() {
        let colors = sidebarRowColors(focused: showsFocus, selected: isSelectedRow)
        capsule.backgroundColor = colors.background
        let content = isHeader && !showsFocus ? MusicMetrics.secondary : colors.content
        titleLabel.textColor = content
        chevron.tintColor = content
        countLabel.textColor = colors.content.withAlphaComponent(0.6)
    }
}

// MARK: - Channel row

/// Logo, name, and group with the quality last played on the left; what is on
/// now, its times, progress and what is next on the right. No background at rest; the glass platter on focus.
@MainActor
final class LiveChannelRowCell: UICollectionViewCell {
    static let reuseID = "LiveChannelRowCell"
    static let height: CGFloat = 120
    /// The platter reaches past the row, as on the folder and track rows.
    static let platterOutset = FolderRowCell.platterOutset

    private static let logoSize = CGSize(width: 128, height: 72)

    private let platter = MusicFocusPlatterView()
    private let logoTile = UIView()
    private let logoView = UIImageView()
    private let nameLabel = UILabel()
    private let groupLabel = UILabel()
    private let programLabel = UILabel()
    private let timeLabel = UILabel()
    private let nextLabel = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private var progressFraction: CGFloat = 0
    private var logoURL: URL?
    private var logoTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        // The card's neutral tile behind a logo, and alone when there is none.
        logoTile.backgroundColor = UIColor(white: 0.14, alpha: 1)
        logoTile.layer.cornerRadius = 12
        logoTile.layer.cornerCurve = .continuous
        logoTile.clipsToBounds = true
        logoView.contentMode = .scaleAspectFit
        logoTile.addSubview(logoView)

        nameLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        programLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        for label in [groupLabel, nextLabel] {
            label.font = .systemFont(ofSize: 18, weight: .medium)
        }
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        timeLabel.textAlignment = .right
        for label in [nameLabel, programLabel] { label.textColor = .white }
        for label in [groupLabel, nextLabel, timeLabel] { label.textColor = MusicMetrics.secondary }
        for label in [nameLabel, groupLabel, programLabel, nextLabel] { label.lineBreakMode = .byTruncatingTail }

        // As the cards' bar: white over 30% white.
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        progressTrack.layer.cornerRadius = 2
        progressFill.backgroundColor = .white
        progressFill.layer.cornerRadius = 2
        progressTrack.addSubview(progressFill)

        [platter, logoTile, nameLabel, groupLabel, programLabel, timeLabel, progressTrack, nextLabel]
            .forEach(contentView.addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        logoTask?.cancel()
        logoTask = nil
        logoURL = nil
        logoView.image = nil
        platter.alpha = 0
    }

    /// With no guide data the row is the channel alone: no bar, no empty line.
    func configure(_ channel: UnifiedChannel, nowNext: LiveNowNext, now: Date = Date()) {
        nameLabel.text = channel.displayNumberAndName
        groupLabel.text = LiveListText.detail(channel)
        if let current = nowNext.current {
            programLabel.text = current.displayTitle
            timeLabel.text = LiveListText.times(current)
        } else {
            programLabel.text = nil
            timeLabel.text = nil
        }
        if let next = nowNext.next {
            nextLabel.text = LiveListText.next(next)
        } else {
            nextLabel.text = nil
        }
        let progress = nowNext.progress(at: now)
        progressTrack.isHidden = progress == nil
        progressFraction = CGFloat(progress ?? 0)
        load(logo: channel.logoURL)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let outset = Self.platterOutset
        platter.frame = CGRect(x: -outset, y: 4, width: bounds.width + outset * 2, height: bounds.height - 8)

        let logo = Self.logoSize
        logoTile.frame = CGRect(x: 0, y: (bounds.height - logo.height) / 2, width: logo.width, height: logo.height)
        logoView.frame = logoTile.bounds.insetBy(dx: 12, dy: 8)

        // Channel on the left third, programme on the rest.
        let nameX = logo.width + 24
        let programX = max(nameX + 320, bounds.width * 0.42)
        // With nothing from the guide the row is the channel alone, so its name takes the width.
        let hasGuide = programLabel.text != nil || nextLabel.text != nil
        let nameWidth = hasGuide ? programX - nameX - 32 : bounds.width - nameX - 16
        let textTop = groupLabel.text == nil ? (bounds.height - 30) / 2 : 28
        nameLabel.frame = CGRect(x: nameX, y: textTop, width: nameWidth, height: 30)
        groupLabel.frame = CGRect(x: nameX, y: textTop + 34, width: nameWidth, height: 24)

        let width = bounds.width - programX
        let timeWidth: CGFloat = 170
        let hasNext = nextLabel.text != nil
        let top: CGFloat = hasNext ? 18 : (progressTrack.isHidden ? 45 : 32)
        timeLabel.frame = CGRect(x: bounds.width - timeWidth, y: top + 3, width: timeWidth, height: 24)
        programLabel.frame = CGRect(x: programX, y: top, width: width - timeWidth - 16, height: 30)
        progressTrack.frame = CGRect(x: programX, y: top + 42, width: width, height: 4)
        progressFill.frame = CGRect(x: 0, y: 0, width: width * progressFraction, height: 4)
        let nextTop = programLabel.text == nil ? (bounds.height - 24) / 2 : top + 58
        nextLabel.frame = CGRect(x: programX, y: nextTop, width: width, height: 24)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            self.platter.alpha = focused ? 1 : 0
        }
    }

    private func load(logo url: URL?) {
        guard url != logoURL else { return }
        logoTask?.cancel()
        logoURL = url
        logoView.image = nil
        guard let url else { return }
        logoTask = Task { [weak self] in
            let image = await UIImage.legibleChannelLogo(for: url)
            // A reused cell may show another channel by now.
            guard let self, !Task.isCancelled, self.logoURL == url else { return }
            self.logoView.image = image
        }
    }
}
