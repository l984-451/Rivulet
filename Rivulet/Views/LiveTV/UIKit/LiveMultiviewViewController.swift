// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveMultiviewViewController.swift
//  Rivulet
//
//  Multiview for the Browse layout, after the Apple TV app's: up to four live
//  channels at once, with sound following focus.
//
//  Two modes. Edit shows the tiles smaller with the layout switch and an
//  "Add More" row under them; watch lets the tiles fill the screen. The mode
//  changes when focus reaches the hint at the edge ("Swipe up to watch" at
//  the top of edit, the chevron at the bottom of watch), so a swipe and an
//  arrow press both work with no transport of their own.
//
//  Playback belongs to MultiStreamViewModel, the same model the SwiftUI
//  multiview uses. A session arrives running (from the full-screen player or
//  the Browse corner player) and leaves running (a tile taken full screen),
//  so moving between surfaces never re-tunes.
//

import UIKit
import Combine

final class LiveMultiviewViewController: UIViewController {

    enum Mode {
        case edit
        case watch
    }

    /// A tile taken full screen. The host presents the player adopting it
    /// once multiview has closed.
    var onWatchFullScreen: ((LiveTVSessionHandoff) -> Void)?
    /// Multiview closed with nothing handed on.
    var onExit: (() -> Void)?

    private let viewModel: MultiStreamViewModel
    private var mode: Mode = .edit
    private var tiles: [UUID: LiveMultiviewTileView] = [:]
    private var placeholderViews: [UIView] = []

    private let watchHint = LiveMultiviewHintView(pointsUp: true, text: "Swipe up to watch")
    private let editHint = LiveMultiviewHintView(pointsUp: false, text: nil)

    private let layoutButtons = UIStackView()
    private let focusLayoutButton = TransportControlButton(
        icon: nil, accessibilityLabel: "Focus Layout", diameter: 62)
    private let gridLayoutButton = TransportControlButton(
        icon: nil, accessibilityLabel: "Grid Layout", diameter: 62)

    private let addMoreLabel = UILabel()
    private var addMoreCollection: UICollectionView!
    /// Keyed by item id, so a card whose programme changes is refreshed in
    /// place instead of replaced (which would drop focus).
    private var addMoreSource: UICollectionViewDiffableDataSource<Int, String>!
    private var addMoreItems: [String: LiveCardItem] = [:]

    private var cancellables = Set<AnyCancellable>()
    /// Where focus goes on the next update, consumed once it lands.
    private weak var pendingFocus: UIView?
    private var isExiting = false
    private var lastLayoutKey: LayoutKey?

    private enum Metrics {
        static let side: CGFloat = 90
        static let gap: CGFloat = 36
        static let cardWidth: CGFloat = 340
        static let rowHeight: CGFloat = 250
    }

    init(adopting session: LiveTVSessionHandoff?, adding channel: UnifiedChannel?) {
        viewModel = MultiStreamViewModel(adopting: session, adding: channel)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.05, alpha: 1)

        view.addSubview(watchHint)
        view.addSubview(editHint)
        editHint.isHidden = true

        layoutButtons.axis = .horizontal
        layoutButtons.spacing = 24
        layoutButtons.addArrangedSubview(focusLayoutButton)
        layoutButtons.addArrangedSubview(gridLayoutButton)
        layoutButtons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(layoutButtons)
        focusLayoutButton.onPress = { [weak self] in self?.useFocusLayout() }
        gridLayoutButton.onPress = { [weak self] in self?.viewModel.resetLayout() }

        addMoreLabel.text = "Add More"
        addMoreLabel.font = .systemFont(ofSize: 32, weight: .semibold)
        addMoreLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        addMoreLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(addMoreLabel)

        setUpAddMoreRow()

