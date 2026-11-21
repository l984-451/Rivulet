// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveSmartListMenu.swift
//  Rivulet
//
//  Making and changing a smart list from the List layout's hold menu, in the
//  same popups as the viewer's own lists: pick a kind of rule, pick a value,
//  confirm the suggested name. A smart list's own hold menu adds or removes
//  rules; a value already in the list shows a checkmark and Select takes it out.
//

import UIKit

@MainActor
enum LiveSmartListMenu {
    /// The hold-menu row that starts a new smart list.
    static func newAction(from presenter: UIViewController, sourceIdFilter: String?) -> TileMenuAction {
        TileMenuAction(title: "New Smart List…", systemImage: "gearshape.2") {
            presentRuleKinds(from: presenter, sourceIdFilter: sourceIdFilter, rules: LiveSmartRules()) { rule in
                let names = sourceNames()
                LiveProgramMenu.presentNameEntry(
                    title: "New Smart List",
                    initialText: LiveSmartRules.suggestedName(for: rule, sourceNames: names),
                    from: presenter) { name in
                    LiveChannelListStore.shared.createSmartList(named: name, rules: LiveSmartRules([rule]))
                }
            }
        }
    }

    /// A smart list's rule rows: Add Rule, then each rule (Select removes it while another is left).
    static func editSections(listId: String, from presenter: UIViewController,
                             sourceIdFilter: String?) -> [[TileMenuAction]] {
        let store = LiveChannelListStore.shared
        guard let rules = store.list(listId)?.rules else { return [] }
        let add = TileMenuAction(title: "Add Rule…", systemImage: "plus") {
            presentRuleKinds(from: presenter, sourceIdFilter: sourceIdFilter, rules: rules) { rule in
                toggle(rule, in: listId)
            }
        }
        let names = sourceNames()
        let current = rules.rules.map { rule in
            TileMenuAction(verbatim: LiveSmartRules.title(of: rule, sourceNames: names),
                           systemImage: rules.rules.count > 1 ? "minus.circle" : "checkmark") {
                toggle(rule, in: listId)
            }
        }
        return [[add], current]
    }

    // MARK: - Picking a rule

    static func presentRuleKinds(from presenter: UIViewController, sourceIdFilter: String?,
                                         rules: LiveSmartRules, onPick: @escaping (LiveSmartRules.Rule) -> Void) {
        let data = LiveTVDataStore.shared
        let lineup = sourceIdFilter.map { id in data.channels.filter { $0.sourceId == id } } ?? data.channels
        var kinds: [TileMenuAction] = []
        let origins = LiveSmartRules.origins(in: lineup)
        if !origins.isEmpty {
            kinds.append(TileMenuAction(title: "Country or Language", systemImage: "globe") {
                presentValues(origins.map { .origin($0) }, title: String(localized: "Country or Language"),
                              rules: rules, from: presenter, onPick: onPick)
            })
        }
        kinds.append(TileMenuAction(title: "Genre", systemImage: "theatermasks") {
            presentValues(LiveGenre.allCases.map { .genre($0) }, title: String(localized: "Genre"),
                          rules: rules, from: presenter, onPick: onPick)
        })
        let sources = data.sources.filter { source in lineup.contains { $0.sourceId == source.id } }
        if sourceIdFilter == nil, sources.count > 1 {
            kinds.append(TileMenuAction(title: "Source", systemImage: "antenna.radiowaves.left.and.right") {
                presentValues(sources.map { .source($0.id) }, title: String(localized: "Source"),
                              rules: rules, from: presenter, onPick: onPick)
            })
        }
        kinds.append(TileMenuAction(title: "Name Contains…", systemImage: "textformat") {
            let entry = TextEntryViewController(
                title: String(localized: "Name Contains"), fieldName: String(localized: "Word in the Channel Name"),
                initialText: "", allowsEmpty: false) { word in
                let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { onPick(.word(trimmed)) }
            }
            presentAfterMenu(entry, from: presenter, animated: true)
        })
        presentAfterMenu(TileMenuPopupViewController(
            sections: [kinds], header: TileMenuHeader(title: String(localized: "Smart List"))), from: presenter)
    }

    static func presentValues(_ values: [LiveSmartRules.Rule], title: String, rules: LiveSmartRules,
                                      from presenter: UIViewController,
                                      onPick: @escaping (LiveSmartRules.Rule) -> Void) {
        guard !values.isEmpty else { return }
        let names = sourceNames()
        let rows = values.map { rule in
            TileMenuAction(verbatim: LiveSmartRules.title(of: rule, sourceNames: names),
                           systemImage: rules.contains(rule) ? "checkmark" : "") { onPick(rule) }
        }
        presentAfterMenu(TileMenuPopupViewController(sections: [rows], header: TileMenuHeader(title: title)),
                         from: presenter)
    }

    // MARK: - Helpers

    /// Adds a rule the list lacks, or takes out one it has while another is left.
    private static func toggle(_ rule: LiveSmartRules.Rule, in listId: String) {
        let store = LiveChannelListStore.shared
        guard var rules = store.list(listId)?.rules else { return }
        if rules.contains(rule) { rules.remove(rule) } else { rules.add(rule) }
        store.setRules(rules, for: listId)
    }

    private static func sourceNames() -> [String: String] {
        Dictionary(LiveTVDataStore.shared.sources.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    /// Presents once the menu that led here has closed.
    private static func presentAfterMenu(_ controller: UIViewController, from presenter: UIViewController,
                                         animated: Bool = false) {
        DispatchQueue.main.async {
            let top = LiveProgramMenu.topmost(from: presenter)
            if let transition = top.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { _ in
                    LiveProgramMenu.topmost(from: presenter).present(controller, animated: animated)
                }
            } else {
                top.present(controller, animated: animated)
            }
        }
    }
}
