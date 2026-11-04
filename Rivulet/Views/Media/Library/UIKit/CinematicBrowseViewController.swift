// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// A full-screen, one-title-at-a-time library browser. The owning library supplies
/// its sparse slots and paging, so this preserves its sort order and provider.
final class CinematicBrowseViewController: UIViewController {
    var onRequestItem: ((Int) -> Void)?
    var onSelectItem: ((MediaItem) -> Void)?
    private(set) var selectedIndex: Int
    private var items: [MediaItem]
    private var displayedItem: MediaItem?
    private var loadTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private let surface = BrowseSurface()
    private let ambient = AmbientBackdropView()
    private let content = UIView()
    private let poster = UIImageView()
    private let titleLabel = UILabel()
    private let metadata = UILabel()
    private let credits = UILabel()
    private let runtime = UILabel()
    private let position = UILabel()
    private let upChevron = UIImageView(image: UIImage(systemName: "chevron.up"))
    private let downChevron = UIImageView(image: UIImage(systemName: "chevron.down"))
    private var transitionSnapshot: UIView?
    private var direction: CGFloat = 1

    init(items: [MediaItem], selectedIndex: Int = 0) {
        self.items = items
        self.selectedIndex = min(max(0, selectedIndex), max(0, items.count - 1))
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    deinit { loadTask?.cancel(); detailTask?.cancel() }

    override func loadView() { view = surface }
    override var preferredFocusEnvironments: [UIFocusEnvironment] { [surface] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CinematicStyle.background
        ambient.usesHeroEdgeColors = true
        ambient.alpha = 0.45
        view.addSubview(ambient)
        view.addSubview(content)
        poster.contentMode = .scaleAspectFit
        poster.clipsToBounds = true
        titleLabel.font = .systemFont(ofSize: 64, weight: .bold)
        titleLabel.numberOfLines = 4
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.65
        metadata.font = .systemFont(ofSize: 26, weight: .medium)
        credits.font = .systemFont(ofSize: 25)
        credits.numberOfLines = 3
        runtime.font = .systemFont(ofSize: 25)
        for label in [titleLabel, metadata, credits, runtime] {
            label.textColor = label === titleLabel ? .white : CinematicStyle.secondaryText
            label.textAlignment = .right
            content.addSubview(label)
        }
        content.addSubview(poster)
        position.font = .systemFont(ofSize: 22)
        position.textColor = CinematicStyle.secondaryText
        view.addSubview(position)
        for chevron in [upChevron, downChevron] {
            chevron.tintColor = CinematicStyle.secondaryText
            chevron.contentMode = .scaleAspectFit
            view.addSubview(chevron)
        }
        surface.onMove = { [weak self] in self?.move(by: $0) }
        surface.onSelect = { [weak self] in self?.selectCurrent() }
        surface.onBack = { [weak self] in self?.dismiss(animated: true) }
        for direction in [UISwipeGestureRecognizer.Direction.up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
        }
        showSelection()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        ambient.frame = view.bounds
        content.frame = view.bounds
        let width = view.bounds.width, height = view.bounds.height
        poster.frame = CGRect(x: width * 0.08, y: 0, width: width * 0.40, height: height)
        let textX = width * 0.54, textWidth = width * 0.40
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: textWidth, height: height * 0.38)).height
        titleLabel.frame = CGRect(x: textX, y: height * 0.50 - titleHeight / 2,
                                 width: textWidth, height: min(titleHeight, height * 0.38))
        metadata.frame = CGRect(x: textX, y: titleLabel.frame.minY - 60, width: textWidth, height: 36)
        credits.frame = CGRect(x: textX, y: titleLabel.frame.maxY + 30, width: textWidth, height: 110)
        runtime.frame = CGRect(x: textX, y: height - 150, width: textWidth, height: 36)
        position.frame = CGRect(x: 24, y: height / 2 - 60, width: width * 0.06, height: 120)
        position.numberOfLines = 3
        position.textAlignment = .center
        upChevron.frame = CGRect(x: position.frame.midX - 12, y: position.frame.minY - 42, width: 24, height: 18)
        downChevron.frame = CGRect(x: position.frame.midX - 12, y: position.frame.maxY + 24, width: 24, height: 18)
    }

    /// Called when the owning library resolves a sparse page or changes its total.
    func update(items: [MediaItem]) {
        self.items = items
        selectedIndex = min(selectedIndex, max(0, items.count - 1))
        guard isViewLoaded else { return }
        if items.isEmpty || items[selectedIndex] != displayedItem { showSelection() }
        updatePosition()
    }

    func move(by delta: Int) {
        let next = min(max(0, selectedIndex + delta), max(0, items.count - 1))
        guard next != selectedIndex else { return }
        direction = delta > 0 ? 1 : -1
        selectedIndex = next
        showSelection()
    }

    func pageLoadFailed(in range: Range<Int>) {
        guard range.contains(selectedIndex), items.indices.contains(selectedIndex),
              items[selectedIndex].isGridPlaceholder else { return }
        loadTask?.cancel()
        displayedItem = nil
        poster.image = nil
        titleLabel.text = String(localized: "Couldn't Load This Title")
        metadata.text = nil
        credits.text = String(localized: "Press Select to try again, or browse to another title.")
        runtime.text = nil
        surface.accessibilityLabel = titleLabel.text
        view.setNeedsLayout()
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        move(by: gesture.direction == .up ? 1 : -1)
    }

    private func updatePosition() {
        upChevron.alpha = selectedIndex > 0 ? 1 : 0.2
        downChevron.alpha = selectedIndex + 1 < items.count ? 1 : 0.2
        position.text = items.isEmpty ? "0" : "\(selectedIndex + 1)\n/\n\(items.count)"
        surface.accessibilityValue = String(localized: "Item \(items.isEmpty ? 0 : selectedIndex + 1) of \(items.count)")
    }

    private func showSelection() {
        loadTask?.cancel()
        detailTask?.cancel()
        updatePosition()
        guard items.indices.contains(selectedIndex) else {
            displayedItem = nil
            poster.image = nil
            titleLabel.text = String(localized: "No Titles")
            metadata.text = nil
            credits.text = nil
            runtime.text = nil
            surface.accessibilityLabel = titleLabel.text
            view.setNeedsLayout()
            return
        }
        onRequestItem?(selectedIndex)
        onRequestItem?(selectedIndex + 12)
        onRequestItem?(selectedIndex - 12)
        let item = items[selectedIndex]
        guard !item.isGridPlaceholder else { return }
        let index = selectedIndex
        loadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let url = item.artwork.poster ?? item.artwork.backdrop ?? item.artwork.thumbnail
            let image: UIImage?
            if let url { image = await ImageCacheManager.shared.image(for: url, quality: .full) } else { image = nil }
            guard !Task.isCancelled, let self, self.selectedIndex == index else { return }
            self.render(item, image: image)
            self.loadCredits(item)
        }
    }

    private func render(_ item: MediaItem, image: UIImage?) {
        transitionSnapshot?.removeFromSuperview()
        content.layer.removeAllAnimations()
        content.alpha = 1
        content.transform = .identity
        let outgoing = UIAccessibility.isReduceMotionEnabled ? nil : content.snapshotView(afterScreenUpdates: false)
        if let outgoing { outgoing.frame = content.frame; view.insertSubview(outgoing, aboveSubview: content) }
        transitionSnapshot = outgoing
        displayedItem = item
        poster.image = image ?? UIImage(systemName: "film")
        poster.tintColor = .secondaryLabel
        titleLabel.text = item.title
        metadata.text = CinematicStyle.metadata(for: item)
        credits.text = nil
        runtime.text = item.runtime.flatMap { $0 > 0 ? String(localized: "Running time \(Int($0 / 60)) min") : nil }
        surface.accessibilityLabel = [item.title, metadata.text, runtime.text].compactMap { $0 }.joined(separator: ", ")
        ambient.setAmbient(url: item.artwork.poster ?? item.artwork.backdrop)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        guard let outgoing else { return }
        content.alpha = 0
        content.transform = CGAffineTransform(translationX: 0, y: direction * 28)
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.content.alpha = 1
            self.content.transform = .identity
            outgoing.alpha = 0
            outgoing.transform = CGAffineTransform(translationX: 0, y: -self.direction * 28)
        } completion: { _ in outgoing.removeFromSuperview() }
    }

    private func loadCredits(_ item: MediaItem) {
        detailTask = Task { [weak self] in
            guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID),
                  let detail = try? await provider.fullDetail(for: item.ref), !Task.isCancelled,
                  let self, self.displayedItem?.ref == item.ref else { return }
            let directors = detail.directors.map(\.name).joined(separator: ", ")
            let studio = detail.studios.joined(separator: ", ")
            self.credits.text = [directors.isEmpty ? nil : String(localized: "Directed by \(directors)"),
                                 studio.isEmpty ? nil : studio].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private func selectCurrent() {
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        guard !item.isGridPlaceholder else { showSelection(); return }
        onSelectItem?(item)
    }
}

private final class BrowseSurface: UIView {
    var onMove: ((Int) -> Void)?
    var onSelect: (() -> Void)?
    var onBack: (() -> Void)?
    override var canBecomeFocused: Bool { true }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = [.button, .adjustable]
        accessibilityHint = String(localized: "Browse up or down. Select to open details.")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityIncrement() { onMove?(1) }
    override func accessibilityDecrement() { onMove?(-1) }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .upArrow }) { onMove?(-1); return }
        if presses.contains(where: { $0.type == .downArrow }) { onMove?(1); return }
        if presses.contains(where: { $0.type == .select || $0.type == .menu }) { return }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { onSelect?(); return }
        if presses.contains(where: { $0.type == .menu }) { onBack?(); return }
        super.pressesEnded(presses, with: event)
    }
}
