// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PersonHeaderCell.swift
//  Rivulet
//
//  The biography header for the person detail page (Docs/atv_ref/
//  actor_details_ref.JPG): a true-circle portrait on the LEFT, the person's
//  name (large semibold white) + a muted, truncated biography on the RIGHT,
//  with an uppercase MORE affordance under the bio when it overflows.
//
//  The cell itself is non-focusable; the BIO is wrapped in a focusable glass
//  panel (a reused FocusableActionButton, so Select handling matches the rest
//  of the detail chrome). The whole description block is the affordance — the
//  focus engine can land on it from an Up press off the poster rows, and Select
//  opens the full-bio popup. A "MORE" hint shows inside the panel only when the
//  bio overflows. The portrait loads via ImageCacheManager the same way
//  CastCell does. Background is clear so the controller's blue→black gradient
//  (or blurred title backdrop) shows through.
//

import UIKit

final class PersonHeaderCell: UICollectionViewCell {

    static let reuseID = "PersonHeaderCell"

    /// Bio is truncated to this many lines; MORE appears only when it overflows.
    private static let bioLineLimit = 3

    private static let nameFont = UIFont.systemFont(ofSize: 48, weight: .semibold)
    private static let bioFont = UIFont.systemFont(ofSize: 24, weight: .medium)
    private static let moreFont = UIFont.systemFont(ofSize: 15, weight: .semibold)

    /// Portrait diameter — a header avatar, slightly larger than a cast thumb.
    private static let portraitSize: CGFloat = 215
    /// The name + bio sit in a narrow column (the reference bio spans ~45% of the
    /// screen, not edge-to-edge); cap the column so it reads like the reference.
    private static let textColumnMaxWidth: CGFloat = 900

    private let headerContent = UIView()
    private let portraitContainer = UIView()
    private let portraitImageView = UIImageView()
    private let fallbackIcon = UIImageView()
    private let nameLabel = UILabel()
    /// The whole bio is one focusable glass panel (the affordance the focus
    /// engine lands on from an Up press off the rows). Reuses FocusableActionButton
    /// for proven Select handling, but we override its focus appearance to glass
    /// (subtle fill + scale + border) instead of the white-pill invert.
    private let bioPanel = FocusableActionButton()
    private let bioLabel = UILabel()
    private let moreLabel = UILabel()
    /// Circular spinner shown inside the panel while the biography loads, so the
    /// page reads as "working" and the panel is a focus target from first paint.
    private let loadingSpinner = UIActivityIndicatorView(style: .medium)

    private var imageToken: UInt64 = 0
    /// The portrait URL currently loaded/loading. A reconfigure with the same
    /// URL (e.g. when the bio arrives and the header re-renders) is a no-op, so
    /// the portrait never blanks or refetches — no flicker.
    private var currentPortraitURL: URL?
    private var onMore: (() -> Void)?
    /// Full (untruncated) biography, used to decide whether MORE is needed.
    private var fullBiography: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PersonHeaderCell is not Storyboard-backed") }

    private func setUp() {
        contentView.clipsToBounds = false
        clipsToBounds = false
        backgroundColor = .clear   // VC paints the gradient behind the cell

        // Fixed-width centered container — portrait + text block is one GROUP
        // horizontally centered on screen. The shelf rows below stay left-aligned
        // (they live in separate section cells; this cell owns only the header).
        headerContent.translatesAutoresizingMaskIntoConstraints = false
        headerContent.clipsToBounds = false
        contentView.addSubview(headerContent)

        // True circle: cornerRadius = side/2, clip the image to it.
        portraitContainer.translatesAutoresizingMaskIntoConstraints = false
        portraitContainer.clipsToBounds = true
        portraitContainer.backgroundColor = UIColor(white: 0.15, alpha: 1)
        portraitContainer.layer.cornerRadius = Self.portraitSize / 2
        portraitContainer.layer.borderWidth = 1
        portraitContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        headerContent.addSubview(portraitContainer)

        portraitImageView.translatesAutoresizingMaskIntoConstraints = false
        portraitImageView.contentMode = .scaleAspectFill
        portraitImageView.clipsToBounds = true
        portraitContainer.addSubview(portraitImageView)

        fallbackIcon.translatesAutoresizingMaskIntoConstraints = false
        fallbackIcon.image = UIImage(systemName: "person.fill")
        fallbackIcon.tintColor = UIColor.white.withAlphaComponent(0.3)
        fallbackIcon.contentMode = .center
        fallbackIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 64, weight: .light)
        portraitContainer.addSubview(fallbackIcon)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Self.nameFont
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 1
        headerContent.addSubview(nameLabel)

