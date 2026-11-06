// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  All carousel artwork, behind the collection view. Each visible card gets its own
//  clipping window with an oversized, parallaxed image inside; a shared mask would let
//  panels bleed into each other. On expand the centred window grows to full screen.

import UIKit

final class BackdropPlaneView: UIView {
    /// A card-sized clipping `container` around a full-stage `imageView`; parallax moves the image inside it.
    private final class Panel {
        let container = UIView()
        let imageView = UIImageView()
        /// Black wash above the artwork; alpha follows the card's distance from centre.
        let dimView = UIView()
        var index: Int
        var loadToken: UInt64 = 0
        var loadTask: Task<Void, Never>?
        deinit { loadTask?.cancel() }
        init(index: Int) {
            self.index = index
            container.clipsToBounds = true
            container.backgroundColor = .black
            container.layer.cornerCurve = .continuous
            // Round only the TOP corners. The card extends to the screen bottom
            // and reads as bleeding off-screen toward the below-fold content,
            // connecting the poster to the details (Apple TV+ look).
            container.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = false
            imageView.isOpaque = true
            imageView.backgroundColor = .black
            container.addSubview(imageView)
            dimView.backgroundColor = .black
            dimView.alpha = 0
            container.addSubview(dimView)
        }
    }

    /// Active panels keyed by movie index.
    private var panels: [Int: Panel] = [:]

    /// Current corner radius for the window containers. Lerped during morph.
    private var windowCornerRadius: CGFloat = PreviewCarouselGeometry.cornerRadius

    /// Items provider injected by the VC.
    private var items: [MediaItem] = []
    /// Detail can resolve a larger variant without replacing browse/watch state.
    private var resolvedArtwork: [MediaItemRef: URL] = [:]

