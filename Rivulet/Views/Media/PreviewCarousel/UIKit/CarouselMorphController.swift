// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The one animator and display link behind the expand and collapse morph: layout
//  swap, backdrop panel, chrome insets, hairline and corner radius all share its
//  clock, so nothing drifts (Docs/UIKIT_FOUNDATIONS.md §1, §5).

import UIKit

@MainActor
final class CarouselMorphController {
    private weak var collectionView: UICollectionView?
    private weak var backdropPlane: BackdropPlaneView?
    private let carouselLayout: PreviewCarouselLayout
    private let expandedLayout: PreviewExpandedLayout

    /// Below-fold surface, set by the VC. Its episode-peek inset + thumb
    /// elongation ride THIS animator so they stay on the morph's single clock.
    weak var detailContainer: ExpandedDetailContainerView?

    private var animator: UIViewPropertyAnimator?
    private var displayLink: CADisplayLink?

    /// Index being morphed.
    private var morphingIndex: Int = 0
    /// Its cell; hairline and scrim follow the window's radius on each tick.
    private weak var morphingCell: PreviewCardView?
    /// Corner-radius lerp endpoints for the current morph.
    private var radiusFrom: CGFloat = 0
    private var radiusTo: CGFloat = 0

    deinit {
        // Don't let an in-flight morph outlive teardown: invalidate the clock and
        // stop the animator (a UIViewPropertyAnimator released while .active
        // aborts the app in dealloc).
        displayLink?.invalidate()
        if animator?.state == .active { animator?.stopAnimation(true) }
    }

    init(
        collectionView: UICollectionView,
        backdropPlane: BackdropPlaneView,
        carouselLayout: PreviewCarouselLayout,
        expandedLayout: PreviewExpandedLayout
    ) {
        self.collectionView = collectionView
        self.backdropPlane = backdropPlane
        self.carouselLayout = carouselLayout
        self.expandedLayout = expandedLayout
    }

    var isAnimating: Bool { animator?.isRunning ?? false }

    // MARK: - Expand

    func expand(
        centeredIndex: Int,
        in viewBounds: CGRect,
        cell: PreviewCardView?,
        completion: @escaping () -> Void
    ) {
        guard let cv = collectionView, let plane = backdropPlane else { return }
        morphingIndex = centeredIndex
        morphingCell = cell

        plane.isMorphing = true
        expandedLayout.itemCount = carouselLayout.itemCount
        expandedLayout.expandedIndex = centeredIndex

        let animator = UIViewPropertyAnimator(
            duration: PreviewCarouselGeometry.expandAnimationDuration,
            curve: .easeInOut
        )
        animator.addAnimations { [weak self] in
            guard let self else { return }
            // a) Card window, on this animator's curve. The VC's pin holds the offset.
            cv.setCollectionViewLayout(self.expandedLayout, animated: false)
            cv.layoutIfNeeded()
            // b) Backdrop centered panel container grows to fullscreen.
            plane.expandPanel(centeredIndex, to: viewBounds)
            // c) Chrome insets to the expanded margin (metadata pulled to
            //    the sides) and the hairline out.
            cell?.setExpanded(true)
            cell?.contentView.layoutIfNeeded()
            // d) Below-fold peek: clip widens to full-bleed (n-1/n+1 edges
            //    peek in) + thumbs elongate, on this same animator.
            self.detailContainer?.setExpanded(true)
            self.detailContainer?.layoutIfNeeded()
        }
        animator.addCompletion { [weak self] _ in
            self?.endMorph()
            completion()
        }
        self.animator = animator
        startRadiusLink(from: PreviewCarouselGeometry.cornerRadius, to: 0)
        animator.startAnimation()
    }

