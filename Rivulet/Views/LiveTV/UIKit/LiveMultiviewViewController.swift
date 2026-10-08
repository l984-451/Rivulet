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
    /// once multiview has closed, WITHOUT animation: the tile has already grown
    /// to fill the screen, so an animated present would show the screen behind.
    var onWatchFullScreen: ((LiveTVSessionHandoff) -> Void)?
    /// Multiview closed with nothing handed on.
    var onExit: (() -> Void)?
    /// Opened from the full-screen player: present without animation, and the
    /// adopted channel starts full screen and shrinks into its tile while the
    /// rest of the screen fades in, so the player seems to become multiview.
    var entersFromFullScreen = false

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
    /// One `ShelfRowCell` per row (What's On's row, so cards land on the same
    /// columns in every row), keyed by row id.
    private var addMoreSource: UICollectionViewDiffableDataSource<String, String>!
    private var addMoreRows: [String: LiveBrowseViewController.Shelf] = [:]
    /// The row on show (the rest are paged out of the clipped row area).
    private var addMoreRow = 0
    /// Edit mode's vertical routing, set per focus move in `routeVerticalFocus`:
    /// under the tiles, and under the layout buttons.
    private let belowTilesGuide = UIFocusGuide()
    private let belowButtonsGuide = UIFocusGuide()
    /// The tile focus was last on, so coming back up lands there rather than
    /// on whichever tile sits above the button or card being left.
    private weak var lastFocusedTile: LiveMultiviewTileView?
    /// A channel just picked from Add More; its tile takes focus once it exists.
    private var focusOnAddedChannelId: String?
    /// A re-rank was held back while focus was in the row.
    private var addMoreNeedsRank = false

    private var cancellables = Set<AnyCancellable>()
    /// Where focus goes on the next update, consumed once it lands.
    private weak var pendingFocus: UIView?
    private var isExiting = false
    private var lastLayoutKey: LayoutKey?

    private enum Metrics {
        static let side: CGFloat = 90
        static let gap: CGFloat = 36
        static let cardWidth: CGFloat = 340
        /// One Add More row: What's On's card plus its focus-growth room.
        static var rowHeight: CGFloat { MediaRowMetrics.liveHeight + MediaRowMetrics.focusGrowthPadding }
        /// Row to row.
        static var rowPitch: CGFloat { rowHeight + MediaRowMetrics.rowTopInset + MediaRowMetrics.rowBottomInset }
        /// How much of the next row's cards shows below the current one, so
        /// it reads as scrollable. The show detail page's episode peek.
        static let nextRowPeek: CGFloat = 40
        /// The Add More area: one row, then the next row down to `nextRowPeek`
        /// of its card (the card sits mid-row, half the growth room down).
        static var addMoreHeight: CGFloat {
            rowPitch + MediaRowMetrics.rowTopInset + MediaRowMetrics.focusGrowthPadding / 2 + nextRowPeek
        }
        /// Edit mode's tile area, shortened to make room for the peek. Its top
        /// stays clear of the watch hint (y 16 to 96) even at the focused
        /// scale: a tile over the hint let Right from the big focus-layout
        /// tile land on it and switch to watch mode.
        static let editTilesTop: CGFloat = 110
        static let editTilesHeight: CGFloat = 450
        static var editTilesBottom: CGFloat { editTilesTop + editTilesHeight }
    }

    /// The Live TV tab's source, or nil when sources are combined. Add More
    /// offers only what that tab shows: two sources can carry the same lineup
    /// (Plex Live TV on a Dispatcharr tuner, plus Dispatcharr itself), and
    /// unscoped, every such channel was offered twice.
    private let sourceIdFilter: String?

    init(adopting session: LiveTVSessionHandoff?, adding channel: UnifiedChannel?, sourceIdFilter: String?) {
        viewModel = MultiStreamViewModel(adopting: session, adding: channel)
        self.sourceIdFilter = sourceIdFilter
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

        // Full width, so Up from any card or button lands on the next layer
        // up instead of whichever tile happens to sit above it.
        view.addLayoutGuide(belowTilesGuide)
        view.addLayoutGuide(belowButtonsGuide)
        NSLayoutConstraint.activate([
            belowTilesGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            belowTilesGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            belowTilesGuide.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.editTilesBottom + 4),
            belowTilesGuide.bottomAnchor.constraint(equalTo: layoutButtons.topAnchor),
            belowButtonsGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            belowButtonsGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            belowButtonsGuide.topAnchor.constraint(equalTo: layoutButtons.bottomAnchor),
            belowButtonsGuide.bottomAnchor.constraint(equalTo: addMoreLabel.topAnchor),
        ])
        routeVerticalFocus(from: nil)

        NSLayoutConstraint.activate([
            layoutButtons.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            layoutButtons.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.editTilesBottom + 20),

            addMoreLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: MediaRowMetrics.liveLeading),
            addMoreLabel.bottomAnchor.constraint(equalTo: addMoreCollection.topAnchor, constant: -4),

            addMoreCollection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            addMoreCollection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            addMoreCollection.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            addMoreCollection.heightAnchor.constraint(equalToConstant: Metrics.addMoreHeight),
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

        if entersFromFullScreen { enteringChrome.forEach { $0.alpha = 0 } }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        LiveHandoffCover.hide(in: view.window)
        guard entersFromFullScreen else { return }
        entersFromFullScreen = false
        relayout(animated: true)
        UIView.animate(withDuration: 0.4, delay: 0.1, options: [.curveEaseOut]) {
            self.enteringChrome.forEach { $0.alpha = 1 }
        }
    }

    /// Edit mode's chrome, held back while the adopted channel is still full
    /// screen.
    private var enteringChrome: [UIView] {
        [addMoreLabel, addMoreCollection, layoutButtons, watchHint].compactMap { $0 }
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
        if let tile = orderedTiles.first(where: { next.isDescendant(of: $0) }) {
            lastFocusedTile = tile
        }
        routeVerticalFocus(from: next)
        if addMoreNeedsRank, !next.isDescendant(of: addMoreCollection) {
            // Outside the focus update, so the apply does not run inside it.
            DispatchQueue.main.async { [weak self] in self?.reloadAddMore() }
        }

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
    private func exitMultiview(handingOff session: LiveTVSessionHandoff?, animated: Bool = true) {
        guard !isExiting else { return }
        isExiting = true
        for tile in tiles.values { tile.release() }
        viewModel.stopAllStreams()
        let onWatchFullScreen = onWatchFullScreen
        let onExit = onExit
        closeSelf(animated: animated) {
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
    private func closeSelf(animated: Bool = true, completion: @escaping () -> Void) {
        if let presented = presentedViewController {
            if presented.isBeingDismissed {
                // Already on its way out (an alert closing after its action):
                // a second dismiss would be dropped along with its completion.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.closeSelf(animated: animated, completion: completion)
                }
                return
            }
            presented.dismiss(animated: false) { [weak self] in
                self?.closeSelf(animated: animated, completion: completion)
            }
            return
        }
        super.dismiss(animated: animated, completion: completion)
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
        routeVerticalFocus(from: pendingFocus)
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

    /// Points the two guides at the next layer in each direction from where
    /// focus now is. Up: Add More, the layout buttons, then the tile with the
    /// sound (layers that are hidden are skipped). Down retraces it.
    private func routeVerticalFocus(from focused: UIView?) {
        let editing = mode == .edit
        belowTilesGuide.isEnabled = editing
        belowButtonsGuide.isEnabled = editing
        guard editing else { return }
        let buttons: UIView? = layoutButtons.isHidden ? nil : layoutButtons
        let tile = returnTile
        let inAddMore = focused?.isDescendant(of: addMoreCollection) ?? false
        let onButtons = focused?.isDescendant(of: layoutButtons) ?? false
        if inAddMore {
            belowButtonsGuide.preferredFocusEnvironments = [buttons ?? tile].compactMap { $0 }
            belowTilesGuide.preferredFocusEnvironments = [tile].compactMap { $0 }
        } else if onButtons {
            belowTilesGuide.preferredFocusEnvironments = [tile].compactMap { $0 }
            belowButtonsGuide.preferredFocusEnvironments = [addMoreCollection].compactMap { $0 }
        } else {
            belowTilesGuide.preferredFocusEnvironments = [buttons ?? addMoreCollection].compactMap { $0 }
            belowButtonsGuide.preferredFocusEnvironments = [addMoreCollection].compactMap { $0 }
        }
    }

    /// Where Up lands in the tiles: the one last focused, else the one with sound.
    private var returnTile: LiveMultiviewTileView? {
        if let last = lastFocusedTile, last.superview != nil { return last }
        return audibleTile ?? orderedTiles.first
    }

    /// The focus engine's geometric Up from a layout button picks the tile
    /// above that button, past the guide. Redirect to `returnTile`.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        // The hints switch modes when focused, so they take focus only in
        // their own direction: Up into "Swipe up to watch", Down into the
        // edit hint.
        if context.nextFocusedView === watchHint, context.focusHeading != .up { return false }
        if context.nextFocusedView === editHint, context.focusHeading != .down { return false }
        guard mode == .edit, context.focusHeading == .up,
              let previous = context.previouslyFocusedView, previous.isDescendant(of: layoutButtons),
              let next = context.nextFocusedView, !next.isDescendant(of: layoutButtons),
              let target = returnTile, next !== target, !next.isDescendant(of: target)
        else { return super.shouldUpdateFocus(in: context) }
        pendingFocus = target
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        }
        return false
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

        // A channel just added from Add More takes focus, so it can be moved
        // or made the one with sound straight away.
        if let id = focusOnAddedChannelId,
           let slot = streams.first(where: { $0.channel.id == id }), let tile = tiles[slot.id] {
            focusOnAddedChannelId = nil
            pendingFocus = tile
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }

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

    /// The tile grows to fill the screen while the rest fades, then multiview
    /// closes without animation and the player takes over the same picture
    /// (the reverse of `entersFromFullScreen`). Detaching removes the tile, so
    /// it happens after the grow.
    private func takeFullScreen(slotId: UUID) {
        guard !isExiting, let tile = tiles[slotId],
              let slot = viewModel.streams.first(where: { $0.id == slotId }) else { return }
        switch slot.playbackState {
        case .playing, .paused, .buffering: break
        default: return  // Still joining: nothing to carry over yet.
        }
        let others: [UIView] = tiles.values.filter { $0 !== tile } + placeholderViews
            + enteringChrome + [editHint]
        let restore = others.map { ($0, $0.alpha) }
        view.bringSubviewToFront(tile)
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut], animations: {
            tile.bounds = CGRect(origin: .zero, size: self.view.bounds.size)
            tile.center = CGPoint(x: self.view.bounds.midX, y: self.view.bounds.midY)
            others.forEach { $0.alpha = 0 }
        }, completion: { _ in
            guard let index = self.viewModel.streams.firstIndex(where: { $0.id == slotId }),
                  let session = self.viewModel.detachStream(at: index) else {
                // Stopped while growing: put the screen back.
                self.lastLayoutKey = nil
                self.relayout(animated: true)
                UIView.animate(withDuration: 0.3) { restore.forEach { $0.0.alpha = $0.1 } }
                return
            }
            tile.release()
            LiveHandoffCover.show(under: self)
            self.exitMultiview(handingOff: session, animated: false)
        })
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
        let fullScreen: Bool
    }

    private func relayout(animated: Bool) {
        guard isViewLoaded, view.bounds.width > 0 else { return }
        updateLayoutButtonIcons()

        let streams = viewModel.streams
        let bounds = view.bounds
        let editing = mode == .edit
        let fullScreen = entersFromFullScreen && streams.count == 1
        let rect = fullScreen ? bounds
            : editing
            ? CGRect(x: Metrics.side, y: Metrics.editTilesTop, width: bounds.width - Metrics.side * 2,
                     height: Metrics.editTilesHeight)
            : bounds.insetBy(dx: 48, dy: 84)

        var mainId: UUID?
        if case .focus(let id) = viewModel.layoutMode, streams.count > 1 { mainId = id }
        // Editing one channel shows it big beside an empty slot, as a prompt
        // to add another.
        let wantsPlaceholder = !fullScreen && editing && viewModel.canAddStream
            && (mainId != nil || streams.count == 1)
        if editing, streams.count == 1 { mainId = streams[0].id }

        let key = LayoutKey(ids: streams.map(\.id), mainId: mainId, mode: mode,
                            placeholder: wantsPlaceholder, size: bounds.size, fullScreen: fullScreen)
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

        // A tile just added has no frame yet; put it in its slot first so it
        // fades in where the empty placeholder was, rather than flying in
        // from the top-left corner.
        UIView.performWithoutAnimation {
            for (index, slot) in streams.enumerated() {
                guard let tile = self.tiles[slot.id], tile.bounds.isEmpty, index < plan.tiles.count else { continue }
                let frame = plan.tiles[index]
                tile.bounds = CGRect(origin: .zero, size: frame.size)
                tile.center = CGPoint(x: frame.midX, y: frame.midY)
            }
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
        // What's On's layout: one full-bleed `ShelfRowCell` per section. An
        // orthogonal section lands each card against the raw screen edge, so
        // a scrolled row sat off the columns of the rows around it.
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let rowSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                 heightDimension: .absolute(Metrics.rowHeight))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: rowSize,
                                                           subitems: [NSCollectionLayoutItem(layoutSize: rowSize)])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsetsReference = .none
            section.contentInsets = .init(top: MediaRowMetrics.rowTopInset, leading: 0,
                                          bottom: MediaRowMetrics.rowBottomInset, trailing: 0)
            return section
        }

        addMoreCollection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        addMoreCollection.backgroundColor = .clear
        // One row plus the peek, clipped, so the rows paged above stay hidden.
        addMoreCollection.clipsToBounds = true
        addMoreCollection.showsVerticalScrollIndicator = false
        addMoreCollection.contentInsetAdjustmentBehavior = .never
        addMoreCollection.remembersLastFocusedIndexPath = true
        addMoreCollection.register(ShelfRowCell.self, forCellWithReuseIdentifier: ShelfRowCell.reuseID)
        addMoreCollection.delegate = self
        addMoreCollection.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(addMoreCollection)

        addMoreSource = UICollectionViewDiffableDataSource(collectionView: addMoreCollection) { [weak self] cv, indexPath, id in
            let row = cv.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
            self?.configureAddMoreRow(row, id: id)
            return row
        }
    }

    /// Bind a row to one Add More shelf, the way What's On binds its rows.
    private func configureAddMoreRow(_ row: ShelfRowCell, id: String) {
        guard let shelf = addMoreRows[id] else { return }
        let cards = shelf.items
        row.cellProvider = { innerCV, indexPath in
            let cell = innerCV.dequeueReusableCell(withReuseIdentifier: LiveCardCell.reuseID,
                                                   for: indexPath) as! LiveCardCell
            if indexPath.item < cards.count { cell.configure(cards[indexPath.item]) }
            return cell
        }
        row.onSelect = { [weak self] index in
            guard index < cards.count, let channel = cards[index].channel else { return }
            self?.addFromAddMore(channel)
        }
        row.onFocusItem = { [weak self] _ in self?.addMoreRowFocused(id) }
        var token = Hasher()
        for card in cards { token.combine(card.id) }
        row.configure(kind: .live, realCount: cards.count, hasSkeleton: false,
                      contentToken: token.finalize(), initialOffset: 0)
        let inner = row.rowCollectionView!
        for case let cell as LiveCardCell in inner.visibleCells {
            guard let indexPath = inner.indexPath(for: cell), indexPath.item < cards.count else { continue }
            cell.configure(cards[indexPath.item])
        }
    }

    private func addFromAddMore(_ channel: UnifiedChannel) {
        focusOnAddedChannelId = channel.id
        if viewModel.canAddStream {
            Task { await viewModel.addChannel(channel) }
        } else {
            // Full: the channel takes the place of the one being listened to.
            let index = viewModel.focusedSlotIndex
            Task { await viewModel.replaceStream(at: index, with: channel) }
        }
    }

    /// Paging between rows: the label takes the new row's title.
    private func addMoreRowFocused(_ id: String) {
        guard let row = addMoreSource.snapshot().indexOfSection(id), row != addMoreRow else { return }
        addMoreRow = row
        UIView.transition(with: addMoreLabel, duration: 0.2, options: .transitionCrossDissolve) {
            self.addMoreLabel.text = self.addMoreRows[id]?.title ?? "Add More"
        }
    }

    /// Add More's rows: "Recommended" (channels like the one multiview opened
    /// with) and then What's On's own rows. One row shows at a time; Down and
    /// Up page between them. Channels already on screen are left out.
    private func reloadAddMore() {
        guard addMoreSource != nil else { return }
        let active = viewModel.activeChannelIds
        // Never rebuild under the viewer's cursor: while focus is in the rows
        // only channels now playing leave them, in place; the rest lands when
        // focus leaves.
        if let focused = UIFocusSystem.focusSystem(for: addMoreCollection)?.focusedItem as? UIView,
           focused.isDescendant(of: addMoreCollection) {
            addMoreNeedsRank = true
            var changedRows: [String] = []
            for (id, shelf) in addMoreRows {
                let kept = shelf.items.filter { !($0.channel.map { active.contains($0.id) } ?? false) }
                guard kept.count != shelf.items.count else { continue }
                addMoreRows[id] = LiveBrowseViewController.Shelf(id: id, title: shelf.title, items: kept)
                changedRows.append(id)
            }
            guard !changedRows.isEmpty else { return }
            var snapshot = addMoreSource.snapshot()
            snapshot.reconfigureItems(changedRows)
            addMoreSource.apply(snapshot, animatingDifferences: false)
            return
        }
        addMoreNeedsRank = false

        let notPlaying = { (item: LiveCardItem) in
            item.kind == .channel && !(item.channel.map { active.contains($0.id) } ?? true)
        }
        // Recordings and Starting Soon are not channels to add now.
        let shelves = LiveBrowseViewController.buildShelves(sourceIdFilter: sourceIdFilter)
            .filter { $0.id != "recordings" && $0.id != "soon" }
        let rows = ([LiveBrowseViewController.Shelf(id: "add", title: "Recommended", items: recommended())]
                    + shelves)
            .map { LiveBrowseViewController.Shelf(id: $0.id, title: $0.title,
                                                  items: $0.items.filter(notPlaying).uniquedById()) }
            .filter { !$0.items.isEmpty }

        let existing = Set(addMoreSource.snapshot().itemIdentifiers)
        addMoreRows = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        addMoreRow = min(addMoreRow, max(rows.count - 1, 0))
        addMoreLabel.text = rows[safe: addMoreRow]?.title ?? "Add More"

        // One item per row; a row's identity never changes, so reconfiguring
        // is what hands an existing row its new cards.
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for row in rows {
            snapshot.appendSections([row.id])
            snapshot.appendItems([row.id], toSection: row.id)
        }
        snapshot.reconfigureItems(rows.map(\.id).filter(existing.contains))
        addMoreSource.apply(snapshot, animatingDifferences: false)
    }

    /// Channels most like what is playing: the same kind of programme
    /// (another football game), then the same genre, then the same channel
    /// group, against whichever playing channel each is closest to;
    /// favourites lead within each, then number. Ranked against every tile,
    /// not the one with sound, so the row changes when a channel is added or
    /// removed and never when the sound moves.
    private func recommended() -> [LiveCardItem] {
        let store = LiveTVDataStore.shared
        let references = viewModel.streams.map { channel -> (labels: Set<String>, genre: LiveGenre?, group: String?) in
            let program = store.getCurrentProgram(for: channel.channel)
            return (LiveGenre.specificLabels(of: program),
                    LiveGenre.of(channel.channel, airing: program, guide: store.epg[channel.channel.id] ?? []),
                    channel.channel.groupTitle)
        }
        func tier(_ channel: UnifiedChannel) -> Int {
            guard !references.isEmpty else { return 0 }
            let program = store.getCurrentProgram(for: channel)
            let labels = LiveGenre.specificLabels(of: program)
            let genre = LiveGenre.of(channel, airing: program, guide: store.epg[channel.id] ?? [])
            return references.map { reference in
                if !reference.labels.isDisjoint(with: labels) { return 0 }
                if let referenceGenre = reference.genre, genre == referenceGenre { return 1 }
                if let group = reference.group, !group.isEmpty, channel.groupTitle == group { return 2 }
                return 3
            }.min() ?? 3
        }
        return store.channels
            .filter { sourceIdFilter == nil || $0.sourceId == sourceIdFilter }
            .map { (channel: $0, tier: tier($0)) }
            .sorted { a, b in
                if a.tier != b.tier { return a.tier < b.tier }
                let fa = store.isFavorite(a.channel)
                let fb = store.isFavorite(b.channel)
                if fa != fb { return fa }
                return (a.channel.channelNumber ?? Int.max) < (b.channel.channelNumber ?? Int.max)
            }
            .prefix(80)
            .map { LiveCardItem.channel($0.channel, program: store.getCurrentProgram(for: $0.channel), section: "add") }
    }
}

