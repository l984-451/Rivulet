// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// What a programme is, with Watch, Record and Favorite. `onWatch` nil hides Watch.
/// The presenter plays once the sheet is gone.
struct MacLiveProgrammeSheet: View {
    let selection: LiveProgrammeSelection
    let onWatch: ((UnifiedChannel) -> Void)?
    @ObservedObject private var store = LiveTVDataStore.shared
    @StateObject private var recorder = LiveRecorder()
    @Environment(\.dismiss) private var dismiss
    @State private var wideArt: URL?

    private var channel: UnifiedChannel { selection.channel }
    private var program: UnifiedProgram? { selection.program }

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let url = wideArt ?? program?.posterURL {
                        MacImage(url: url)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    header
                    actions
                    if let description = program?.description, !description.isEmpty {
                        Text(description).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .frame(height: contentHeight > 0 ? min(contentHeight, 560) : nil)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .modifier(MacLiveWideArt(program: program, url: $wideArt))
        .liveRecorder(recorder)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                MacLiveLogo(url: channel.logoURL).frame(width: 40, height: 24)
                Text(channel.displayNumberAndName).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(program?.displayTitle ?? channel.displayName).font(.title2.bold())
            if let subtitle = program?.subtitle, !subtitle.isEmpty, subtitle != program?.title {
                Text(subtitle).font(.headline)
            }
            if let program {
                Text(details(program)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func details(_ program: UnifiedProgram) -> String {
        var parts = [program.timeRange]
        if !Calendar.current.isDateInToday(program.startTime) {
            parts.insert(program.startTime.formatted(.dateTime.weekday(.wide)), at: 0)
        }
        if let episode = program.episodeNumber, !episode.isEmpty { parts.append(episode) }
        if let year = program.year { parts.append(String(year)) }
        if let rating = program.contentRating, !rating.isEmpty { parts.append(rating) }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        let airing = program?.isCurrentlyAiring ?? true
        let isFavorite = store.isFavorite(channel)
        return VStack(spacing: 10) {
            if let onWatch {
                Button {
                    onWatch(channel)
                    dismiss()
                } label: {
                    Label(airing ? "Watch" : "Watch \(channel.displayName) Live", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 10) {
                if let program { MacLiveRecordControl(channel: channel, program: program, recorder: recorder) }
                Button { store.toggleFavorite(channel) } label: {
                    Label(isFavorite ? "Favorite" : "Add to Favorites", systemImage: isFavorite ? "star.fill" : "star")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
        }
        .controlSize(.large)
    }
}
