// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  One carousel card: Apple's scrim and a `MediaDetailChromeView`, over the artwork
//  `BackdropPlaneView` draws. The centred card's chrome fades in over 0.5 s once paging
//  settles and fades against its travel when paging away (`setPagingFade`).

import UIKit
import os.log

private let previewCardLog = Logger(
    subsystem: "com.rivulet.app",
    category: "PreviewCardView"
)

final class PreviewCardView: UICollectionViewCell {
    static let reuseIdentifier = "PreviewCardCell"

    // MARK: - State

    /// Current item this card is showing. `nil` means the card is idle
    /// (cleared for reuse). Setting forwards to the chrome view and
    /// kicks off the backdrop image load here.
    var item: MediaItem? {
        didSet {
            guard item != oldValue else { return }
            guard !isRefreshingWatchState else { return }
            applyItem()
        }
    }

    /// Only the centred card shows vignette and chrome. Set through `setIsCurrent(_:animated:)`.
    private(set) var isCurrent: Bool = false

    /// Monotonic load token for the backdrop image fetch. Chrome view
    /// owns its own token for logo/detail fetches.
    private var loadToken: UInt64 = 0

    /// Monotonic cascade token. Bumped on every `setIsCurrent` so any
    /// in-flight delayed UIView.animate blocks from a prior cascade
    /// no-op if the cell is paged away before they fire.
    private var cascadeToken: UInt64 = 0

    // MARK: - Subviews

