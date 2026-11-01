// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The person page's header: a circular portrait, the name and a truncated bio. The bio
//  sits in a focusable glass panel whose Select opens the full bio; MORE shows on overflow.

import UIKit

final class PersonHeaderCell: UICollectionViewCell {

    static let reuseID = "PersonHeaderCell"

    /// Bio is truncated to this many lines; MORE appears only when it overflows.
    private static let bioLineLimit = 3

    // Metrics measured on device, tvOS 27.
    private static let nameFont = UIFont.systemFont(ofSize: 57, weight: .medium)
    private static let bioFont = UIFont.systemFont(ofSize: 25, weight: .regular)
    private static let moreFont = UIFont.systemFont(ofSize: 23, weight: .semibold)
    private static let bioLinePitch: CGFloat = 32

    private static let portraitSize: CGFloat = 250
    private static let portraitTextGap: CGFloat = 50
    private static let textColumnWidth: CGFloat = 844
    /// Name baseline to the bio's first cap top.
    private static let nameToBioCapGap: CGFloat = 38.5
    /// Focus panel overhang around the bio text.
    private static let panelPad: CGFloat = 15

    private let headerContent = UIView()
    private let portraitContainer = UIView()
    private let portraitImageView = UIImageView()
    private let fallbackIcon = UIImageView()
    private let nameLabel = UILabel()
    /// Focusable bio; shows a glass panel only while focused.
    private let bioPanel = BioPanel()
    private let bioLabel = UILabel()
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

        bioPanel.translatesAutoresizingMaskIntoConstraints = false
        bioPanel.isHidden = true
        bioPanel.onPrimaryAction = { [weak self] in self?.onMore?() }
        headerContent.addSubview(bioPanel)

        // MORE rides inline after the ellipsis (built in updateBioText).
        bioLabel.translatesAutoresizingMaskIntoConstraints = false
        bioLabel.font = Self.bioFont
        bioLabel.textColor = .white
        bioLabel.numberOfLines = Self.bioLineLimit
        bioLabel.lineBreakMode = .byTruncatingTail
        bioLabel.isUserInteractionEnabled = false
        bioPanel.addSubview(bioLabel)

        // Loading spinner: centered in the panel (the panel is already at its
        // final 3-line height, so the spinner sits in that reserved space).
        // Shown only while the biography is loading.
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.color = UIColor.white.withAlphaComponent(0.85)
        loadingSpinner.hidesWhenStopped = true
        bioPanel.addSubview(loadingSpinner)

