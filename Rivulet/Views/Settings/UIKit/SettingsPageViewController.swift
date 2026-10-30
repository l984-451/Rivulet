// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsPageViewController.swift
//  Rivulet
//
//  One Settings page's ROW LIST (right pane content only). The container
//  (`SettingsContainerViewController`) owns the title, the persistent left
//  description panel, the page stack, the directional transition, and the
//  Left/Menu handling. This VC just renders the rows for its page and reports
//  taps (`onPush`) + row focus (`onFocusRow`).
//

import Combine
import UIKit

@MainActor
final class SettingsPageViewController: UIViewController {

    let page: SettingsPage
    /// A navigation row was selected → container pushes this page.
    var onPush: ((SettingsPage) -> Void)?
    /// A picker option was chosen → container pops back to the parent.
    var onPop: (() -> Void)?
    /// Pops this page and the one below it (a form opened from a picker).
    var onPopTwo: (() -> Void)?
    /// A row gained focus → container updates the left description panel.
    var onFocusRow: ((String?) -> Void)?

    private(set) var collectionView: UICollectionView!
    private var rows: [SettingsRowItem] = []
    private static let cellID = SettingsCell.reuseID

    /// Tracks the focused row so a grab (hold Select) knows which row to act on.
    private var focusedIndexPath: IndexPath?
    /// Move mode for a grabbed row: Up/Down slide it, Select drops it.
    private var reorder: GrabReorderController!
    private var speechModelState: AnyCancellable?

    init(page: SettingsPage) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        rebuildRows()

        // Row metrics measured off tvOS Settings at 4K: 80pt pitch, a 66.5pt
        // capsule, 13.5pt between capsules. 72 + 8 spacing gives the same 80pt
        // pitch, and SettingsCell's 3pt inset each side lands a 66pt capsule
        // with a 14pt gap — within half a point of Apple on all three.
        let rowHeight: CGFloat = 72
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                            heightDimension: .absolute(rowHeight)))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                       heightDimension: .absolute(rowHeight)),
                                                     subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 8
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 24, trailing: 24)
        // Insets from the bounds, not the safe area: the container places the pane.
        section.contentInsetsReference = .none
        let layout = UICollectionViewCompositionalLayout(section: section)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(SettingsCell.self, forCellWithReuseIdentifier: Self.cellID)
        collectionView.register(SettingsHeaderCell.self, forCellWithReuseIdentifier: SettingsHeaderCell.reuseID)
        collectionView.remembersLastFocusedIndexPath = true
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Apple-Home-style reorder. Hold Select to grab a reorderable row; it
        // lifts + wiggles, Up/Down slides it (any distance), Select drops it.
        // tvOS has no UICollectionView reorder gesture, so drive it manually.
        let grab = UILongPressGestureRecognizer(target: self, action: #selector(handleGrab(_:)))
        grab.minimumPressDuration = 0.6
        grab.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        collectionView.addGestureRecognizer(grab)

        reorder = GrabReorderController(
            view: collectionView, axis: .vertical, count: { [weak self] in self?.rows.count ?? 0 },
            canMove: { [weak self] from, to in
                // Only slide within the reorderable run (don't pass Add All / Remove All).
                guard let rows = self?.rows else { return false }
                return rows[to].isReorderable && rows[to].reorderGroup == rows[from].reorderGroup
            },
            onStep: { [weak self] from, to in self?.moveRow(from: from, to: to) },
            onDrop: { [weak self] _, final in
                (self?.collectionView.cellForItem(at: IndexPath(item: final, section: 0)) as? SettingsCell)?
                    .setReordering(false)
            })

        // Kick off any background load this page needs (e.g. fetch Plex Home
        // users) and refresh the list when it arrives.
        SettingsContent.prepareAsync(for: page) { [weak self] in self?.reloadRows() }

        // The speech model's download progress updates in place (Content Filtering, Generated Subtitles).
        if page == .contentFilter || page == .playback {
            speechModelState = SpeechModelStore.shared.$state
                .dropFirst()
                .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] _ in self?.refreshVisibleValues() }
        }
    }

    @objc private func handleGrab(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began, !reorder.isMoving,
              let ip = focusedIndexPath, ip.item < rows.count,
              rows[ip.item].isReorderable else { return }
        reorder.begin(at: ip.item)
        reorder.swallowsNextSelect = true     // the grab hold's release must not toggle
        (collectionView.cellForItem(at: ip) as? SettingsCell)?.setReordering(true)
    }

    private func moveRow(from: Int, to: Int) {
        rows[from].onReorder?(to < from)       // persist the single-step move
        let moved = rows.remove(at: from)
        rows.insert(moved, at: to)
        let toPath = IndexPath(item: to, section: 0)
        collectionView.performBatchUpdates { collectionView.moveItem(at: IndexPath(item: from, section: 0), to: toPath) }
        focusedIndexPath = toPath
    }

    private var hasAppeared = false
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if page == .silo, let account = SiloSession.account, let provider = SiloSession.storedProvider() {
            SiloPlaybackSettingsContent.refresh(provider: provider, account: account) { [weak self] in self?.reloadRows() }
        }
        // On RE-appearance (e.g. returning from a presented modal like the
        // Plex sign-in sheet), rebuild rows so the page reflects new state
        // (Connect → Sign Out) and refreshed values. Skip the first appear
        // (rows are already fresh from viewDidLoad).
        if hasAppeared { reloadRows() }
        hasAppeared = true
    }



    /// Rebuild the row models for this page from current manager/UserDefaults
    /// state. Falls back to a single focusable placeholder for empty pages so
    /// focus always has a target (never a focusless page).
    private func rebuildRows() {
        rows = SettingsContent.rows(for: page)
        if rows.isEmpty {
            rows = [SettingsRowItem(id: "placeholder_\(page.title)",
                                    title: "\(page.title) — coming soon",
                                    kind: .action(destructive: false, handler: { _ in }))]
        }
    }

    /// Re-apply the dimmed state of every visible row after a toggle, since one
    /// row's value can disable another. Deliberately NOT a `reloadData()` — that
    /// recreates the focused cell mid-press and drops focus on tvOS.
    private func refreshDimmedRows() {
        guard let collectionView else { return }
        for cell in collectionView.visibleCells {
            guard let cell = cell as? SettingsCell,
                  let path = collectionView.indexPath(for: cell),
                  path.item < rows.count else { continue }
            cell.setDimmed(!rows[path.item].isEnabled())
        }
    }

    /// Re-read every visible row's value in place, keeping focus where it is.
    private func refreshVisibleValues() {
        guard let collectionView else { return }
        for cell in collectionView.visibleCells {
            guard let cell = cell as? SettingsCell,
                  let path = collectionView.indexPath(for: cell),
                  path.item < rows.count else { continue }
            let item = rows[path.item]
            cell.configure(title: item.title, value: item.valueText, showsChevron: item.showsChevron,
                           destructive: item.isDestructive, showsCheckmark: item.showsCheckmark,
                           dimmed: !item.isEnabled(), busy: item.isBusy())
        }
    }

    /// Rebuild rows from current state and reload the list. For action rows
    /// that mutate this page's OWN data and need the list to refresh in place
    /// (e.g. Libraries' Add All / Remove All).
    func reloadRows() {
        rebuildRows()
        collectionView?.reloadData()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        collectionView == nil ? super.preferredFocusEnvironments : [collectionView]
    }
}