// MARK: - Add More selection

extension LiveMultiviewViewController: UICollectionViewDelegate {
    /// Focus scrolls land with the focused row exactly in the row area; tvOS
    /// would otherwise stop part way, showing slices of two rows.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === addMoreCollection,
              let first = addMoreCollection.layoutAttributesForItem(at: IndexPath(item: 0, section: addMoreRow))
        else { return }
        targetContentOffset.pointee.y = first.frame.minY - MediaRowMetrics.rowTopInset
    }
}

// MARK: - Hand-off cover

/// Black behind the screen being swapped out when the full-screen player and
/// multiview hand a channel to each other. Both sides close and open without
/// animation, and UIKit can still draw one frame between them; without this,
/// that frame is the guide. Sits UNDER the outgoing screen, so it shows only
/// in that gap; the incoming screen presents above it and removes it.
enum LiveHandoffCover {
    private static let tag = 0x4C48_4F43

    static func show(under controller: UIViewController) {
        guard let window = controller.view.window else { return }
        hide(in: window)
        var top: UIView = controller.view
        while let parent = top.superview, parent !== window { top = parent }
        let cover = UIView(frame: window.bounds)
        cover.backgroundColor = .black
        cover.tag = tag
        cover.isUserInteractionEnabled = false
        window.insertSubview(cover, belowSubview: top)
        // Never outlive a hand-off that did not complete.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak cover] in cover?.removeFromSuperview() }
    }

