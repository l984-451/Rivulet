// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// The player's "Search for Subtitles" sheet: the server's results, a click downloads one and turns it on.
struct MacSubtitleSearchPane: View {
    @ObservedObject var model: SubtitleSearchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search Results").font(.headline)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            content
        }
        .frame(width: 420, height: 380)
        .onAppear { model.start() }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .searching:
            ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .downloading:
            ProgressView("Downloading Subtitles…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle")
        case .results(let results) where results.isEmpty:
            ContentUnavailableView("No Subtitles Found", systemImage: "captions.bubble")
        case .results(let results):
            List(results) { result in
                Button { model.choose(result) { dismiss() } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.displayTitle).lineLimit(2)
                        if !result.detail.isEmpty {
                            Text(result.detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
