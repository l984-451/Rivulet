// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The page's ambient color wash: one artwork stretched under the home's frosted material, plus a
// vignette that keeps the lower half dark. It follows the hero with a slow 0.6s crossfade, since a
// hard cut reads as the whole background flickering.

import UIKit

@MainActor
final class AmbientBackdropView: UIView {

    private let currentImageView = UIImageView()
    private let previousImageView = UIImageView()
    private let vignette = VignetteView()
    private var loadTask: Task<Void, Never>?
    private var clearPreviousTask: Task<Void, Never>?
    private var currentURL: URL?

    /// True once any artwork has been shown. The no-hero fallback uses this to
    /// avoid overwriting a wash the hero already established.
    var hasAmbient: Bool { currentURL != nil }

    /// Music's Now Playing shows the wash at full brightness, as Apple Music does,
    /// and reduces the artwork to its colours first.
    var showsVignette = true {
        didSet { vignette.isHidden = !showsVignette }
    }
    var imageTransform: (@Sendable (UIImage) -> UIImage)?

    /// The artwork any page washed last; Settings borrows it for its own background.
    static private(set) var lastURL: URL?

    private let crossfadeDuration: TimeInterval = 0.6
    private let imageAlpha: CGFloat = 0.85

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = .clear

        for iv in [previousImageView, currentImageView] {
            iv.contentMode = .scaleAspectFill
            iv.alpha = 0   // fades in when the artwork lands
            iv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iv)
            NSLayoutConstraint.activate([
                iv.topAnchor.constraint(equalTo: topAnchor),
                iv.bottomAnchor.constraint(equalTo: bottomAnchor),
                iv.leadingAnchor.constraint(equalTo: leadingAnchor),
                iv.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
        }

        vignette.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vignette)

        NSLayoutConstraint.activate([
            vignette.topAnchor.constraint(equalTo: topAnchor),
            vignette.bottomAnchor.constraint(equalTo: bottomAnchor),
            vignette.leadingAnchor.constraint(equalTo: leadingAnchor),
            vignette.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        loadTask?.cancel()
        clearPreviousTask?.cancel()
    }

    /// Set the ambient artwork. Crossfades from whatever is on screen. A nil URL
    /// or a repeat of the current URL is a no-op — the existing wash stays put
    /// rather than flashing to black between hero items that lack artwork.
    func setAmbient(url: URL?) {
        guard let url, url != currentURL else { return }
        currentURL = url
        Self.lastURL = url
        loadTask?.cancel()
        clearPreviousTask?.cancel()

        let oldImage = currentImageView.image
        loadTask = Task { [weak self] in
            var image = await ImageCacheManager.shared.image(for: url)
            // Off the main actor: Now Playing's transform resamples and redraws the cover.
            if let source = image, let transform = self?.imageTransform {
                image = await Task.detached { transform(source) }.value
            }
            guard let self, !Task.isCancelled, let image, self.currentURL == url else { return }
            self.applyImage(image, replacing: oldImage)
        }
    }

    private func applyImage(_ image: UIImage, replacing oldImage: UIImage?) {
        if let oldImage {
            previousImageView.image = oldImage
            previousImageView.alpha = imageAlpha
        } else {
            previousImageView.image = nil
            previousImageView.alpha = 0
        }
        currentImageView.image = image
        currentImageView.alpha = 0

        UIView.animate(withDuration: crossfadeDuration, delay: 0, options: [.curveEaseInOut]) {
            self.currentImageView.alpha = self.imageAlpha
            self.previousImageView.alpha = 0
        }

        guard oldImage != nil else { return }
        // Hold the outgoing image until the fade has fully settled, then drop it.
        let totalNs = UInt64(crossfadeDuration * 1_000_000_000) + 50_000_000
        clearPreviousTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: totalNs)
            guard let self, !Task.isCancelled else { return }
            self.previousImageView.image = nil
        }
    }

    /// Vertical scrim over the wash: brightest up top, dark behind the
    /// shelves — matches both reference shots. Plain gradient-backed UIView
    /// (layerClass) so it lays out via Auto Layout like everything else.
    private final class VignetteView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            let gradient = layer as! CAGradientLayer
            gradient.colors = [
                UIColor.black.withAlphaComponent(0.10).cgColor,
                UIColor.black.withAlphaComponent(0.25).cgColor,
                UIColor.black.withAlphaComponent(0.50).cgColor
            ]
            gradient.locations = [0, 0.55, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    }
}
