// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// What a programme is, and Watch, Record and Favorite in that order.
/// `onWatch` nil hides Watch (the player's own Info). The presenter plays
/// once the sheet is gone, since a cover cannot present over a closing sheet.
struct IOSLiveProgrammeSheet: View {
    let selection: IOSLiveProgrammeSelection
    let onWatch: ((UnifiedChannel) -> Void)?
    @ObservedObject private var store = LiveTVDataStore.shared
    @StateObject private var recorder = IOSLiveRecorder()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var wideArt: URL?

    private var channel: UnifiedChannel { selection.channel }
    private var program: UnifiedProgram? { selection.program }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    artwork
                    header
                    actions
                    if let description = program?.description, !description.isEmpty {
                        Text(description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { dismiss() }
                }
            }
        }
        .modifier(IOSLiveWideArt(program: program, url: $wideArt))
        .liveRecorder(recorder)
        .presentationDetents(sizeClass == .regular ? [.large] : [.medium, .large])
        .presentationSizing(.form)
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = wideArt ?? program?.posterURL {
            IOSPlexImage(url: url)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                IOSLiveLogo(url: channel.logoURL).frame(width: 40, height: 24)
                Text(channel.numberAndName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(program?.displayTitle ?? channel.name)
                .font(.title2.bold())
            if let subtitle = program?.subtitle, !subtitle.isEmpty, subtitle != program?.title {
                Text(subtitle).font(.headline)
            }
            if let program {
                Text(details(program))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

    @ViewBuilder
    private var actions: some View {
        let airing = program?.isCurrentlyAiring ?? true
        VStack(spacing: 10) {
            if let onWatch {
                Button {
                    onWatch(channel)
                    dismiss()
                } label: {
                    Label(airing ? "Watch" : "Watch \(channel.name) Live", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
            HStack(spacing: 10) {
                recordButton
                favoriteButton
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var recordButton: some View {
        if let program, program.endTime > Date(), store.canRecord(channel) {
            if let recording = store.activeRecording(for: program) {
                Menu {
                    Button(recording.status == .recording ? "Stop Recording" : "Cancel Recording",
                           systemImage: "stop.circle", role: .destructive) { recorder.cancel(recording) }
                    if recording.ruleIsSeries {
                        Button("Cancel Series", systemImage: "square.stack.3d.up.slash", role: .destructive) {
                            recorder.cancelSeries(of: recording)
                        }
                    }
                } label: {
                    Label(recording.status == .recording ? "Recording" : "Scheduled", systemImage: "record.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .tint(.red)
            } else {
                Button {
                    recorder.offerRecording(program, on: channel)
                } label: {
                    Label("Record", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(recorder.isLoadingOptions)
            }
        }
    }

    @ViewBuilder
    private var favoriteButton: some View {
        if store.isFavorite(channel) || !channel.isFavourite {
            let isFavorite = store.isFavorite(channel)
            Button {
                store.toggleFavorite(channel)
            } label: {
                Label(isFavorite ? "Favorite" : "Add to Favorites", systemImage: isFavorite ? "star.fill" : "star")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .sensoryFeedback(.selection, trigger: isFavorite)
            .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
    }
}
