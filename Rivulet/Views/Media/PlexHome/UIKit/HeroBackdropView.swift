// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HeroBackdropView.swift
//  Rivulet
//
//  The Home hero's full-bleed backdrop and scrim, behind the collection view.
//  Motion and scrim are the Apple TV app's home hero (VideosUI, read on tvOS
//  26.5): a page change slides the art over with the image at half the page's
//  speed, and scrolling down lifts the backdrop until its bottom edge meets the
//  first shelf, then it rides the content.
//

import UIKit

enum HeroPageDirection: CGFloat {
    case forward = 1
    case backward = -1
}

@MainActor
final class HeroBackdropView: UIView {

    /// One page: a clipping container whose image is counter-offset while it
    /// slides, so the art moves at `parallaxRatio` of the page's speed.
    private final class Page: UIView {
        let imageView = UIImageView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            addSubview(imageView)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.bounds = bounds
            imageView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        /// Page translation `x`; the image inside moves at half of it.
        func setOffset(_ x: CGFloat) {
            transform = CGAffineTransform(translationX: x, y: 0)
            imageView.transform = CGAffineTransform(translationX: -x * HeroBackdropView.parallaxRatio, y: 0)
        }
    }

    private var currentPage = Page()
    private var previousPage = Page()
    private let placeholderLayer = CAGradientLayer()
    private let scrimLayers: [CAGradientLayer]

    private var currentURL: URL?
    private var loadTask: Task<Void, Never>?
    private var pageAnimator: UIViewPropertyAnimator?
    private let themeVideo: ThemeVideoBackdropView
    private var isShowcased = true
    private var isChangingBackdrop = false

    override var isHidden: Bool {
        didSet { updateThemeVideoSuspension() }
    }

    /// Fired when a real backdrop image is on screen. Used by the home VC to
    /// gate startup/profile-switch loading on the hero so it doesn't pop in
    /// after the rows have already painted. Never fires for `nil` URLs (no
    /// image will load) — the caller marks readiness directly in that case.
    var onFirstImageLoaded: (() -> Void)?

    /// Apple's `parallaxRatio`: the image moves at half the page's speed.
    static let parallaxRatio: CGFloat = 0.5
    /// Apple's page animator: 1 s, its composed spring + cubic timing.
    static func pageAnimator() -> UIViewPropertyAnimator {
        UIViewPropertyAnimator(duration: 1.0, timingParameters: HeroPageTiming())
    }
    /// Non-paging image swaps (a refreshed URL for the same slide).
    private let crossfadeDuration: TimeInterval = 0.22

    init(frame: CGRect = .zero, themeVideo: ThemeVideoBackdropView? = nil) {
        self.themeVideo = themeVideo ?? ThemeVideoBackdropView()
        // Apple's home hero scrim (`MediaShowcasingGradientLayout`, stage):
        // constant black, no per-image darkening.
        scrimLayers = [
            Self.gradient(.axial, from: CGPoint(x: 0, y: 0.6), to: CGPoint(x: 0.41, y: 0.5),
                          alphas: [0.14, 0], locations: nil),
            Self.gradient(.axial, from: CGPoint(x: 0.5, y: 0), to: CGPoint(x: 0.5, y: 1),
                          alphas: [0, 0, 0.02, 0.09, 0.18, 0.27, 0.36, 0.45],
                          locations: [0, 0.64, 0.71, 0.78, 0.84, 0.91, 0.95, 1.0]),
            Self.gradient(.radial, from: CGPoint(x: 0.6671875, y: 0), to: CGPoint(x: 1.7270833, y: 1.8842593),
                          alphas: [0, 0.04, 0.15, 0.30, 0.33, 0.49, 0.67, 0.85, 1.0],
                          locations: [0, 0.19, 0.36, 0.51, 0.53, 0.65, 0.77, 0.89, 1.0])
        ]
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func gradient(_ type: CAGradientLayerType, from start: CGPoint, to end: CGPoint,
                                 alphas: [CGFloat], locations: [NSNumber]?) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.type = type
        g.colors = alphas.map { UIColor.black.withAlphaComponent($0).cgColor }
        g.locations = locations
        g.startPoint = start
        g.endPoint = end
        return g
    }

