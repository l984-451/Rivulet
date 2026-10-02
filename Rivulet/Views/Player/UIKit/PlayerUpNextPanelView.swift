// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerUpNextPanelView.swift
//  Rivulet
//
//  Up Next content for the shared rail panel (Task 6). Pure list
//  content — no glass chrome, no collapsed/expanded state machine.
//  The panel presenter (PlayerRailPanelView, via
//  PlayerContainerViewController.presentRailPanel) owns the floating
//  chrome and width; this view only builds the header + scrollable
//  row list and reports its preferred initial focus (the up-next
//  row, scrolled into view). A fresh instance is built per
//  presentation, so there's no setEpisodes statefulness to manage.
//

import UIKit

final class UpNextListView: UIView {

    private enum Metrics {
        static let maxHeight: CGFloat = 520
        // Horizontal inset for the row stack inside the scroll view so a
        // focused row's 1.02 scale doesn't overflow the clipping scroll
        // view at the left/right edges.
        static let rowInset: CGFloat = 8
    }

    private let onSelect: (PlexMetadata) -> Void
    private let headerLabel = UILabel()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var rows: [UpNextRowButton] = []
    /// Pin focus to the up-next row only for the FIRST landing; afterwards
    /// express no preference so the focus engine leaves focus where the user
    /// navigated (no bounce back up from the bottom of the list). See the
    /// matching flag in CardTrackListView.
    private var hasPinnedInitialFocus = false
    private weak var lastFocusedRow: UpNextRowButton?

    /// `thumbnailURL` answers a row's image URL when the item carries its
    /// own; nil (or a nil answer) builds the Plex thumbnail URL.
    init(episodes: [PlexMetadata], currentRatingKey: String?, seasonNumber: Int?,
         serverURL: String, authToken: String, thumbnailURL: ((PlexMetadata) -> URL?)? = nil,
         onSelect: @escaping (PlexMetadata) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
        setupContent()
        buildRows(episodes: episodes, currentRatingKey: currentRatingKey, seasonNumber: seasonNumber,
                   serverURL: serverURL, authToken: authToken, thumbnailURL: thumbnailURL)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContent() {
        stack.axis = .vertical
        stack.spacing = 8
        scrollView.addSubview(stack)
        scrollView.clipsToBounds = true

        [headerLabel, scrollView, stack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(headerLabel)
        addSubview(scrollView)

        // The scroll view grows with content up to a cap, so a short
        // season hugs its rows and a long one scrolls.
        let scrollHeight = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        scrollHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor),
            // Header stays flush with the rows' own (inset) content, not
            // the old view edge, so it aligns with row text/thumbnails
            // rather than the scroll view's outer bounds.
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.rowInset),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollHeight,
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.maxHeight),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Metrics.rowInset),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Metrics.rowInset),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -(Metrics.rowInset * 2)),
        ])
    }

    private func buildRows(episodes: [PlexMetadata], currentRatingKey: String?, seasonNumber: Int?,
                            serverURL: String, authToken: String, thumbnailURL: ((PlexMetadata) -> URL?)?) {
        let headerText = seasonNumber.map { "UP NEXT · SEASON \($0)" } ?? "UP NEXT"
        headerLabel.attributedText = NSAttributedString(
            string: headerText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.5),
                .kern: 1.5,
            ]
        )

        for episode in episodes {
            let state = UpNextRowState.state(for: episode, in: episodes, currentRatingKey: currentRatingKey)
            let row = UpNextRowButton(episode: episode, state: state, serverURL: serverURL, authToken: authToken,
                                      thumbnailURL: thumbnailURL?(episode))
            row.onTap = { [weak self] in self?.onSelect(episode) }
            stack.addArrangedSubview(row)
            rows.append(row)
        }
    }

    // MARK: - Teardown

    override func removeFromSuperview() {
        rows.forEach { $0.cancelImageLoad() }
        super.removeFromSuperview()
    }

    deinit {
        rows.forEach { $0.cancelImageLoad() }
    }

    // MARK: - Scroll-to-current

    private var didScrollToCurrent = false

    /// Positions the scroll view on the now-playing row instantly and
    /// invisibly, before the panel's rise-in animation renders its first
    /// visible frame. MUST be called by the presenter (PlayerRailPanelView)
    /// synchronously, after the panel has been given its real constraints
    /// and `layoutIfNeeded()` has resolved a real frame — NOT from
    /// `didMoveToWindow()`, which fires while this view is added to the
    /// window during `container.addSubview(panel)`, before the panel's own
    /// width/position constraints are activated. Calling `scrollToCurrentRow`
    /// against that not-yet-laid-out geometry produced a wrong initial
    /// offset that then visibly corrected itself (looked like an animated
    /// scroll from episode 1 to the current row) once real layout landed.
    /// Idempotent — only the first call does anything.
    func prepareForPresentation() {
        guard !didScrollToCurrent else { return }
        didScrollToCurrent = true
        scrollToCurrentRow()
    }

    private func scrollToCurrentRow() {
        guard let target = rows.first(where: { $0.rowState == .nowPlaying }) else { return }
        layoutIfNeeded()
        let targetFrame = target.convert(target.bounds, to: scrollView)
        scrollView.scrollRectToVisible(targetFrame.insetBy(dx: 0, dy: -(scrollView.bounds.height / 2 - targetFrame.height / 2)), animated: false)
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // After the first landing, hold the CURRENT row so a denied edge move
        // (Down at the last row / Up at the first, once the panel fence
        // refuses to let focus leave) re-resolves onto the row focus already
        // sits on rather than falling back to the first focusable — which
        // otherwise "looped" focus to the top. See CardTrackListView for the
        // full rationale; directional row-to-row moves never consult this.
        if hasPinnedInitialFocus {
            return lastFocusedRow.map { [$0] } ?? []
        }
        // Land on the up-next row first (the collapsed row), then free movement.
        if let target = rows.first(where: { $0.rowState == .upNext }) ?? rows.first { return [target] }
        return [self]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // Once focus enters any of our rows, stop pinning the up-next row and
        // remember which row holds focus (see preferredFocusEnvironments).
        if let next = context.nextFocusedView,
           let row = rows.first(where: { next.isDescendant(of: $0) || next === $0 }) {
            hasPinnedInitialFocus = true
            lastFocusedRow = row
        }
    }
}