        // The bio panel: a focusable glass surface holding the bio text + an
        // optional MORE hint. Always focusable when a bio exists (the focus
        // engine lands on it from an Up press off the poster rows); Select opens
        // the full-bio popup. Glass focus style — content stays white.
        bioPanel.translatesAutoresizingMaskIntoConstraints = false
        bioPanel.focusStyle = .glass
        bioPanel.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        bioPanel.layer.cornerRadius = 14
        bioPanel.layer.borderWidth = 1
        bioPanel.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        bioPanel.isHidden = true
        bioPanel.onPrimaryAction = { [weak self] in self?.onMore?() }
        headerContent.addSubview(bioPanel)

        bioLabel.translatesAutoresizingMaskIntoConstraints = false
        bioLabel.font = Self.bioFont
        bioLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        bioLabel.numberOfLines = Self.bioLineLimit
        bioLabel.lineBreakMode = .byTruncatingTail
        bioLabel.isUserInteractionEnabled = false
        bioPanel.addSubview(bioLabel)

        // MORE: an uppercase hint shown inside the panel only when the bio
        // overflows — signals there's more behind Select. Not itself focusable.
        moreLabel.translatesAutoresizingMaskIntoConstraints = false
        moreLabel.text = "MORE"
        moreLabel.font = Self.moreFont
        moreLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        moreLabel.isHidden = true
        bioPanel.addSubview(moreLabel)

        // Loading spinner: centered in the panel (the panel is already at its
        // final 3-line height, so the spinner sits in that reserved space).
        // Shown only while the biography is loading.
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.color = UIColor.white.withAlphaComponent(0.85)
        loadingSpinner.hidesWhenStopped = true
        bioPanel.addSubview(loadingSpinner)

        // headerContent: fixed width = portrait + gap + text column, centered in
        // contentView. Self-sizes vertically by hugging the taller of portrait /
        // text column (>= constraints). The bottom pin is what lets the
        // compositional layout engine measure the estimated-height section.
        let containerWidth = Self.portraitSize + 36 + Self.textColumnMaxWidth
        NSLayoutConstraint.activate([
            // Container anchors
            headerContent.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            headerContent.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerContent.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            headerContent.widthAnchor.constraint(equalToConstant: containerWidth),

            // Portrait — fixed-size circle, TOP aligned with the name top so it
            // lines up with the name + bio block (its bottom lands ≈ the bio
            // panel bottom since the size ≈ the column span).
            portraitContainer.topAnchor.constraint(equalTo: nameLabel.topAnchor),
            portraitContainer.leadingAnchor.constraint(equalTo: headerContent.leadingAnchor),
            portraitContainer.widthAnchor.constraint(equalToConstant: Self.portraitSize),
            portraitContainer.heightAnchor.constraint(equalToConstant: Self.portraitSize),
            portraitContainer.bottomAnchor.constraint(lessThanOrEqualTo: headerContent.bottomAnchor),

            portraitImageView.topAnchor.constraint(equalTo: portraitContainer.topAnchor),
            portraitImageView.leadingAnchor.constraint(equalTo: portraitContainer.leadingAnchor),
            portraitImageView.trailingAnchor.constraint(equalTo: portraitContainer.trailingAnchor),
            portraitImageView.bottomAnchor.constraint(equalTo: portraitContainer.bottomAnchor),

            fallbackIcon.centerXAnchor.constraint(equalTo: portraitContainer.centerXAnchor),
            fallbackIcon.centerYAnchor.constraint(equalTo: portraitContainer.centerYAnchor),

            // Name + bio block to the RIGHT of the portrait. Name defines the
            // column top.
            nameLabel.topAnchor.constraint(equalTo: headerContent.topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: portraitContainer.trailingAnchor, constant: 36),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerContent.trailingAnchor),

            // Bio panel: under the name, spanning the text column. Glass padding
            // (18 h / 14 v) insets the bio + MORE from the panel edge.
            bioPanel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 14),
            bioPanel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            bioPanel.trailingAnchor.constraint(equalTo: headerContent.trailingAnchor),
            bioPanel.bottomAnchor.constraint(lessThanOrEqualTo: headerContent.bottomAnchor),

            bioLabel.topAnchor.constraint(equalTo: bioPanel.topAnchor, constant: 14),
            bioLabel.leadingAnchor.constraint(equalTo: bioPanel.leadingAnchor, constant: 18),
            bioLabel.trailingAnchor.constraint(equalTo: bioPanel.trailingAnchor, constant: -18),
            // Fixed 3-line height so the panel is its FINAL size from first paint
            // (loading or short bio won't shrink it → no expand when the bio
            // arrives). lineHeight × bioLineLimit.
            bioLabel.heightAnchor.constraint(equalToConstant: Self.bioBlockHeight),