    /// Vignette container: holds the three scrim layers.
    /// Alpha 0 by default; cascade fades to 1.
    private let vignetteContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        v.alpha = 0
        return v
    }()

    // The Apple TV app's product-page scrim. Views, not sublayers, so they ride the morph animator.
    private let scrimLayers: [GradientView] = GradientView.productPageScrim().map { v in
        v.translatesAutoresizingMaskIntoConstraints = false
        // Follows the card's top corners, or the scrim shows as dark squares
        // against the grey surround.
        v.layer.cornerCurve = .continuous
        v.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
        v.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        v.layer.masksToBounds = true
        return v
    }

    /// Bottom-leading in the card, above the shelf peek. Starts at alpha 0; the cascade fades it in.
    private let chromeView: MediaDetailChromeView = {
        let v = MediaDetailChromeView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.mode = .carouselStable
        v.chromeAlpha = 0
        return v
    }()

    /// 1 pt white hairline along the top and sides, like Apple's card. On the
    /// cell, above the vignette, so the scrim and the paging fade don't dim it.
    private let hairlineView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor(white: 1, alpha: 0.2).cgColor
        v.layer.cornerCurve = .continuous
        v.layer.cornerRadius = PreviewCarouselGeometry.cornerRadius
        v.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        return v
    }()

    /// The expand morph animates its constant from the carousel inset to the expanded one.
    private var chromeLeadingConstraint: NSLayoutConstraint!

    /// Trailing chrome inset constraint. Mirrors leading (constants
    /// are negative). The host mutates this to keep the chrome
    /// symmetric during morph.
    private var chromeTrailingConstraint: NSLayoutConstraint!

    /// The shelf-peek reserve (`carouselChromeShelfPeek`), the same in both modes.
    private var chromeBottomConstraint: NSLayoutConstraint!
    private var chromeTopConstraint: NSLayoutConstraint!

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreviewCardView is not Storyboard-backed")
    }

    private func commonInit() {
        backgroundColor = .clear
        // Stable identifier for focus diagnostics / UI automation.
        accessibilityIdentifier = "carousel.card.9f27c1"
        // Transparent: BackdropPlaneView draws and clips the artwork behind the cell.
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = false

        scrimLayers.forEach(vignetteContainer.addSubview)
        contentView.addSubview(vignetteContainer)
        contentView.addSubview(chromeView)
        addSubview(hairlineView)

        chromeLeadingConstraint = chromeView.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: PreviewCarouselGeometry.carouselChromeInset
        )
        chromeTrailingConstraint = chromeView.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor,
            constant: -PreviewCarouselGeometry.carouselChromeInset
        )
        chromeBottomConstraint = chromeView.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor,
            constant: -PreviewCarouselGeometry.carouselChromeShelfPeek
        )
        chromeTopConstraint = chromeView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 40)

        NSLayoutConstraint.activate([
            // Vignette covers the full card; gradient stops do the fade.
            vignetteContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            vignetteContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            vignetteContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            vignetteContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // The host animates these constants during expand.
            chromeLeadingConstraint,
            chromeTrailingConstraint,
            chromeBottomConstraint,

            // 1 pt taller than the card, so the bottom stroke falls off screen.
            hairlineView.topAnchor.constraint(equalTo: topAnchor),
            hairlineView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairlineView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairlineView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 1)
        ])
        // Every scrim layer fills the card; the stops do the shaping.
        NSLayoutConstraint.activate(scrimLayers.flatMap { [
            $0.topAnchor.constraint(equalTo: vignetteContainer.topAnchor),
            $0.leadingAnchor.constraint(equalTo: vignetteContainer.leadingAnchor),
            $0.trailingAnchor.constraint(equalTo: vignetteContainer.trailingAnchor),
            $0.bottomAnchor.constraint(equalTo: vignetteContainer.bottomAnchor)
        ] })
    }

    // MARK: - Layout

    // MARK: - Custom layout attribute application

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        // Backdrop + parallax are owned by BackdropPlaneView now. The
        // cell only consumes frame + alpha from the layout (handled by
        // super). Nothing cell-local to update here.
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken &+= 1
        cascadeToken &+= 1
        isCurrent = false
        contentView.alpha = 1
        hairlineView.alpha = 1
        setCornerRadius(PreviewCarouselGeometry.cornerRadius)
        vignetteContainer.alpha = 0
        chromeView.chromeAlpha = 0
        chromeView.reset()
        onDetailArtwork = nil
        item = nil
    }

    // MARK: - Chrome cascade

    /// Marks the centred card; `animated` fades vignette and chrome in over 0.5 s.
    func setIsCurrent(_ current: Bool, animated: Bool) {
        guard isCurrent != current || !animated else { return }
        isCurrent = current
        chromeView.isDescriptionTranslationActive = current
        cascadeToken &+= 1
        let token = cascadeToken

        // Cancel any in-flight animations by reading the current
        // presentation alpha and committing it as the model value,
        // then issuing the new animation from there.
        let currentVignetteAlpha = vignetteContainer.layer.presentation()?.opacity ?? Float(vignetteContainer.alpha)
        let currentChromeAlpha = chromeView.layer.presentation()?.opacity ?? Float(chromeView.chromeAlpha)
        vignetteContainer.layer.removeAllAnimations()
        chromeView.layer.removeAllAnimations()
        vignetteContainer.alpha = CGFloat(currentVignetteAlpha)
        chromeView.chromeAlpha = CGFloat(currentChromeAlpha)

        if !current {
            // Snap to invisible; the travel-driven fade already ran (setPagingFade).
            vignetteContainer.alpha = 0
            chromeView.chromeAlpha = 0
            return
        }

        if !animated {
            vignetteContainer.alpha = 1
            chromeView.chromeAlpha = 1
            return
        }

        UIView.animate(
            withDuration: 0.5,
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
        ) { [weak self] in
            guard let self, self.cascadeToken == token else { return }
            self.vignetteContainer.alpha = 1
            self.chromeView.chromeAlpha = 1
        }
    }

    /// Whether the chrome's logo and details are in (`MediaDetailChromeView.whenContentReady`).
    var isChromeReady: Bool { chromeView.isContentReady }
    func whenChromeReady(_ body: @escaping () -> Void) { chromeView.whenContentReady(body) }

    /// Fade the whole card content against paging travel (1 centred, 0 gone).
    /// On `contentView` so it multiplies an in-flight fade-in instead of fighting it.
    func setPagingFade(_ alpha: CGFloat) { contentView.alpha = alpha }

    /// Hairline strength for the card's normalized position: 0.1 centred,
    /// about 0.2 on a resting neighbour.
    func setHairline(position: CGFloat) {
        hairlineView.layer.borderColor = UIColor(white: 1, alpha: 0.1 + 0.1 * abs(position)).cgColor
    }

    /// Hairline and scrim follow the window's corner radius through the morph
    /// (display-link tick).
    func setCornerRadius(_ radius: CGFloat) {
        hairlineView.layer.cornerRadius = radius
        scrimLayers.forEach { $0.layer.cornerRadius = radius }
    }

    // MARK: - Apply

    /// Hero Play → play this item (resolved to its on-deck episode for shows by
    /// the carousel VC). Set by the VC in cellForItemAt.
    var onPlay: ((MediaItem) -> Void)?
    /// Versions → play `item` from the picked file. Set by the VC in cellForItemAt.
    var onPlayVersion: ((MediaItem, String) -> Void)?
    /// Info button → show the structured info popup (carries the loaded detail).
    var onShowInfo: ((MediaItemDetail) -> Void)?
    var onDetailArtwork: ((MediaItemRef, MediaArtwork) -> Void)?

    /// Repaint the hero chrome's watch-derived bits from a re-fetched copy of
    /// the same item, without rebuilding the card (issue #228). Also updates
    /// this card's own stored item so `onPlay` resumes from the new offset.
    func refreshWatchState(from refreshed: MediaItem) {
        guard let current = item, current.ref == refreshed.ref else { return }
        isRefreshingWatchState = true
        item = refreshed
        isRefreshingWatchState = false
        chromeView.refreshWatchState(from: refreshed)
    }

    /// Set while `refreshWatchState` swaps the re-fetched item in, so the
    /// `item` `didSet` skips the backdrop/chrome rebuild.
    private var isRefreshingWatchState = false

    private func applyItem() {
        loadToken &+= 1

        // Forward to chrome view — it owns logo + metadata + detail fetch.
        // Backdrop artwork is owned by BackdropPlaneView now.
        chromeView.item = item
        chromeView.onPlay = { [weak self] in
            guard let self, let item = self.chromeView.item else { return }
            self.onPlay?(item)
        }
        chromeView.onPlayVersion = { [weak self] sourceID in
            guard let self, let item = self.chromeView.item else { return }
            self.onPlayVersion?(item, sourceID)
        }
        chromeView.onShowFullDescription = { [weak self] detail in
            self?.onShowInfo?(detail)
        }
        chromeView.onDetailArtwork = { [weak self] ref, artwork in
            guard let self, self.item?.ref == ref else { return }
            self.onDetailArtwork?(ref, artwork)
        }
    }

    // MARK: - Expand state

    /// Set chrome layout mode + insets for carousel vs expanded. Corner
    /// radius and backdrop are no longer the cell's concern (plane owns
    /// them). Kept minimal; the morph controller drives the animation.
    func setExpanded(_ expanded: Bool) {
        let inset = expanded
            ? PreviewCarouselGeometry.expandedChromeInset
            : PreviewCarouselGeometry.carouselChromeInset
        chromeLeadingConstraint.constant = inset
        chromeTrailingConstraint.constant = -inset
        chromeTopConstraint.isActive = expanded
        chromeView.mode = expanded ? .expandedDetail : .carouselStable
        // The centred card's hairline fades out as it grows to fullscreen.
        hairlineView.alpha = expanded ? 0 : 1
    }

    // MARK: - Focus

    /// Focus target for the expanded action row (the Play pill). nil until the
    /// detail loads. The VC points the focus engine at this cell when expanded;
    /// the cell redirects focus into Play.
    var actionFocusEnvironment: UIView? { chromeView.playFocusable }

    /// Fade the hero metadata (chrome) as the user scrolls into the details.
    /// 1 = full hero, 0 = hidden. Restored to 1 when scroll progress returns to 0.
    func setHeroChromeAlpha(_ alpha: CGFloat) { chromeView.chromeAlpha = alpha }

    /// Make the chrome action buttons (un)focusable — disabled while the user is
    /// in the below-fold so focus can't escape up into them.
    func setChromeActionRowFocusable(_ on: Bool) { chromeView.setActionRowFocusable(on) }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let play = chromeView.playFocusable { return [play] }
        return super.preferredFocusEnvironments
    }
}

