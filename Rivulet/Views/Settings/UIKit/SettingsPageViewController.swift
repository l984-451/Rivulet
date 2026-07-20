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

import UIKit

@MainActor
final class SettingsPageViewController: UIViewController {

    let page: SettingsPage
    /// A navigation row was selected → container pushes this page.
    var onPush: ((SettingsPage) -> Void)?
    /// A picker option was chosen → container pops back to the parent.
    var onPop: (() -> Void)?
    /// A row gained focus → container updates the left description panel.
    var onFocusRow: ((String?) -> Void)?
    /// True once the user has changed any library setting on the Sidebar
    /// Libraries page this visit (toggle / Add All / Remove All / reorder). The
    /// container reads it on pop to decide whether to offer "Save & Apply"
    /// (rebuild the sidebar). Resets when the page VC is recreated (next visit).
    private(set) var librariesDidEdit = false
    private func markLibraryEdit() { if page == .libraries { librariesDidEdit = true } }
    /// User chose "Not Now" on the apply prompt: stop intercepting Back so the
    /// page pops normally (edits still persist and apply on next launch).
    func acknowledgeLibraryEdits() { librariesDidEdit = false }

    private(set) var collectionView: UICollectionView!
    private var rows: [SettingsRowItem] = []
    private static let cellID = SettingsCell.reuseID

    /// Tracks the focused row so a grab (hold Select) knows which row to act on.
    private var focusedIndexPath: IndexPath?
    /// The row currently grabbed in reorder/move mode (nil = not moving).
    private var movingIndexPath: IndexPath?
    /// Swallows the Select that ends a grab/drop so it doesn't also toggle.
    private var suppressNextSelect = false
    /// Gestures active ONLY during move mode (Up/Down slide, Select drop). The
    /// grab long-press is always active.
    private var moveGestures: [UIGestureRecognizer] = []

    init(page: SettingsPage) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        rebuildRows()

        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                            heightDimension: .absolute(64)))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                       heightDimension: .absolute(64)),
                                                     subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 8
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 24, trailing: 24)
        let layout = UICollectionViewCompositionalLayout(section: section)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(SettingsCell.self, forCellWithReuseIdentifier: Self.cellID)
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

        moveGestures = [
            moveGesture(.upArrow, #selector(moveUp)),
            moveGesture(.downArrow, #selector(moveDown)),
            moveGesture(.select, #selector(dropGrab))
        ]
        moveGestures.forEach { $0.isEnabled = false; collectionView.addGestureRecognizer($0) }

        // Kick off any background load this page needs (e.g. fetch Plex Home
        // users) and refresh the list when it arrives.
        SettingsContent.prepareAsync(for: page) { [weak self] in self?.reloadRows() }
    }

    private func moveGesture(_ type: UIPress.PressType, _ action: Selector) -> UITapGestureRecognizer {
        let gr = UITapGestureRecognizer(target: self, action: action)
        gr.allowedPressTypes = [NSNumber(value: type.rawValue)]
        return gr
    }

    @objc private func handleGrab(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began, movingIndexPath == nil,
              let ip = focusedIndexPath, ip.item < rows.count,
              rows[ip.item].isReorderable else { return }
        movingIndexPath = ip
        suppressNextSelect = true            // the grab hold's release must not toggle
        setMoveGesturesEnabled(true)
        (collectionView.cellForItem(at: ip) as? SettingsCell)?.setReordering(true)
    }

    @objc private func moveUp() { moveHeld(up: true) }
    @objc private func moveDown() { moveHeld(up: false) }

    private func moveHeld(up: Bool) {
        guard let from = movingIndexPath else { return }
        let toItem = from.item + (up ? -1 : 1)
        // Only slide within the reorderable run (don't pass Add All / Remove All).
        guard toItem >= 0, toItem < rows.count, rows[toItem].isReorderable else { return }
        let to = IndexPath(item: toItem, section: 0)
        rows[from.item].onReorder?(up)        // persist the single-step move
        markLibraryEdit()
        let moved = rows.remove(at: from.item)
        rows.insert(moved, at: toItem)
        collectionView.performBatchUpdates { collectionView.moveItem(at: from, to: to) }
        movingIndexPath = to
        focusedIndexPath = to
    }

    @objc private func dropGrab() {
        guard let ip = movingIndexPath else { return }
        (collectionView.cellForItem(at: ip) as? SettingsCell)?.setReordering(false)
        movingIndexPath = nil
        suppressNextSelect = true             // swallow the drop click so it doesn't toggle
        setMoveGesturesEnabled(false)
    }

    private func setMoveGesturesEnabled(_ on: Bool) {
        moveGestures.forEach { $0.isEnabled = on }
    }

    private var hasAppeared = false
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
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
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.cellID, for: indexPath) as! SettingsCell
        let item = rows[indexPath.item]
        cell.configure(title: item.title, value: item.valueText, showsChevron: item.showsChevron,
                       destructive: item.isDestructive, showsCheckmark: item.showsCheckmark)
        cell.onFocusGained = { [weak self] in self?.onFocusRow?(item.id) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        rows[indexPath.item].isFocusable
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // A long-press just fired its menu; swallow the trailing Select so it
        // doesn't also toggle the row.
        if suppressNextSelect { suppressNextSelect = false; return }
        let item = rows[indexPath.item]
        switch item.kind {
        case .navigation(let target), .navigationValue(let target, _):
            onPush?(target)
        case .navigationAction(let target, _, let prepare):
            prepare()
            onPush?(target)
        case .toggle(let get, let set):
            set(!get())
            (collectionView.cellForItem(at: indexPath) as? SettingsCell)?.updateValue(get() ? "On" : "Off")
            markLibraryEdit()
        case .cycle(let value, let next):
            next()
            (collectionView.cellForItem(at: indexPath) as? SettingsCell)?.updateValue(value())
        case .action(_, let handler):
            handler(self)
            if item.id == "addAllLibraries" || item.id == "removeAllLibraries" { markLibraryEdit() }
        case .option(_, let select):
            select()
            onPop?()
        case .selectable(_, _, let handler):
            // The handler owns its own list refresh (it may switch synchronously
            // or present a PIN modal and reload on dismiss).
            handler(self)
        case .textEntry(let value, let placeholder, let hint, let suggestions, let keyboardType, let set):
            let entry = TextEntryViewController(
                title: item.title, initialText: value(), placeholder: placeholder,
                hint: hint, suggestions: suggestions, keyboardType: keyboardType,
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
        movingIndexPath == nil
    }
}