            // MORE hint under the bio, leading-aligned; pins the panel bottom.
            moreLabel.topAnchor.constraint(equalTo: bioLabel.bottomAnchor, constant: 10),
            moreLabel.leadingAnchor.constraint(equalTo: bioLabel.leadingAnchor),
            moreLabel.bottomAnchor.constraint(equalTo: bioPanel.bottomAnchor, constant: -14),

            // Spinner centered in the panel's reserved (final-size) area.
            loadingSpinner.centerXAnchor.constraint(equalTo: bioPanel.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: bioLabel.centerYAnchor),

            // Container bottom hugs tallest column (portrait vs text+panel)
            headerContent.bottomAnchor.constraint(greaterThanOrEqualTo: portraitContainer.bottomAnchor),
            headerContent.bottomAnchor.constraint(greaterThanOrEqualTo: bioPanel.bottomAnchor),
        ])
    }

    /// Fixed height of the 3-line bio block — keeps the panel a constant size
    /// whether loading, empty, or showing a bio.
    private static let bioBlockHeight: CGFloat =
        ceil(bioFont.lineHeight * CGFloat(bioLineLimit))

    // MARK: - Configure

    /// `isLoading` true while the biography is still being fetched: the panel
    /// shows the pulse dots and stays a focus target (so focus lands on the
    /// description from first paint), with no bio text or MORE yet.
    func configure(name: String, biography: String?, portraitURL: URL?, isLoading: Bool, onMore: @escaping () -> Void) {
        self.onMore = onMore
        nameLabel.text = name

        // Preview is a single flowing paragraph: TMDB bios carry "\n\n" paragraph
        // breaks, but the reference shows one continuous truncated block. The full
        // multi-paragraph bio is shown in the MORE popup (driven by the VC).
        let bio = (biography ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.fullBiography = bio
        bioLabel.text = bio.isEmpty && !isLoading ? "No biography available." : bio

        // Three states:
        //   loading            → panel visible, dots, no bio/MORE (focusable)
        //   loaded, has bio     → panel visible, bio (+ MORE if it overflows)
        //   loaded, no bio      → panel visible with a placeholder, so the page
        //                         always has a focus target even with no rows
        if isLoading {
            bioPanel.isHidden = false
            loadingSpinner.startAnimating()
            bioLabel.isHidden = true
            moreLabel.isHidden = true
        } else {
            loadingSpinner.stopAnimating()
            bioLabel.isHidden = false
            bioPanel.isHidden = false
            moreLabel.isHidden = true   // re-measured in layoutSubviews
        }
        // Truncation (and thus MORE visibility) can only be measured after the
        // bio label has a real width — defer to layoutSubviews.
        setNeedsLayout()

        loadPortrait(url: portraitURL)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateMoreVisibility()
    }

    /// Show MORE only when the full biography doesn't fit in the line-limited
    /// label. Measured by comparing the unbounded text height against the
    /// height the capped label actually occupies.
    private func updateMoreVisibility() {
        guard let bio = fullBiography, !bio.isEmpty, bioLabel.bounds.width > 1 else {
            if !moreLabel.isHidden { moreLabel.isHidden = true }
            return
        }
        let width = bioLabel.bounds.width
        let attrs: [NSAttributedString.Key: Any] = [.font: bioLabel.font as Any]
        let fullHeight = (bio as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        ).height
        let lineHeight = bioLabel.font.lineHeight
        let cappedHeight = lineHeight * CGFloat(Self.bioLineLimit)
        let truncated = fullHeight > cappedHeight + 1
        if moreLabel.isHidden == truncated {
            moreLabel.isHidden = !truncated
        }
    }

    private func loadPortrait(url: URL?) {
        // Same URL already shown/loading → leave it; avoids a blank+refetch
        // flicker when the header re-renders after the bio loads.
        if url == currentPortraitURL, portraitImageView.image != nil { return }
        currentPortraitURL = url
        imageToken &+= 1
        let token = imageToken
        portraitImageView.image = nil
        fallbackIcon.isHidden = false
        guard let url else { return }
        Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            await MainActor.run {
                guard let self, self.imageToken == token, let image else { return }
                self.portraitImageView.image = image
                self.fallbackIcon.isHidden = true
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageToken &+= 1
        currentPortraitURL = nil
        portraitImageView.image = nil
        fallbackIcon.isHidden = false
        nameLabel.text = nil
        bioLabel.text = nil
        bioLabel.isHidden = false
        fullBiography = nil
        bioPanel.isHidden = true
        loadingSpinner.stopAnimating()
        moreLabel.isHidden = true
        onMore = nil
    }

    // Plain content cell: never a focus target itself. The bio PANEL is the
    // focus target (focusable whenever a bio exists); otherwise focus falls
    // through to the poster rows. Matches AboutCollectionCell / ShelfRowCell.
    override var canBecomeFocused: Bool { false }
}
