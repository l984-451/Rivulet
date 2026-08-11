// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  BelowFoldCells.swift
//  Rivulet
//
//  UICollectionViewCell wrappers that host the ported below-fold section views
//  (EpisodeCell / SeasonPillView / CastCell) so they can live in the
//  compositional below-fold collection, plus a section-header reusable view.
//  Each wrapper forwards focus to the inner view's setFocused (the standard
//  tvOS didUpdateFocus + UIFocusAnimationCoordinator pattern) and resets it in
//  prepareForReuse (avoids the stuck-scale fast-scroll bug). See
//  perf-spike/EXPANDED_DETAIL_CONVERSION_SPIKE.md §3.
//

import UIKit
import TVUIKit

// MARK: - Episode

final class EpisodeCollectionCell: UICollectionViewCell {
    static let reuseID = "EpisodeCollectionCell"
    private let episodeView = EpisodeCell()
    /// Fires when either sub-target (thumb/description) gains focus. Cell-level
    /// (not collection-level) so it fires for horizontal moves within the
    /// orthogonal episode row — the collection's own didUpdateFocus does NOT fire
    /// for intra-section nav. Drives season-pill tracking.
    var onFocused: ((Bool) -> Void)?
    /// Thumb Select → play this episode.
    var onPlay: (() -> Void)?
    /// Description Select → open the episode detail page.
    var onShowDetails: (() -> Void)?
    /// Reports which sub-target is focused (thumb / description / none).
    var onFocusKind: ((EpisodeFocusKind) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(episodeView)
        pinFilling(episodeView, to: contentView)
        // The cell itself is non-focusable (canFocusItemAt = false in
        // BelowFoldCollectionView); the EpisodeCell's thumb + description are the
        // real focus targets and report focus/select up through these closures.
        episodeView.onPlay = { [weak self] in self?.onPlay?() }
        episodeView.onShowDetails = { [weak self] in self?.onShowDetails?() }
        episodeView.onFocusKindChanged = { [weak self] kind in
            self?.onFocusKind?(kind)
            if kind != .none { self?.onFocused?(true) }
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(episode: MediaItem, showSeasonPrefix: Bool) {
        episodeView.configure(episode: episode, showSeasonPrefix: showSeasonPrefix)
    }

    /// Trailers render with the SAME episode card so the two rows match exactly.
    func configure(trailer: BelowFoldTrailer) {
        episodeView.configure(trailer: trailer)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onFocused = nil
        onPlay = nil
        onShowDetails = nil
        onFocusKind = nil
        episodeView.resetFocusVisual()
    }
}

// MARK: - Season pill

final class SeasonPillCollectionCell: UICollectionViewCell {
    static let reuseID = "SeasonPillCollectionCell"
    private let pillView = SeasonPillView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(pillView)
        pinFilling(pillView, to: contentView)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(label: String, isSelected: Bool) {
        pillView.configure(label: label, isSelected: isSelected)
    }
    func setSelected(asSeason selected: Bool) { pillView.setSelected(selected) }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = isSelfFocused(context)
        coordinator.addCoordinatedAnimations { [weak self] in self?.pillView.setFocused(focused) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        pillView.setFocused(false)
    }
}

// MARK: - Trailer

final class TrailerCollectionCell: UICollectionViewCell {
    static let reuseID = "TrailerCollectionCell"

    private let card = UIView()
    private let imageView = UIImageView()
    private let glassView = UIVisualEffectView(effect: nil)
    private let gradientLayer = CAGradientLayer()
    private let titleLabel = UILabel()
    private let durationRow = UIStackView()
    private let playIcon = UIImageView()
    private let durationLabel = UILabel()
    private var imageToken: UInt64 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.clipsToBounds = true
        card.backgroundColor = UIColor(white: 0.14, alpha: 1)
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        contentView.addSubview(card)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        card.addSubview(imageView)

        glassView.translatesAutoresizingMaskIntoConstraints = false
        glassView.isUserInteractionEnabled = false
        glassView.backgroundColor = .clear
        glassView.alpha = 0
        glassView.clipsToBounds = true
        card.addSubview(glassView)

        gradientLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.70).cgColor
        ]
        gradientLayer.locations = [0.20, 1.0]
        card.layer.addSublayer(gradientLayer)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        card.addSubview(titleLabel)

        durationRow.translatesAutoresizingMaskIntoConstraints = false
        durationRow.axis = .horizontal
        durationRow.alignment = .center
        durationRow.spacing = 5
        card.addSubview(durationRow)

        playIcon.image = UIImage(systemName: "play.fill")
        playIcon.tintColor = UIColor.white.withAlphaComponent(0.85)
        playIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        durationRow.addArrangedSubview(playIcon)

        durationLabel.font = .systemFont(ofSize: 19, weight: .medium)
        durationLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        durationRow.addArrangedSubview(durationLabel)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            imageView.topAnchor.constraint(equalTo: card.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            glassView.topAnchor.constraint(equalTo: card.topAnchor),
            glassView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            glassView.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            titleLabel.bottomAnchor.constraint(equalTo: durationRow.topAnchor, constant: -2),

            durationRow.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            durationRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = card.bounds
    }