        NSLayoutConstraint.activate([
            layoutButtons.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            layoutButtons.topAnchor.constraint(equalTo: view.topAnchor, constant: 650),

            addMoreLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.side),
            addMoreLabel.bottomAnchor.constraint(equalTo: addMoreCollection.topAnchor, constant: -4),

            addMoreCollection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            addMoreCollection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            addMoreCollection.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            addMoreCollection.heightAnchor.constraint(equalToConstant: Metrics.rowHeight),
        ])

        viewModel.$streams
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.streamsChanged() }
            .store(in: &cancellables)
        viewModel.$layoutMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout(animated: true) }
            .store(in: &cancellables)

        // What is on changes by the minute; the row follows the store.
        let store = LiveTVDataStore.shared
        Publishers.CombineLatest(store.$channels, store.$epg)
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.reloadAddMore() }
            .store(in: &cancellables)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        watchHint.frame = CGRect(x: Metrics.side, y: 16, width: bounds.width - Metrics.side * 2, height: 80)
        // Clear of the watch tiles even at their focused scale: anything over
        // the hint's frame would make it unfocusable, and Down could not
        // reach it.
        editHint.frame = CGRect(x: Metrics.side, y: bounds.height - 60, width: bounds.width - Metrics.side * 2, height: 56)
        relayout(animated: false)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let pendingFocus { return [pendingFocus] }
        if let tile = audibleTile ?? orderedTiles.first { return [tile] }
        return [addMoreCollection].compactMap { $0 }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView else { return }
        if next === pendingFocus { pendingFocus = nil }

        if next === watchHint {
            DispatchQueue.main.async { [weak self] in self?.setMode(.watch) }
        } else if next === editHint {
            DispatchQueue.main.async { [weak self] in self?.setMode(.edit) }
        } else if let tile = next as? LiveMultiviewTileView,
                  let index = viewModel.streams.firstIndex(where: { $0.id == tile.slotId }) {
            // Sound follows focus.
            viewModel.setFocus(to: index)
        }
    }

    // MARK: - Remote

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .menu:
                // The same funnel as the system's own Menu dismissal, so both
                // routes make one decision (see dismiss(animated:)).
                dismiss(animated: true)
                return
            case .playPause:
                viewModel.togglePlayPauseOnFocused()
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Taken at began; an ended phase reaching the system would act twice.
        if presses.contains(where: { $0.type == .menu || $0.type == .playPause }) { return }
        super.pressesEnded(presses, with: event)
    }

    /// Menu peels one layer at a time: watch back to edit, then (with more
    /// than one channel on) a confirmation, then out. The responder-chain
    /// press and tvOS's parallel system Menu gesture both land here.
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        if isExiting {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        // Checked before the presented case: the echo of the press that just
        // raised the exit confirmation must not take the confirmation down.
        if blockNextDismiss {
            blockNextDismiss = false
            completion?()
            return
        }
        // An alert or menu over multiview is closing itself.
        if presentedViewController != nil {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        if mode == .watch {
            setMode(.edit)
            armDismissEchoBlock()
            completion?()
            return
        }
        let confirm = UserDefaults.standard.object(forKey: "confirmExitMultiview") as? Bool ?? true
        if confirm && viewModel.streamCount > 1 {
            confirmExit()
            armDismissEchoBlock()
            completion?()
            return
        }
        exitMultiview(handingOff: nil)
    }

    /// After a Menu press peels a layer, swallow the system gesture's echo of
    /// the same press. Time-limited so it can never eat the next real one.
    private var blockNextDismiss = false
    private var blockResetWork: DispatchWorkItem?

    private func armDismissEchoBlock() {
        blockNextDismiss = true
        blockResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.blockNextDismiss = false }
        blockResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func confirmExit() {
        let alert = UIAlertController(title: "Do you want to exit Multiview?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Exit", style: .default) { [weak self] _ in
            self?.exitMultiview(handingOff: nil)
        })
        present(alert, animated: true)
    }

    /// Close multiview. Every tile stops except `session`, which goes to the
    /// host to play full screen.
    private func exitMultiview(handingOff session: LiveTVSessionHandoff?) {
        guard !isExiting else { return }
        isExiting = true
        for tile in tiles.values { tile.release() }
        viewModel.stopAllStreams()
        let onWatchFullScreen = onWatchFullScreen
        let onExit = onExit
        closeSelf {
            if let session {
                if let onWatchFullScreen {
                    onWatchFullScreen(session)
                } else {
                    session.stop()
                }
            } else {
                onExit?()
            }
        }
    }

    /// Dismissing a controller that is presenting something only takes that
    /// something down, so clear an alert or menu still on screen first.
    private func closeSelf(completion: @escaping () -> Void) {
        if let presented = presentedViewController {
            if presented.isBeingDismissed {
                // Already on its way out (an alert closing after its action):
                // a second dismiss would be dropped along with its completion.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.closeSelf(completion: completion)
                }
                return
            }
            presented.dismiss(animated: false) { [weak self] in
                self?.closeSelf(completion: completion)
            }
            return
        }
        super.dismiss(animated: true, completion: completion)
    }

    // MARK: - Mode

    private func setMode(_ newMode: Mode) {
        guard mode != newMode, !isExiting else { return }
        if newMode == .watch && viewModel.streams.isEmpty { return }
        mode = newMode
        let editing = newMode == .edit

        // Everything the new mode shows must be unhidden before focus moves,
        // and the old mode's controls hidden only after, or the engine picks
        // its own destination.
        if editing {
            watchHint.isHidden = viewModel.streams.isEmpty
            addMoreLabel.isHidden = false
            addMoreCollection.isHidden = false
            layoutButtons.isHidden = viewModel.streamCount < 2
        } else {
            editHint.isHidden = false
        }

        pendingFocus = audibleTile ?? orderedTiles.first
        setNeedsFocusUpdate()
        updateFocusIfNeeded()

        relayout(animated: true)
        UIView.animate(withDuration: 0.3, animations: {
            self.addMoreLabel.alpha = editing ? 1 : 0
            self.addMoreCollection.alpha = editing ? 1 : 0
            self.layoutButtons.alpha = editing ? 1 : 0
            self.watchHint.alpha = editing ? 1 : 0
            self.editHint.alpha = editing ? 0 : 1
            for tile in self.tiles.values { tile.setShowsCaption(editing) }
        }, completion: { _ in
            guard self.mode == newMode else { return }
            if editing {
                self.editHint.isHidden = true
            } else {
                self.watchHint.isHidden = true
                self.addMoreLabel.isHidden = true
                self.addMoreCollection.isHidden = true
                self.layoutButtons.isHidden = true
            }
        })
    }

    // MARK: - Tiles

    private var orderedTiles: [LiveMultiviewTileView] {
        viewModel.streams.compactMap { tiles[$0.id] }
    }

    private var audibleTile: LiveMultiviewTileView? {
        viewModel.streams.first(where: { !$0.isMuted }).flatMap { tiles[$0.id] }
    }

    private func streamsChanged() {
        let streams = viewModel.streams
        let ids = Set(streams.map(\.id))

        for (id, tile) in tiles where !ids.contains(id) {
            tile.release()
            tile.removeFromSuperview()
            tiles[id] = nil
        }
        for slot in streams {
            let tile: LiveMultiviewTileView
            if let existing = tiles[slot.id] {
                tile = existing
            } else {
                tile = LiveMultiviewTileView(slotId: slot.id)
                tile.alpha = 0
                tile.setShowsCaption(mode == .edit)
                tile.onSelect = { [weak self, weak tile] in
                    guard let self, let tile else { return }
                    self.tileSelected(tile)
                }
                tile.onLongPress = { [weak self, weak tile] in
                    guard let self, let tile else { return }
                    self.presentTileMenu(for: tile)
                }
                view.insertSubview(tile, belowSubview: watchHint)
                tiles[slot.id] = tile
            }
            tile.show(slot)
        }

        if mode == .edit {
            layoutButtons.isHidden = streams.count < 2
            layoutButtons.alpha = 1
            // Nothing to watch yet: Up has nowhere to go.
            watchHint.isHidden = streams.isEmpty
        }
        updateLayoutButtonIcons()
        reloadAddMore()
        relayout(animated: true)

        if streams.isEmpty && mode == .watch {
            setMode(.edit)
        }
    }

    private func tileSelected(_ tile: LiveMultiviewTileView) {
        // Watching: Select makes the tile the big one. Editing: the options.
        if mode == .watch, viewModel.streamCount > 1 {
            viewModel.setFocusedLayout(on: tile.slotId)
        } else {
            presentTileMenu(for: tile)
        }
    }

    private func presentTileMenu(for tile: LiveMultiviewTileView) {
        guard let index = viewModel.streams.firstIndex(where: { $0.id == tile.slotId }) else { return }
        let slot = viewModel.streams[index]
        var actions: [TileMenuAction] = []
        actions.append(TileMenuAction(title: "Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { [weak self] in
            self?.takeFullScreen(slotId: slot.id)
        })
        if viewModel.streamCount > 1 {
            var isMain = false
            if case .focus(let mainId) = viewModel.layoutMode { isMain = mainId == slot.id }
            if !isMain {
                actions.append(TileMenuAction(title: "Make Main", systemImage: "rectangle.inset.filled") { [weak self] in
                    self?.viewModel.setFocusedLayout(on: slot.id)
                })
            }
        }
        let remove = TileMenuAction(title: "Remove", systemImage: "xmark", destructive: true) { [weak self] in
            guard let self, let index = self.viewModel.streams.firstIndex(where: { $0.id == slot.id }) else { return }
            if self.viewModel.streamCount <= 1 {
                self.exitMultiview(handingOff: nil)
            } else {
                self.viewModel.removeStream(at: index)
            }
        }
        let header = TileMenuHeader(
            title: slot.currentProgram?.title ?? slot.channel.name,
            detail: [slot.channel.channelNumber.map(String.init), slot.channel.name]
                .compactMap { $0 }
                .joined(separator: " · ")
        )
        let popup = TileMenuPopupViewController(
            sections: [actions, [remove]],
            sourceFrame: tile.convert(tile.bounds, to: nil),
            header: header
        )
        present(popup, animated: false)
    }

    private func takeFullScreen(slotId: UUID) {
        guard let index = viewModel.streams.firstIndex(where: { $0.id == slotId }) else { return }
        guard let session = viewModel.detachStream(at: index) else {
            // Still joining: nothing to carry over yet.
            return
        }
        tiles[slotId]?.release()
        exitMultiview(handingOff: session)
    }

    private func useFocusLayout() {
        let target = viewModel.streams.first(where: { !$0.isMuted }) ?? viewModel.streams.first
        if let target { viewModel.setFocusedLayout(on: target.id) }
    }

    private func updateLayoutButtonIcons() {
        let focused = viewModel.isFocusLayout
        let many = viewModel.streamCount > 2
        focusLayoutButton.setIcon(UIImage(systemName: focused ? "rectangle.righthalf.inset.filled" : "sidebar.right"))
        let grid = many ? "rectangle.split.2x2" : "rectangle.split.2x1"
        gridLayoutButton.setIcon(UIImage(systemName: focused ? grid : grid + ".fill"))
    }

    // MARK: - Layout

    private struct LayoutKey: Equatable {
        let ids: [UUID]
        let mainId: UUID?
        let mode: Mode
        let placeholder: Bool
        let size: CGSize
    }

    private func relayout(animated: Bool) {
        guard isViewLoaded, view.bounds.width > 0 else { return }
        updateLayoutButtonIcons()

        let streams = viewModel.streams
        let bounds = view.bounds
        let editing = mode == .edit
        let rect = editing
            ? CGRect(x: Metrics.side, y: 110, width: bounds.width - Metrics.side * 2, height: 510)
            : bounds.insetBy(dx: 48, dy: 84)

        var mainId: UUID?
        if case .focus(let id) = viewModel.layoutMode, streams.count > 1 { mainId = id }
        // Editing one channel shows it big beside an empty slot, as a prompt
        // to add another.
        let wantsPlaceholder = editing && viewModel.canAddStream && (mainId != nil || streams.count == 1)
        if editing, streams.count == 1 { mainId = streams[0].id }

        let key = LayoutKey(ids: streams.map(\.id), mainId: mainId, mode: mode,
                            placeholder: wantsPlaceholder, size: bounds.size)
        guard key != lastLayoutKey else { return }
        lastLayoutKey = key

        let mainIndex = mainId.flatMap { id in streams.firstIndex(where: { $0.id == id }) }
        let plan = Self.plan(count: streams.count, mainIndex: mainIndex,
                             placeholder: wantsPlaceholder, in: rect, gap: Metrics.gap)

        // Placeholders are plain views, rebuilt each pass.
        placeholderViews.forEach { $0.removeFromSuperview() }
        placeholderViews = plan.placeholders.map { frame in
            let slot = UIView(frame: frame)
            slot.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            slot.layer.cornerRadius = 18
            slot.layer.cornerCurve = .continuous
            slot.isUserInteractionEnabled = false
            slot.alpha = 0
            view.insertSubview(slot, belowSubview: watchHint)
            return slot
        }

        let apply = {
            for (index, slot) in streams.enumerated() {
                guard let tile = self.tiles[slot.id], index < plan.tiles.count else { continue }
                let frame = plan.tiles[index]
                tile.bounds = CGRect(origin: .zero, size: frame.size)
                tile.center = CGPoint(x: frame.midX, y: frame.midY)
                tile.alpha = 1
            }
            self.placeholderViews.forEach { $0.alpha = 1 }
        }
        if animated {
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.9,
                           initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: apply)
        } else {
            apply()
        }
    }

    struct Plan {
        var tiles: [CGRect] = []
        var placeholders: [CGRect] = []
    }

    /// Where each tile goes. `mainIndex` picks the focus layout: one big tile
    /// with the rest in a column beside it, tops aligned. Otherwise a grid:
    /// side by side for two, two by two for three or four. Every tile is 16:9.
    static func plan(count: Int, mainIndex: Int?, placeholder: Bool, in rect: CGRect, gap: CGFloat) -> Plan {
        var plan = Plan()
        guard count > 0 else {
            if placeholder { plan.placeholders = [fit(in: rect)] }
            return plan
        }

        if let mainIndex, mainIndex < count {
            let sideCount = max(1, count - 1 + (placeholder ? 1 : 0))
            var mainW = rect.width * 0.66
            var mainH = mainW * 9 / 16
            if mainH > rect.height {
                mainH = rect.height
                mainW = mainH * 16 / 9
            }
            var sideW = rect.width - mainW - gap
            var sideH = sideW * 9 / 16
            let columnGaps = CGFloat(sideCount - 1) * gap
            if CGFloat(sideCount) * sideH + columnGaps > rect.height {
                sideH = (rect.height - columnGaps) / CGFloat(sideCount)
                sideW = sideH * 16 / 9
            }
            let columnH = CGFloat(sideCount) * sideH + columnGaps
            let totalW = mainW + gap + sideW
            let x = rect.minX + (rect.width - totalW) / 2
            let top = rect.minY + (rect.height - max(mainH, columnH)) / 2

            let main = CGRect(x: x, y: top, width: mainW, height: mainH)
            var side: [CGRect] = []
            for i in 0..<sideCount {
                side.append(CGRect(x: x + mainW + gap, y: top + CGFloat(i) * (sideH + gap),
                                   width: sideW, height: sideH))
            }
            var next = 0
            for index in 0..<count {
                if index == mainIndex {
                    plan.tiles.append(main)
                } else {
                    plan.tiles.append(side[min(next, side.count - 1)])
                    next += 1
                }
            }
            if placeholder, next < side.count { plan.placeholders = [side[next]] }
            return plan
        }

        switch count {
        case 1:
            plan.tiles = [fit(in: rect)]
        case 2:
            var w = (rect.width - gap) / 2
            var h = w * 9 / 16
            if h > rect.height {
                h = rect.height
                w = h * 16 / 9
            }
            let x = rect.minX + (rect.width - (w * 2 + gap)) / 2
            let y = rect.minY + (rect.height - h) / 2
            plan.tiles = [CGRect(x: x, y: y, width: w, height: h),
                          CGRect(x: x + w + gap, y: y, width: w, height: h)]
        default:
            var h = (rect.height - gap) / 2
            var w = h * 16 / 9
            if w * 2 + gap > rect.width {
                w = (rect.width - gap) / 2
                h = w * 9 / 16
            }
            let x = rect.minX + (rect.width - (w * 2 + gap)) / 2
            let y = rect.minY + (rect.height - (h * 2 + gap)) / 2
            let cells = [CGRect(x: x, y: y, width: w, height: h),
                         CGRect(x: x + w + gap, y: y, width: w, height: h),
                         CGRect(x: x, y: y + h + gap, width: w, height: h),
                         CGRect(x: x + w + gap, y: y + h + gap, width: w, height: h)]
            plan.tiles = Array(cells.prefix(min(count, 4)))
            if count == 3 {
                // The odd one out sits centred under the pair.
                plan.tiles[2].origin.x = rect.midX - w / 2
            }
        }
        return plan
    }

    /// The largest 16:9 rectangle centred in `rect`.
    private static func fit(in rect: CGRect) -> CGRect {
        var w = rect.width
        var h = w * 9 / 16
        if h > rect.height {
            h = rect.height
            w = h * 16 / 9
        }
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: - Add More

    private func setUpAddMoreRow() {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                            heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .absolute(Metrics.cardWidth),
                              heightDimension: .absolute(Metrics.cardWidth * LiveCardCell.aspect)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = 40
        section.contentInsets = .init(top: 30, leading: Metrics.side, bottom: 30, trailing: Metrics.side)
        let layout = UICollectionViewCompositionalLayout(section: section)

        addMoreCollection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        addMoreCollection.backgroundColor = .clear
        addMoreCollection.clipsToBounds = false
        addMoreCollection.remembersLastFocusedIndexPath = true
        addMoreCollection.register(LiveCardCell.self, forCellWithReuseIdentifier: LiveCardCell.reuseID)
        addMoreCollection.delegate = self
        addMoreCollection.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(addMoreCollection)

        addMoreSource = UICollectionViewDiffableDataSource(collectionView: addMoreCollection) { [weak self] cv, indexPath, id in
            let cell = cv.dequeueReusableCell(withReuseIdentifier: LiveCardCell.reuseID, for: indexPath) as! LiveCardCell
            if let item = self?.addMoreItems[id] { cell.configure(item) }
            return cell
        }
    }

    /// Channels on now that are not already on screen: favourites first,
    /// then by number.
    private func reloadAddMore() {
        guard addMoreSource != nil else { return }
        let store = LiveTVDataStore.shared
        let active = viewModel.activeChannelIds
        let channels = store.channels
            .filter { !active.contains($0.id) }
            .sorted { a, b in
                let fa = a.isFavourite || store.isFavorite(a)
                let fb = b.isFavourite || store.isFavorite(b)
                if fa != fb { return fa }
                return (a.channelNumber ?? Int.max) < (b.channelNumber ?? Int.max)
            }
            .prefix(80)
        let items = channels
            .map { LiveCardItem.channel($0, program: store.getCurrentProgram(for: $0), section: "add") }
            .uniquedById()
        let previous = addMoreItems
        addMoreItems = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(items.map(\.id))
        let changed = items.filter { previous[$0.id] != nil && previous[$0.id] != $0 }.map(\.id)
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }
        addMoreSource.apply(snapshot, animatingDifferences: false)
    }
}

