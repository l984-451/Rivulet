// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// The player's "Search for Subtitles" sheet: the server's results, a tap downloads one and turns it on.
struct IOSSubtitleSearchPane: View {
    @ObservedObject var model: SubtitleSearchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search Results")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .onAppear { model.start() }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .searching:
            ProgressView("Searching…")
        case .downloading:
            ProgressView("Downloading Subtitles…")
        case .failed:
            ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle")
        case .results(let results) where results.isEmpty:
            ContentUnavailableView("No Subtitles Found", systemImage: "captions.bubble")
        case .results(let results):
            List(results) { result in
                Button { model.choose(result) { dismiss() } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.displayTitle).font(.headline).lineLimit(2)
                        if !result.detail.isEmpty {
                            Text(result.detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}