    func configure(trailer: BelowFoldTrailer) {
        titleLabel.text = trailer.title
        durationLabel.text = trailer.durationFormatted ?? "1m"

        imageToken &+= 1
        let token = imageToken
        imageView.image = nil
        guard let url = trailer.artworkURL else { return }
        Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            await MainActor.run {
                guard let self, self.imageToken == token else { return }
                self.imageView.image = image
            }
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = isSelfFocused(context)
        coordinator.addCoordinatedAnimations { [weak self] in
            guard let self else { return }
            self.glassView.alpha = focused ? 1 : 0
            self.glassView.backgroundColor = focused ? UIColor.white.withAlphaComponent(0.08) : .clear
            if focused {
                if #available(tvOS 26.0, *) {
                    self.glassView.effect = UIGlassEffect()
                } else {
                    self.glassView.effect = UIBlurEffect(style: .regular)
                }
            } else {
                self.glassView.effect = nil
            }
            self.card.transform = focused ? CGAffineTransform(scaleX: 1.04, y: 1.04) : .identity
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        card.transform = .identity
        glassView.alpha = 0
        glassView.backgroundColor = .clear
        glassView.effect = nil
    }
}

// MARK: - Cast

final class CastCollectionCell: UICollectionViewCell {
    static let reuseID = "CastCollectionCell"
    private let castView = CastCell()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(castView)
        pinFilling(castView, to: contentView)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(person: MediaPerson, fallbackSubtitle: String?) {
        castView.configure(person: person, fallbackSubtitle: fallbackSubtitle)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = isSelfFocused(context)
        coordinator.addCoordinatedAnimations { [weak self] in self?.castView.setFocused(focused) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        castView.setFocused(false)
    }
}

// MARK: - Related poster (agnostic MediaItem; the existing PosterCell needs PlexMetadata)

final class RelatedPosterCell: UICollectionViewCell {
    static let reuseID = "RelatedPosterCell"
    static let posterWidth: CGFloat = 260
    static let posterHeight: CGFloat = 390

    private let cornerRadius: CGFloat = 16
    // Same TVUIKit poster widget the home rows use (native focus parallax/scale/
    // glow), titleless to match the home aesthetic. The home `PosterCell` can't be
    // reused directly (it takes PlexMetadata + Plex overlays); this shares the
    // underlying widget instead.
    private let posterView = TVPosterView()
    private var imageToken: UInt64 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = false
        clipsToBounds = false

        // Drop shadow on the cell (matches the home PosterCell).
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0.35
        contentView.layer.shadowRadius = 8
        contentView.layer.shadowOffset = CGSize(width: 0, height: 6)

        posterView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(posterView)
        NSLayoutConstraint.activate([
            posterView.topAnchor.constraint(equalTo: contentView.topAnchor),
            posterView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            posterView.widthAnchor.constraint(equalToConstant: Self.posterWidth),
            posterView.heightAnchor.constraint(equalToConstant: Self.posterHeight),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(item: MediaItem) {
        imageToken &+= 1
        let token = imageToken
        posterView.image = nil
        if let url = item.artwork.poster ?? item.artwork.thumbnail {
            Task { [weak self] in
                let image = await ImageCacheManager.shared.image(for: url)
                await MainActor.run {
                    guard let self, self.imageToken == token else { return }
                    self.posterView.image = image
                }
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.layer.shadowPath = UIBezierPath(
            roundedRect: posterView.frame, cornerRadius: cornerRadius).cgPath
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageToken &+= 1
        posterView.image = nil
    }
}

// MARK: - Section header

final class BelowFoldSectionHeader: UICollectionReusableView {
    static let reuseID = "BelowFoldSectionHeader"
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        titleLabel.textColor = .white
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String) { titleLabel.text = title }
}

// MARK: - Season divider

/// Slim, non-focusable boundary marker between seasons in the flat episode
/// rail: a broken vertical hairline through the thumb band with a compact
/// season chip ("S3" / "SP") in the gap. Structure only — the season's full
/// identity lives in the info strip and the pills. The focus engine skips it
/// (canBecomeFocused false + the collection's canFocusItemAt exclusion), so
/// the rail's focus order is unchanged.
final class SeasonDividerCell: UICollectionViewCell {
    static let reuseID = "SeasonDividerCell"
    static let cardWidth: CGFloat = 100

    private let topLine = UIView()
    private let bottomLine = UIView()
    private let chip = UILabel()

    override var canBecomeFocused: Bool { false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for line in [topLine, bottomLine] {
            line.translatesAutoresizingMaskIntoConstraints = false
            line.backgroundColor = UIColor.white.withAlphaComponent(0.18)
            line.layer.cornerRadius = 1
            contentView.addSubview(line)
        }
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.font = .systemFont(ofSize: 29, weight: .semibold)
        chip.textColor = UIColor.white.withAlphaComponent(0.55)
        chip.textAlignment = .center
        contentView.addSubview(chip)
        NSLayoutConstraint.activate([
            // Centered on the thumb band (the cell spans the full card height,
            // text zone included, so the marker aligns with the artwork).
            chip.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            chip.centerYAnchor.constraint(equalTo: contentView.topAnchor, constant: EpisodeCell.thumbHeight / 2),
            topLine.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            topLine.widthAnchor.constraint(equalToConstant: 2),
            topLine.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            topLine.bottomAnchor.constraint(equalTo: chip.topAnchor, constant: -12),
            bottomLine.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            bottomLine.widthAnchor.constraint(equalToConstant: 2),
            bottomLine.topAnchor.constraint(equalTo: chip.bottomAnchor, constant: 12),
            bottomLine.bottomAnchor.constraint(equalTo: contentView.topAnchor, constant: EpisodeCell.thumbHeight - 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SeasonDividerCell is not Storyboard-backed") }

    func configure(label: String) {
        chip.text = label
    }
}

// MARK: - Helpers

private extension UICollectionViewCell {
    func isSelfFocused(_ context: UIFocusUpdateContext) -> Bool {
        guard let next = context.nextFocusedView else { return false }
        return next === self || next.isDescendant(of: self)
    }
}

private func pinFilling(_ inner: UIView, to container: UIView) {
    inner.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        inner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        inner.topAnchor.constraint(equalTo: container.topAnchor),
        inner.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        inner.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
    ])
}