/// A view backed by a CAGradientLayer, so the gradient resizes and animates with the view.
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

    convenience init(_ type: CAGradientLayerType, from start: CGPoint, to end: CGPoint,
                     alphas: [CGFloat], locations: [NSNumber]?) {
        self.init(frame: .zero)
        isUserInteractionEnabled = false
        gradientLayer.type = type
        gradientLayer.startPoint = start
        gradientLayer.endPoint = end
        gradientLayer.colors = alphas.map { UIColor.black.withAlphaComponent($0).cgColor }
        gradientLayer.locations = locations
    }

    /// The Apple TV app's product-page scrim (`ProductGradientLayout`): three
    /// black layers, each meant to fill the page.
    static func productPageScrim() -> [GradientView] {
        [
            // Bottom band: clear over the top 64 percent.
            GradientView(.axial, from: CGPoint(x: 0.5, y: 0), to: CGPoint(x: 0.5, y: 1),
                         alphas: [0, 0, 0.03, 0.135, 0.27, 0.405, 0.54, 0.675],
                         locations: [0, 0.64, 0.71, 0.78, 0.84, 0.91, 0.95, 1.0]),
            // Radial, clear at two thirds across the top edge, darkest lower left.
            GradientView(.radial, from: CGPoint(x: 0.667, y: 0), to: CGPoint(x: 1.727, y: 1.884),
                         alphas: [0, 0.04, 0.15, 0.30, 0.33, 0.49, 0.67, 0.85, 1.0],
                         locations: [0, 0.19, 0.36, 0.51, 0.53, 0.65, 0.77, 0.89, 1.0]),
            // Left-to-right wash across the whole width.
            GradientView(.axial, from: CGPoint(x: 0, y: 1), to: CGPoint(x: 1, y: 0.8),
                         alphas: [0.30, 0], locations: nil)
        ]
    }
}