    private func setUp() {
        backgroundColor = .black
        isUserInteractionEnabled = false

        // Placeholder gradient (dark grey -> nearly-black) shows before the
        // first image resolves. Sits beneath both pages.
        placeholderLayer.colors = [
            UIColor(white: 0.15, alpha: 1).cgColor,
            UIColor(white: 0.05, alpha: 1).cgColor
        ]
        placeholderLayer.startPoint = CGPoint(x: 0.5, y: 0)
        placeholderLayer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(placeholderLayer)

        for page in [previousPage, currentPage] {
            page.alpha = 0
            addSubview(page)
        }
        addSubview(themeVideo)
        scrimLayers.forEach { layer.addSublayer($0) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholderLayer.frame = bounds
        scrimLayers.forEach { $0.frame = bounds }
        CATransaction.commit()
        for page in [previousPage, currentPage] {
            page.bounds = bounds
            page.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        themeVideo.frame = bounds
    }

    // MARK: - API

    /// Load the backdrop for `url`. `paging` slides the new art in from the
    /// selected edge (a hero page change); otherwise it crossfades. Nil shows
    /// the placeholder.
    func setBackdrop(url: URL?, item: MediaItemRef? = nil, host: UIViewController? = nil, paging: HeroPageDirection? = nil) {
        // The clip follows the title, not the artwork: episodes share images.
        if url != currentURL {
            isChangingBackdrop = true
            updateThemeVideoSuspension()
            finishPageAnimation()
        }
        themeVideo.configure(item: item, host: host)
        guard url != currentURL else { return }
        loadTask?.cancel()

        guard let url else {
            currentURL = nil
            finishPageAnimation()
            isChangingBackdrop = false
            updateThemeVideoSuspension()
            for page in [previousPage, currentPage] {
                page.imageView.image = nil
                page.alpha = 0
            }
            return
        }
        currentURL = url

        // A prefetched image slides at once, on the same beat as the text.
        if let image = ImageCacheManager.shared.cachedImage(for: url, quality: .full) {
            show(image, paging: paging)
            return
        }
        loadTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.imageFullSize(for: url)
            guard !Task.isCancelled, let self, self.currentURL == url else { return }
            // Home waits behind this callback, so an image that fails must fire it too.
            guard let image else {
                self.isChangingBackdrop = false
                self.updateThemeVideoSuspension()
                self.onFirstImageLoaded?()
                return
            }
            self.show(image, paging: paging)
        }
    }

    private func show(_ image: UIImage, paging: HeroPageDirection?) {
        finishPageAnimation()
        guard currentPage.imageView.image != nil, currentPage.alpha > 0 else {
            currentPage.imageView.image = image
            currentPage.setOffset(0)
            currentPage.alpha = 1
            isChangingBackdrop = false
            updateThemeVideoSuspension()
            onFirstImageLoaded?()
            return
        }
        swap(&currentPage, &previousPage)
        bringSubviewToFront(currentPage)
        bringSubviewToFront(themeVideo)
        scrimLayers.forEach { layer.addSublayer($0) }  // keep the scrim on top
        currentPage.imageView.image = image

        guard let paging else {
            currentPage.setOffset(0)
            currentPage.alpha = 0
            UIView.animate(withDuration: crossfadeDuration, delay: 0, options: [.curveEaseInOut]) {
                self.currentPage.alpha = 1
            } completion: { _ in
                self.previousPage.alpha = 0
                self.previousPage.imageView.image = nil
            }
            isChangingBackdrop = false
            updateThemeVideoSuspension()
            onFirstImageLoaded?()
            return
        }

        let width = bounds.width * paging.rawValue
        currentPage.alpha = 1
        currentPage.setOffset(width)
        let animator = Self.pageAnimator()
        animator.addAnimations {
            self.currentPage.setOffset(0)
            self.previousPage.setOffset(-width)
        }
        animator.addCompletion { [weak self] _ in
            guard let self, self.pageAnimator != nil else { return }
            self.pageAnimator = nil
            self.settlePages()
            self.isChangingBackdrop = false
            self.updateThemeVideoSuspension()
        }
        pageAnimator = animator
        animator.startAnimation()
        onFirstImageLoaded?()
    }

    /// Whether the hero's page is on screen (Home visible, no other page on top).
    func setActive(_ active: Bool) { themeVideo.setActive(active) }

    private func updateThemeVideoSuspension() {
        themeVideo.setSuspended(!isShowcased || isHidden || isChangingBackdrop)
    }

    /// Jumps an in-flight page slide to its end so the next one starts clean.
    private func finishPageAnimation() {
        guard let animator = pageAnimator else { return }
        pageAnimator = nil
        if animator.state == .active {
            animator.stopAnimation(false)
            animator.finishAnimation(at: .end)
        }
        settlePages()
    }

    private func settlePages() {
        currentPage.setOffset(0)
        previousPage.setOffset(0)
        previousPage.alpha = 0
        previousPage.imageView.image = nil
    }

    /// Scroll-driven lift (Apple's showcase scroll, `s` = scroll past rest):
    /// the backdrop rises faster than the content until its bottom edge meets
    /// the first shelf, then moves with it. `shelfTop` is where the first shelf
    /// rests at offset 0.
    func applyScrollOffset(_ offset: CGFloat, shelfTop: CGFloat) {
        transform = CGAffineTransform(translationX: 0, y: -Self.scrollLift(offset, shelfTop: shelfTop, height: bounds.height))
        isShowcased = Self.showcasePercentage(offset, shelfTop: shelfTop) > 0
        updateThemeVideoSuspension()
    }

    /// Where the backdrop's bottom meets the floor line. Apple ends the catch-up
    /// at the offset that centres the first row (`d1`, 0x726a8c); y 325 is that
    /// point on Home, measured from the TV app.
    static let meetY: CGFloat = 325

    nonisolated static func scrollLift(_ offset: CGFloat, shelfTop: CGFloat, height: CGFloat) -> CGFloat {
        let s = max(0, offset)
        let travel = max(1, shelfTop - meetY)      // Apple's T
        let catchUp = max(0, height - shelfTop)     // Apple's A
        return s + catchUp * min(1, s / travel)
    }

    /// Apple's showcase percentage: 1 at rest, 0 once the shelf has caught up.
    nonisolated static func showcasePercentage(_ offset: CGFloat, shelfTop: CGFloat) -> CGFloat {
        let travel = max(1, shelfTop - meetY)
        return min(1, max(0, (1 - max(0, offset) / travel)))
    }
}

/// The timing Apple hands its page animator: a spring (mass 1, stiffness 100,
/// damping 22) composed with a cubic (0.05, 0)-(1, 1). UIKit decides how the
/// two combine, so passing both reproduces Apple's curve exactly.
final class HeroPageTiming: NSObject, UITimingCurveProvider {
    let timingCurveType: UITimingCurveType = .composed
    let cubicTimingParameters: UICubicTimingParameters? =
        UICubicTimingParameters(controlPoint1: CGPoint(x: 0.05, y: 0), controlPoint2: CGPoint(x: 1, y: 1))
    let springTimingParameters: UISpringTimingParameters? =
        UISpringTimingParameters(mass: 1, stiffness: 100, damping: 22, initialVelocity: .zero)

    override init() { super.init() }
    required init?(coder: NSCoder) { super.init() }
    func encode(with coder: NSCoder) {}
    func copy(with zone: NSZone? = nil) -> Any { HeroPageTiming() }
}