// MARK: - UpNextRowButton

final class UpNextRowButton: UIControl {

    let rowState: UpNextRowState
    var onTap: (() -> Void)?

    private let thumbView = UIImageView()
    private let accentBar = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var imageLoadTask: Task<Void, Never>?

    private static let restBackground = UIColor.white.withAlphaComponent(0.06)
    private static let restBackgroundClear = UIColor.clear
    private static let focusedBackground = UIColor.white.withAlphaComponent(0.16)
    private static let restBorder = UIColor.clear.cgColor
    private static let focusedBorder = UIColor.white.withAlphaComponent(0.25).cgColor
    private static let accentColor = UIColor(red: 143/255, green: 233/255, blue: 212/255, alpha: 1)

    init(episode: PlexMetadata, state: UpNextRowState, serverURL: String, authToken: String,
         thumbnailURL: URL? = nil) {
        self.rowState = state
        super.init(frame: .zero)
        setupViews(episode: episode)
        loadThumbnail(episode: episode, serverURL: serverURL, authToken: authToken, url: thumbnailURL)
        applyRestAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        imageLoadTask?.cancel()
    }

    override var canBecomeFocused: Bool { true }

    private func setupViews(episode: PlexMetadata) {
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Self.restBorder

        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.layer.cornerRadius = 8
        thumbView.layer.cornerCurve = .continuous
        thumbView.backgroundColor = UIColor.white.withAlphaComponent(0.08)

        accentBar.backgroundColor = Self.accentColor
        accentBar.isHidden = rowState != .nowPlaying

        let index = episode.index ?? 0
        let title = episode.title ?? ""
        titleLabel.text = "E\(index) · \(title)"
        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        subtitleLabel.text = Self.subtitleText(for: rowState, episode: episode)
        subtitleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        subtitleLabel.numberOfLines = 1

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.isUserInteractionEnabled = false

        [accentBar, thumbView, textStack].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 92),

            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            accentBar.widthAnchor.constraint(equalToConstant: 3),

            thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 120),
            thumbView.heightAnchor.constraint(equalToConstant: 68),

            textStack.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private static func subtitleText(for state: UpNextRowState, episode: PlexMetadata) -> String {
        let mins = (episode.duration ?? 0) / 60000
        switch state {
        case .watched: return "Watched"
        case .nowPlaying: return "Now playing"
        case .upNext: return "Up next · \(mins) min"
        case .future: return "\(mins) min"
        }
    }

    private func loadThumbnail(episode: PlexMetadata, serverURL: String, authToken: String, url: URL?) {
        guard let url = url ?? episode.thumb.flatMap({
            PlexNetworkManager.shared.buildThumbnailURL(
                serverURL: serverURL, authToken: authToken, thumbPath: $0, width: 300, height: 169)
        }) else { return }

        imageLoadTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled else { return }
            self.thumbView.image = image
        }
    }

    func cancelImageLoad() {
        imageLoadTask?.cancel()
        imageLoadTask = nil
    }

    private func applyRestAppearance() {
        backgroundColor = rowState == .upNext ? Self.restBackground : Self.restBackgroundClear
        layer.borderColor = Self.restBorder
        transform = .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.backgroundColor = isFocused ? Self.focusedBackground : (self.rowState == .upNext ? Self.restBackground : Self.restBackgroundClear)
            self.layer.borderColor = isFocused ? Self.focusedBorder : Self.restBorder
            self.transform = isFocused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
        }, completion: nil)
    }

    // Select does not fire .primaryActionTriggered on a plain UIControl on
    // tvOS; handle the press directly (same trap as CardTrackRowButton).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onTap?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}