    static func hide(in window: UIWindow?) {
        window?.viewWithTag(tag)?.removeFromSuperview()
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
    /// Shown once the tile has stopped retrying a channel that will not play.
    private let unavailableLabel = UILabel()
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
        unavailableLabel.text = "Channel Unavailable"
        unavailableLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        unavailableLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        unavailableLabel.isHidden = true
        pausedIcon.preferredSymbolConfiguration = .init(pointSize: 48, weight: .semibold)
        speakerIcon.tintColor = .white
        speakerIcon.preferredSymbolConfiguration = .init(pointSize: 22, weight: .semibold)
        speakerIcon.layer.shadowColor = UIColor.black.cgColor
        speakerIcon.layer.shadowOpacity = 0.6
        speakerIcon.layer.shadowRadius = 6
        speakerIcon.layer.shadowOffset = .zero

        [captionLabel, spinner, pausedIcon, unavailableLabel, speakerIcon].forEach {
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
            unavailableLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            unavailableLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        // A failure still being retried shows the spinner; only a tile that
        // recovery gave up on says the channel is unavailable.
        switch slot.playbackState {
        case .loading, .buffering, .idle, .failed:
            if slot.isUnavailable { spinner.stopAnimating() } else { spinner.startAnimating() }
        default:
            spinner.stopAnimating()
        }
        pausedIcon.isHidden = slot.playbackState != .paused
        unavailableLabel.isHidden = !slot.isUnavailable
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
        // Scale only, as the Apple TV app does: no outline around a playing
        // picture, which distracts and would sit static long enough to burn in.
        coordinator.addCoordinatedAnimations {
            self.transform = focused ? CGAffineTransform(scaleX: 1.03, y: 1.03) : .identity
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