    /// While a morph is in flight, sync() is suppressed so the morph
    /// controller has exclusive control of the centered panel's frames.
    var isMorphing: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Apple's surround grey; shows in the top strip and the gaps between cards.
        backgroundColor = UIColor(white: 0.16, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not Storyboard-backed") }

    func configure(items: [MediaItem]) {
        self.items = items
        resolvedArtwork.removeAll()
        for panel in panels.values {
            panel.loadTask?.cancel()
            panel.container.removeFromSuperview()
        }
        panels.removeAll()
    }

    /// Only replace this plane's artwork, never the item's identity or watch state.
    func updateArtwork(_ artwork: MediaArtwork, for ref: MediaItemRef) {
        guard let index = items.firstIndex(where: { $0.ref == ref }),
              let url = artwork.backdrop ?? items[index].artwork.backdrop
                ?? artwork.poster ?? items[index].artwork.poster,
              url != artworkURL(for: index) else { return }
        resolvedArtwork[ref] = url
        for (index, panel) in panels where items[index].ref == ref {
            loadArtwork(into: panel)
        }
    }

    func artworkURL(for index: Int) -> URL? {
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        return resolvedArtwork[item.ref] ?? item.artwork.backdrop ?? item.artwork.poster
    }

    // MARK: - Carousel-mode sync

    /// Position one self-clipping window container per visible card, each
    /// holding an oversized image centered on the window + parallax.
    /// Called every scroll tick. Suppressed while morphing.
    func sync(to layout: PreviewCarouselLayout, offset: CGPoint) {
        guard !isMorphing else { return }
        let stage = bounds.size
        let visible = layout.visibleIndices(at: offset)

        // Recycle panels that scrolled away.
        for (idx, panel) in panels where !visible.contains(idx) {
            panel.loadTask?.cancel()
            panel.container.removeFromSuperview()
            panels[idx] = nil
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for idx in visible {
            guard idx >= 0 && idx < items.count else { continue }
            let panel = panels[idx] ?? makePanel(for: idx)

            // Card window in VIEWPORT (plane) coords.
            let cardContent = layout.cardFrame(for: idx)
            let cardWindow = CGRect(
                x: cardContent.origin.x - offset.x,
                y: cardContent.origin.y - offset.y,
                width: cardContent.width,
                height: cardContent.height
            )

            // Container = the window. It clips its oversized image.
            panel.container.frame = cardWindow
            panel.container.layer.cornerRadius = windowCornerRadius
            // The dim follows horizontal position only, never the morph: a
            // morph-timed fade on the peeks is what ripped (see expandPanel).
            panel.dimView.frame = CGRect(origin: .zero, size: cardWindow.size)
            panel.dimView.alpha = PreviewCarouselGeometry.neighbourDimAlpha
                * abs(layout.normalizedPosition(for: idx))

            // X: window-centred plus parallax, which cancels about 80% of the card's
            // travel (Apple's formula). Y: pinned to screen 0, so expand never drifts
            // vertically; the centred card (parallax 0) lands on expandPanel's endpoint.
            let parallax = layout.parallaxOffset(for: idx)
            panel.imageView.frame = CGRect(
                x: (cardWindow.width - stage.width) / 2 + parallax,
                y: -cardWindow.origin.y,
                width: stage.width,
                height: stage.height
            )
        }
        CATransaction.commit()
    }

    private func makePanel(for index: Int) -> Panel {
        let panel = Panel(index: index)
        addSubview(panel.container)
        panels[index] = panel
        loadArtwork(into: panel)
        return panel
    }

    private func loadArtwork(into panel: Panel) {
        guard panel.index >= 0 && panel.index < items.count else { return }
        panel.loadTask?.cancel()
        panel.loadToken &+= 1
        let token = panel.loadToken
        // Backdrop falls back to poster. This plane fills most of the screen in
        // both carousel and expanded-detail, so decode at full quality.
        guard let url = artworkURL(for: panel.index) else {
            panel.imageView.image = nil
            return
        }
        // In memory: draw now. Otherwise fade it in when it lands, never pop.
        if let cached = ImageCacheManager.shared.cachedImage(for: url, quality: .full) {
            panel.imageView.image = cached
            return
        }
        // Keep the existing image visible while a higher-quality detail variant loads.
        panel.loadTask = Task { [weak panel] in
            let image = await ImageCacheManager.shared.image(for: url, quality: .full)
            await MainActor.run {
                guard !Task.isCancelled, let panel, panel.loadToken == token, let image else { return }
                UIView.transition(with: panel.imageView, duration: 0.5, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    panel.imageView.image = image
                }
            }
        }
    }

    /// The artwork already loaded for `index`, for the shelf flight's cards.
    func image(for index: Int) -> UIImage? { panels[index]?.imageView.image }

    // MARK: - Morph hooks (driven by CarouselMorphController)

    /// Current viewport frame of the panel container at `index`. Used by
    /// the morph controller as the morph's start frame.
    func panelRect(for index: Int) -> CGRect {
        return panels[index]?.container.frame ?? .zero
    }

    /// Grows the centred panel to `rect` inside the morph animator's block. Requires `isMorphing`.
    func expandPanel(_ index: Int, to rect: CGRect) {
        guard let panel = panels[index] else { return }
        // On top, so growing covers the peeks. Do not alpha-fade them: a fade off the
        // geometry's timeline tears the peeks mid-morph.
        bringSubviewToFront(panel.container)
        panel.container.frame = rect
        panel.imageView.frame = CGRect(origin: .zero, size: rect.size)
        panel.dimView.frame = panel.imageView.frame
    }

    /// Reverse of expandPanel: shrink the centered panel's container back
    /// to its carousel window, restore its oversized centered image, and
    /// reveal the other panels. Called inside the (reversed) morph block.
    func collapsePanel(_ index: Int, to window: CGRect, parallax: CGFloat, stage: CGSize) {
        guard let panel = panels[index] else { return }
        // On top for the whole collapse: panels stack by add order, so a higher-index
        // peek would fade in over the shrinking card's edge.
        bringSubviewToFront(panel.container)
        panel.container.frame = window
        // Carousel endpoint — must match sync() exactly: X window-centered +
        // parallax (travels with the card), Y screen-pinned (-window.origin.y).
        panel.imageView.frame = CGRect(
            x: (window.width - stage.width) / 2 + parallax,
            y: -window.origin.y,
            width: stage.width,
            height: stage.height
        )
        panel.dimView.frame = CGRect(origin: .zero, size: window.size)
        // Peeks were never alpha-hidden (see expandPanel) — they sit at their
        // carousel frames and are revealed geometrically as the centered card
        // shrinks. Nothing to restore here.
    }

    /// Set per display-link tick by the morph, with CA actions off so no tick spawns an implicit animation.
    func setWindowCornerRadius(_ radius: CGFloat, for index: Int) {
        windowCornerRadius = radius
        guard let panel = panels[index] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.container.layer.cornerRadius = radius
        CATransaction.commit()
    }
}