// MARK: - Add More selection

extension LiveMultiviewViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = addMoreSource.itemIdentifier(for: indexPath),
              let channel = addMoreItems[id]?.channel else { return }
        if viewModel.canAddStream {
            Task { await viewModel.addChannel(channel) }
        } else {
            // Full: the channel takes the place of the one being listened to.
            let index = viewModel.focusedSlotIndex
            Task { await viewModel.replaceStream(at: index, with: channel) }
        }
    }
}

// MARK: - Tile

/// One channel in multiview: its picture, a spinner while it joins, and the
/// speaker on the tile whose sound is playing.
final class LiveMultiviewTileView: UIView {
    let slotId: UUID
    var onSelect: (() -> Void)?
    var onLongPress: (() -> Void)?

    private let surface = AetherPlayer.makeRenderSurface()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let pausedIcon = UIImageView(image: UIImage(systemName: "pause.fill"))
    private let speakerIcon = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
    private let captionScrim = CAGradientLayer()
    private let captionLabel = UILabel()
    private weak var boundPlayer: AetherPlayer?

    override var canBecomeFocused: Bool { true }

    init(slotId: UUID) {
        self.slotId = slotId
        super.init(frame: .zero)
        backgroundColor = .black
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 0

        surface.frame = bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(surface)

        captionScrim.colors = [UIColor.black.withAlphaComponent(0).cgColor,
                               UIColor.black.withAlphaComponent(0.7).cgColor]
        layer.addSublayer(captionScrim)

        captionLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        captionLabel.textColor = .white
        spinner.color = .white
        spinner.hidesWhenStopped = true
        pausedIcon.tintColor = .white
        pausedIcon.preferredSymbolConfiguration = .init(pointSize: 48, weight: .semibold)
        speakerIcon.tintColor = .white
        speakerIcon.preferredSymbolConfiguration = .init(pointSize: 22, weight: .semibold)
        speakerIcon.layer.shadowColor = UIColor.black.cgColor
        speakerIcon.layer.shadowOpacity = 0.6
        speakerIcon.layer.shadowRadius = 6
        speakerIcon.layer.shadowOffset = .zero

        [captionLabel, spinner, pausedIcon, speakerIcon].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: speakerIcon.leadingAnchor, constant: -12),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            speakerIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            speakerIcon.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            pausedIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            pausedIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(selected))
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        addGestureRecognizer(tap)
        addGestureRecognizer(TileLongPress.makeRecognizer(target: self, action: #selector(longPressed(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        captionScrim.frame = CGRect(x: 0, y: bounds.height * 0.6, width: bounds.width, height: bounds.height * 0.4)
        CATransaction.commit()
    }

    func show(_ slot: MultiStreamViewModel.StreamSlot) {
        if boundPlayer !== slot.aetherPlayer {
            boundPlayer?.unbind(surface: surface)
            slot.aetherPlayer.bind(surface: surface)
            boundPlayer = slot.aetherPlayer
        }
        captionLabel.text = [slot.channel.channelNumber.map(String.init), slot.channel.name]
            .compactMap { $0 }
            .joined(separator: " · ")
        switch slot.playbackState {
        case .loading, .buffering, .idle:
            spinner.startAnimating()
        default:
            spinner.stopAnimating()
        }
        pausedIcon.isHidden = slot.playbackState != .paused
        speakerIcon.isHidden = slot.isMuted
    }

    func setShowsCaption(_ shows: Bool) {
        captionLabel.alpha = shows ? 1 : 0
        captionScrim.opacity = shows ? 1 : 0
    }

    func release() {
        boundPlayer?.unbind(surface: surface)
        boundPlayer = nil
    }

    /// A held Select opens the menu at the hold; its release must not then
    /// count as a press as well.
    private var releaseBelongsToLongPress = false

    @objc private func selected() {
        if releaseBelongsToLongPress {
            releaseBelongsToLongPress = false
            return
        }
        onSelect?()
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        releaseBelongsToLongPress = true
        onLongPress?()
        // The tap may never fire for a long hold; do not let the flag eat the
        // next real press.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.releaseBelongsToLongPress = false
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations {
            self.transform = focused ? CGAffineTransform(scaleX: 1.03, y: 1.03) : .identity
            self.layer.borderWidth = focused ? 5 : 0
        }
    }
}

// MARK: - Mode hint

/// "Swipe up to watch" over the edit view, and the chevron under the watch
/// view. Focusable only so a move toward it has somewhere to land; the
/// controller changes mode the moment it takes focus, so it never shows a
/// focused look.
final class LiveMultiviewHintView: UIView {
    override var canBecomeFocused: Bool { true }

    init(pointsUp: Bool, text: String?) {
        super.init(frame: .zero)
        let chevron = UIImageView(image: UIImage(systemName: pointsUp ? "chevron.compact.up" : "chevron.compact.down"))
        chevron.tintColor = UIColor.white.withAlphaComponent(0.8)
        chevron.preferredSymbolConfiguration = .init(pointSize: 34, weight: .semibold)

        let stack = UIStackView(arrangedSubviews: [chevron])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        if let text {
            let label = UILabel()
            label.text = text
            label.font = .systemFont(ofSize: 24, weight: .medium)
            label.textColor = UIColor.white.withAlphaComponent(0.8)
            stack.addArrangedSubview(label)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
