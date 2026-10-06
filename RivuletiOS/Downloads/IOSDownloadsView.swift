// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Pushes the Downloads list onto a tab's stack.
struct IOSDownloadsRoute: Hashable {}

/// Every download of the current profile: Movies, then each show's seasons.
/// Renders from local records only, so it works with no server at all.
struct IOSDownloadsView: View {
    var showsAccount = false
    @EnvironmentObject private var downloads: IOSDownloadCenter
    @EnvironmentObject private var playback: IOSPlaybackController
    @Environment(\.plexActions) private var actions

    private struct Shelf: Identifiable {
        let id: String
        let title: String
        let records: [DownloadRecord]
    }

    private var groups: [Shelf] {
        let records = downloads.visibleRecords
        let movies = records.filter { $0.metadata.type != "episode" }
            .sorted { $0.metadata.displayTitle.localizedStandardCompare($1.metadata.displayTitle) == .orderedAscending }
        let seasons = Dictionary(grouping: records.filter { $0.metadata.type == "episode" }) {
            "\($0.metadata.grandparentRatingKey ?? $0.metadata.showTitle)|\($0.metadata.parentIndex ?? 0)"
        }
        let shows = seasons.map { key, records in
            let episodes = records.sorted { ($0.metadata.index ?? 0) < ($1.metadata.index ?? 0) }
            let first = episodes[0].metadata
            let season = first.parentIndex.map { $0 == 0 ? "Specials" : "Season \($0)" }
            return (show: first.showTitle, season: first.parentIndex ?? 0, group: Shelf(
                id: key, title: [first.showTitle, season].compactMap { $0 }.joined(separator: " · "), records: episodes))
        }
        .sorted { lhs, rhs in
            let order = lhs.show.localizedStandardCompare(rhs.show)
            return order == .orderedSame ? lhs.season < rhs.season : order == .orderedAscending
        }
        .map(\.group)
        return (movies.isEmpty ? [] : [Shelf(id: "movies", title: "Movies", records: movies)]) + shows
    }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.records) { record in
                        row(record)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if downloads.visibleRecords.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Movies and episodes you download appear here, ready to watch offline.")
                )
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if showsAccount { IOSAccountToolbarItem() }
        }
    }

    @ViewBuilder
    private func row(_ record: DownloadRecord) -> some View {
        Button {
            switch record.state {
            // By record: its ratingKey may name another item on the current server.
            case .completed:
                if let request = downloads.localPlayback(record: record) { playback.play(request) }
            case .failed: downloads.retry(recordID: record.id)
            default: break
            }
        } label: {
            IOSDownloadRow(record: record, isPreparing: actions.preparingID == record.metadata.id)
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(record.state.isSettled ? "Delete" : "Cancel", systemImage: "trash", role: .destructive) {
                downloads.delete(recordID: record.id)
            }
        }
    }
}

private struct IOSDownloadRow: View {
    let record: DownloadRecord
    let isPreparing: Bool
    @EnvironmentObject private var plex: IOSPlexSession

    private var item: PlexMetadata { record.metadata }

    private var posterURL: URL? {
        record.posterFileName.map { IOSDownloadTransfer.directory.appending(path: $0) }
            ?? plex.artworkURL(for: item, kind: .poster, width: 180, height: 270)
    }

    private var title: String {
        guard item.type == "episode" else { return item.displayTitle }
        return [item.index.map { "E\($0)" }, item.displayTitle].compactMap { $0 }.joined(separator: " · ")
    }

    private var isFailed: Bool {
        if case .failed = record.state { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 14) {
            IOSPlexImage(url: posterURL)
                .frame(width: 56, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(record.statusText)
                    .font(.subheadline)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(3)
                if let progress = record.progress {
                    ProgressView(value: progress)
                }
            }
            Spacer(minLength: 0)
            if isPreparing {
                ProgressView()
            } else if record.state == .completed {
                Image(systemName: "play.circle")
                    .font(.title2)
                    .foregroundStyle(.tint)
            } else if isFailed {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(record.state == .completed ? "Plays" : (isFailed ? "Retries the download" : ""))
    }
}

// MARK: - Detail button

/// The detail page's download circle: Download, a progress ring, or a filled arrow with Play and Remove.
struct IOSDownloadButton: View {
    let item: PlexMetadata
    @EnvironmentObject private var downloads: IOSDownloadCenter
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.plexActions) private var actions

    var body: some View {
        if let key = item.ratingKey, let record = downloads.record(for: key) {
            Menu {
                Section(record.statusText) {
                    switch record.state {
                    case .completed:
                        Button("Play", systemImage: "play.fill") { actions.play(item) }
                    case .failed:
                        Button("Retry Download", systemImage: "arrow.clockwise") { downloads.retry(recordID: record.id) }
                    default:
                        EmptyView()
                    }
                    Button(record.state.isSettled ? "Remove Download" : "Cancel Download",
                           systemImage: "trash", role: .destructive) {
                        downloads.delete(recordID: record.id)
                    }
                }
            } label: {
                icon(record).frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Download")
            .accessibilityValue(record.statusText)
        } else {
            Button { actions.download(item) } label: {
                Image(systemName: "arrow.down").frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(!plex.isConfigured)
            .accessibilityLabel("Download")
        }
    }

    @ViewBuilder
    private func icon(_ record: DownloadRecord) -> some View {
        switch record.state {
        case .completed:
            // Not a checkmark: the watchlist button beside it uses one.
            Image(systemName: "arrow.down.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark")
        default:
            // The App Store's ring: track, filled arc, stop square.
            ZStack {
                Circle().stroke(.secondary.opacity(0.4), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: record.progress ?? 0)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                RoundedRectangle(cornerRadius: 1.5).frame(width: 7, height: 7)
            }
            .frame(width: 19, height: 19)
            .animation(.easeOut(duration: 0.3), value: record.progress)
        }
    }
}

// MARK: - Status

extension DownloadRecord {
    /// What a row or menu says about this download.
    var statusText: String {
        func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        switch state {
        case .waitingForNetwork:
            return "Waiting for Wi-Fi"
        case .waitingForServer:
            return "Waiting for Server"
        case .preparing(let progress):
            return "Preparing on Server \(Int(progress))%"
        case .downloading:
            guard let expected = expectedBytes, expected > 0 else {
                return receivedBytes > 0 ? "Downloading · \(size(receivedBytes))" : "Downloading"
            }
            let percent = Int(Double(receivedBytes) / Double(expected) * 100)
            return "Downloading \(percent)% · \(size(receivedBytes)) of \(size(expected))"
        case .paused:
            return "Paused"
        case .failed(let reason):
            return "Failed: \(reason)"
        case .completed:
            return ["Downloaded", outputLabel, expectedBytes.map(size)].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// 0 to 1 while the server converts or the file transfers.
    var progress: Double? {
        switch state {
        case .preparing(let progress):
            return min(max(progress / 100, 0), 1)
        case .downloading:
            guard let expected = expectedBytes, expected > 0 else { return nil }
            return min(Double(receivedBytes) / Double(expected), 1)
        default:
            return nil
        }
    }
}