    /// Apply the expanded end-state with NO animation — for the standalone detail
    /// mode, which opens already expanded (no card-grow morph). Mirrors `expand`'s
    /// animation block + its final corner radius.
    func expandInstantly(
        centeredIndex: Int,
        in viewBounds: CGRect,
        cell: PreviewCardView?,
        completion: @escaping () -> Void
    ) {
        guard let cv = collectionView, let plane = backdropPlane else { return }
        morphingIndex = centeredIndex
        morphingCell = cell
        radiusTo = 0
        plane.isMorphing = true
        expandedLayout.itemCount = carouselLayout.itemCount
        expandedLayout.expandedIndex = centeredIndex

        cv.setCollectionViewLayout(expandedLayout, animated: false)
        cv.layoutIfNeeded()
        plane.expandPanel(centeredIndex, to: viewBounds)
        cell?.setExpanded(true)
        cell?.contentView.layoutIfNeeded()
        detailContainer?.setExpanded(true)
        detailContainer?.layoutIfNeeded()

        endMorph()
        completion()
    }

    // MARK: - Collapse

    func collapse(
        centeredIndex: Int,
        cell: PreviewCardView?,
        completion: @escaping () -> Void
    ) {
        guard let cv = collectionView, let plane = backdropPlane else { return }
        morphingIndex = centeredIndex
        morphingCell = cell

        // If an expand is mid-flight, reverse it instead of starting fresh.
        if let animator, animator.isRunning {
            animator.isReversed = true
            swap(&radiusFrom, &radiusTo)
            // Reverse the cell's chrome insets + the below-fold peek too.
            cell?.setExpanded(false)
            detailContainer?.setExpanded(false)
            return
        }

        let stage = plane.bounds.size
        let window = carouselWindow(centeredIndex, offset: cv.contentOffset)
        let parallax = carouselLayout.parallaxOffset(for: centeredIndex)

        plane.isMorphing = true
        let animator = UIViewPropertyAnimator(
            duration: PreviewCarouselGeometry.expandAnimationDuration,
            curve: .easeInOut
        )
        animator.addAnimations { [weak self] in
            guard let self else { return }
            // The carousel-layout swap also zeroes contentOffset; the VC's pin
            // (still active through collapse) holds it centered so the card
            // returns to the right slot.
            cv.setCollectionViewLayout(self.carouselLayout, animated: false)
            cv.layoutIfNeeded()
            plane.collapsePanel(centeredIndex, to: window, parallax: parallax, stage: stage)
            cell?.setExpanded(false)
            cell?.contentView.layoutIfNeeded()
            self.detailContainer?.setExpanded(false)
            self.detailContainer?.layoutIfNeeded()
        }
        animator.addCompletion { [weak self] _ in
            self?.endMorph()
            completion()
        }
        self.animator = animator
        startRadiusLink(from: 0, to: PreviewCarouselGeometry.cornerRadius)
        animator.startAnimation()
    }

    // MARK: - Corner-radius display link

    private func startRadiusLink(from: CGFloat, to: CGFloat) {
        radiusFrom = from
        radiusTo = to
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(tickRadius))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tickRadius() {
        guard let animator else { return }
        let raw = animator.fractionComplete
        let t = animator.isReversed ? (1 - raw) : raw
        setRadius(radiusFrom + (radiusTo - radiusFrom) * t)
    }

    private func setRadius(_ radius: CGFloat) {
        backdropPlane?.setWindowCornerRadius(radius, for: morphingIndex)
        morphingCell?.setCornerRadius(radius)
    }

    private func endMorph() {
        displayLink?.invalidate()
        displayLink = nil
        // The last tick can stop just short of the end value.
        setRadius(radiusTo)
        backdropPlane?.isMorphing = false
        animator = nil
    }

    // MARK: - Geometry

    /// The centered card's window rect in viewport (plane) coords.
    private func carouselWindow(_ index: Int, offset: CGPoint) -> CGRect {
        // Not carouselLayout.cardFrame: mid-collapse that layout is detached and returns
        // .zero. Keep this math in sync with PreviewCarouselLayout.cellFrame.
        guard let cv = collectionView else { return .zero }
        let geom = PreviewCarouselGeometry.self
        let centered = geom.centeredCardFrame(in: cv.bounds)
        let centeredWidth = centered.width
        let stride = centeredWidth + geom.sideCardGap
        let edgePad = geom.centeredHorizontalInset
        let x = edgePad + stride * CGFloat(index)
        return CGRect(
            x: x - offset.x,
            y: centered.minY - offset.y,
            width: centeredWidth,
            height: centered.height
        )
    }
}