        // Portrait left, text column right, the pair centred; the column is centred on the portrait.
        let containerWidth = Self.portraitSize + Self.portraitTextGap + Self.textColumnWidth
        let textColumn = UIView()
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        headerContent.addSubview(textColumn)
        // Bio line box top = name baseline + gap - the cap's offset inside a pitch-high line.
        let bioBoxTop = Self.nameFont.ascender + Self.nameToBioCapGap
            - (Self.bioLinePitch - Self.bioFont.lineHeight + Self.bioFont.ascender - Self.bioFont.capHeight)
        NSLayoutConstraint.activate([
            headerContent.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            headerContent.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerContent.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            headerContent.widthAnchor.constraint(equalToConstant: containerWidth),

            portraitContainer.topAnchor.constraint(equalTo: headerContent.topAnchor),
            portraitContainer.leadingAnchor.constraint(equalTo: headerContent.leadingAnchor),
            portraitContainer.widthAnchor.constraint(equalToConstant: Self.portraitSize),
            portraitContainer.heightAnchor.constraint(equalToConstant: Self.portraitSize),
            portraitContainer.bottomAnchor.constraint(equalTo: headerContent.bottomAnchor),

            portraitImageView.topAnchor.constraint(equalTo: portraitContainer.topAnchor),
            portraitImageView.leadingAnchor.constraint(equalTo: portraitContainer.leadingAnchor),
            portraitImageView.trailingAnchor.constraint(equalTo: portraitContainer.trailingAnchor),
            portraitImageView.bottomAnchor.constraint(equalTo: portraitContainer.bottomAnchor),

            fallbackIcon.centerXAnchor.constraint(equalTo: portraitContainer.centerXAnchor),
            fallbackIcon.centerYAnchor.constraint(equalTo: portraitContainer.centerYAnchor),

            textColumn.leadingAnchor.constraint(equalTo: portraitContainer.trailingAnchor, constant: Self.portraitTextGap),
            textColumn.widthAnchor.constraint(equalToConstant: Self.textColumnWidth),
            textColumn.centerYAnchor.constraint(equalTo: portraitContainer.centerYAnchor),
            textColumn.topAnchor.constraint(equalTo: nameLabel.topAnchor),
            textColumn.bottomAnchor.constraint(equalTo: bioLabel.bottomAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: textColumn.leadingAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: textColumn.trailingAnchor),

            bioLabel.topAnchor.constraint(equalTo: nameLabel.topAnchor, constant: bioBoxTop),
            bioLabel.leadingAnchor.constraint(equalTo: textColumn.leadingAnchor),
            bioLabel.trailingAnchor.constraint(equalTo: textColumn.trailingAnchor),
            // Fixed 3-line height so the panel is final-size from first paint.
            bioLabel.heightAnchor.constraint(equalToConstant: Self.bioLinePitch * CGFloat(Self.bioLineLimit)),

            // The panel overhangs the text by panelPad on every side.
            bioPanel.topAnchor.constraint(equalTo: bioLabel.topAnchor, constant: -Self.panelPad),
            bioPanel.bottomAnchor.constraint(equalTo: bioLabel.bottomAnchor, constant: Self.panelPad),
            bioPanel.leadingAnchor.constraint(equalTo: bioLabel.leadingAnchor, constant: -Self.panelPad),
            bioPanel.trailingAnchor.constraint(equalTo: bioLabel.trailingAnchor, constant: Self.panelPad),

            loadingSpinner.centerXAnchor.constraint(equalTo: bioPanel.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: bioLabel.centerYAnchor),
        ])
    }

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
        self.fullBiography = bio.isEmpty && !isLoading ? String(localized: "No biography available.") : bio

        // The panel always shows (dots, bio, or a placeholder), so the page always has a focus target.
        if isLoading {
            bioPanel.isHidden = false
            loadingSpinner.startAnimating()
            bioLabel.isHidden = true
        } else {
            loadingSpinner.stopAnimating()
            bioLabel.isHidden = false
            bioPanel.isHidden = false
        }
        // Truncation needs the label's real width, so the text is set in layoutSubviews.
        builtBioKey = nil
        setNeedsLayout()

        loadPortrait(url: portraitURL)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateBioText()
    }

    private var builtBioKey: String?

    /// Sets the bio at the line pitch; when it overflows three lines, cuts the third at "... MORE".
    private func updateBioText() {
        let width = bioLabel.bounds.width
        guard let bio = fullBiography, !bio.isEmpty, width > 1 else { return }
        let key = "\(Int(width))|\(bio)"
        guard key != builtBioKey else { return }
        builtBioKey = key

        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = Self.bioLinePitch
        para.maximumLineHeight = Self.bioLinePitch
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.bioFont, .foregroundColor: UIColor.white, .paragraphStyle: para]
        let moreAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.moreFont, .foregroundColor: UIColor.white.withAlphaComponent(0.5), .paragraphStyle: para]

        let full = NSAttributedString(string: bio, attributes: attrs)
        let typesetter = CTTypesetterCreateWithAttributedString(full)
        let ns = bio as NSString
        var start = 0
        for _ in 0..<(Self.bioLineLimit - 1) where start < ns.length {
            start += CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
        }
        let lineEnd = start + CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
        guard start < ns.length, lineEnd < ns.length else { bioLabel.attributedText = full; return }

        // Shorten the third line until the ellipsis and MORE fit.
        let more = NSAttributedString(string: " MORE", attributes: moreAttrs)
        var end = lineEnd
        var tail = NSMutableAttributedString()
        while end > start {
            let head = ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            tail = NSMutableAttributedString(string: head + "\u{2026}", attributes: attrs)
            tail.append(more)
            if tail.size().width <= width { break }
            end -= 1
        }
        let result = NSMutableAttributedString(
            attributedString: full.attributedSubstring(from: NSRange(location: 0, length: start)))
        result.append(tail)
        bioLabel.attributedText = result
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
        bioLabel.attributedText = nil
        bioLabel.isHidden = false
        fullBiography = nil
        builtBioKey = nil
        bioPanel.isHidden = true
        loadingSpinner.stopAnimating()
        onMore = nil
    }

    // Plain content cell: never a focus target itself. The bio PANEL is the
    // focus target (focusable whenever a bio exists); otherwise focus falls
    // through to the poster rows. Matches AboutCollectionCell / ShelfRowCell.
    override var canBecomeFocused: Bool { false }
}

/// The focusable bio: invisible at rest, a glass panel with a rim when focused.
private final class BioPanel: UIControl {
    var onPrimaryAction: (() -> Void)?
    private var lastFire: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        addTarget(self, action: #selector(fire), for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { true }

    // A bare UIControl misses Select on tvOS, so presses fire too, debounced.
    @objc private func fire() {
        let now = CACurrentMediaTime()
        guard now - lastFire > 0.3 else { return }
        lastFire = now
        onPrimaryAction?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { fire(); return }
        super.pressesEnded(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { [weak self] in
            self?.transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
            self?.backgroundColor = focused ? UIColor.white.withAlphaComponent(0.06) : .clear
            self?.layer.borderColor = (focused ? UIColor.white.withAlphaComponent(0.35) : UIColor.clear).cgColor
        }
    }
}