extension SettingsPageViewController: UICollectionViewDataSource, UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let item = rows[indexPath.item]
        if item.isHeader {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SettingsHeaderCell.reuseID,
                                                          for: indexPath) as! SettingsHeaderCell
            cell.configure(title: item.title)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.cellID, for: indexPath) as! SettingsCell
        cell.configure(title: item.title, value: item.valueText, showsChevron: item.showsChevron,
                       destructive: item.isDestructive, showsCheckmark: item.showsCheckmark,
                       dimmed: !item.isEnabled(), busy: item.isBusy())
        cell.onFocusGained = { [weak self] in self?.onFocusRow?(item.id) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        rows[indexPath.item].isFocusable
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // A long-press just fired its menu; swallow the trailing Select so it
        // doesn't also toggle the row.
        if reorder.swallowsNextSelect { reorder.swallowsNextSelect = false; return }
        let item = rows[indexPath.item]
        switch item.kind {
        case .navigation(let target), .navigationValue(let target, _):
            onPush?(target)
        case .navigationAction(let target, _, let prepare):
            prepare()
            onPush?(target)
        case .toggle(let get, let set, let didChange):
            set(!get())
            (collectionView.cellForItem(at: indexPath) as? SettingsCell)?.updateValue(get() ? "On" : "Off")
            refreshDimmedRows()
            didChange?(get(), self)
        case .cycle(let value, let next):
            next()
            (collectionView.cellForItem(at: indexPath) as? SettingsCell)?.updateValue(value())
            refreshDimmedRows()
        case .action(_, let handler):
            handler(self)
        case .option(_, let select):
            select()
            onPop?()
        case .selectable(_, _, let handler):
            // The handler owns its own list refresh (it may switch synchronously
            // or present a PIN modal and reload on dismiss).
            handler(self)
        case .textEntry(let value, _, let hint, let suggestions, let keyboardType, let isSecure, let contentType, let set):
            let entry = TextEntryViewController(
                title: item.title, message: hint, initialText: value(),
                suggestions: suggestions, keyboardType: keyboardType, isSecure: isSecure,
                contentType: contentType,
                onCommit: { [weak self] text in
                    set(text)
                    // Reload so the row shows the committed value. A Menu
                    // cancel never gets here — the value stays untouched.
                    self?.reloadRows()
                })
            present(entry, animated: true)
        case .info:
            break
        }
    }

    func collectionView(_ collectionView: UICollectionView,
                        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        focusedIndexPath = context.nextFocusedIndexPath
    }

    /// While a row is grabbed, lock focus to it so Up/Down slide the row instead
    /// of moving focus to a neighbour.
    func collectionView(_ collectionView: UICollectionView,
                        shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
        !reorder.isMoving
    }
}
