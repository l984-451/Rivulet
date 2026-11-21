// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Makes or changes a smart list: switches for countries, genres and sources, a
/// name-contains field, and the channels it holds as it is edited.
/// Logic is shared (`LiveSmartListDraft`, `LiveSmartRules`); the Mac has the same sheet.
struct IOSLiveSmartListEditor: View {
    let onSaved: (String?) -> Void
    @ObservedObject private var store = LiveTVDataStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LiveSmartListDraft
    @State private var confirmingDelete = false

    /// `onSaved` gets the list's id, or nil once it is deleted.
    init(listId: String?, onSaved: @escaping (String?) -> Void) {
        self.onSaved = onSaved
        _draft = State(initialValue: LiveSmartListDraft(listId: listId))
    }

    private var sourceNames: [String: String] {
        Dictionary(store.sources.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    private var matches: Int {
        draft.finalRules.channels(in: store.channels, epg: store.epg, versions: store.lineupVersions).count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text(namePrompt))
                } footer: {
                    Text(draft.canSave ? "\(matches) channels" : "Choose at least one rule.")
                }
                let origins = LiveSmartRules.origins(in: store.channels)
                if !origins.isEmpty {
                    Section("Country or Language") {
                        DisclosureGroup(summary(of: origins.map { .origin($0) })) {
                            ForEach(origins, id: \.self) { toggle(.origin($0)) }
                        }
                    }
                }
                Section("Genre") {
                    ForEach(LiveGenre.allCases, id: \.self) { toggle(.genre($0)) }
                }
                if store.sources.count > 1 {
                    Section("Source") {
                        ForEach(store.sources.map(\.id), id: \.self) { toggle(.source($0)) }
                    }
                }
                Section {
                    TextField("Words, separated by commas", text: $draft.wordsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Name Contains")
                } footer: {
                    Text("Choices of one kind widen the list; different kinds narrow it.")
                }
                if draft.listId != nil {
                    Section {
                        Button("Delete Smart List", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(draft.listId == nil ? "New Smart List" : "Edit Smart List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSaved(draft.save(sourceNames: sourceNames))
                        dismiss()
                    }
                    .disabled(!draft.canSave)
                }
            }
            .confirmationDialog("Delete Smart List?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let id = draft.listId { LiveChannelListStore.shared.delete(id) }
                    onSaved(nil)
                    dismiss()
                }
            }
        }
    }

    private var namePrompt: String {
        draft.finalRules.rules.first.map { LiveSmartRules.suggestedName(for: $0, sourceNames: sourceNames) }
            ?? String(localized: "Name")
    }

    private func toggle(_ rule: LiveSmartRules.Rule) -> some View {
        Toggle(LiveSmartRules.title(of: rule, sourceNames: sourceNames), isOn: Binding(
            get: { draft.isOn(rule) }, set: { draft.set(rule, on: $0) }))
    }

    private func summary(of rules: [LiveSmartRules.Rule]) -> String {
        let chosen = rules.filter(draft.isOn).map { LiveSmartRules.title(of: $0) }
        return chosen.isEmpty ? String(localized: "Any") : chosen.joined(separator: ", ")
    }
}
