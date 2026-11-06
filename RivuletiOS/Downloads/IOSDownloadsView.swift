// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

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
        let movies = records.filter { $0.item.kind != .episode }
            .sorted { $0.item.displayTitle.localizedStandardCompare($1.item.displayTitle) == .orderedAscending }
        let seasons = Dictionary(grouping: records.filter { $0.item.kind == .episode }) {
            "\($0.providerID)|\($0.item.grandparentRef?.itemID ?? $0.item.seriesTitle ?? "")|\($0.item.seasonNumber ?? 0)"
        }
        let shows = seasons.map { key, records in
            let episodes = records.sorted { ($0.item.episodeNumber ?? 0) < ($1.item.episodeNumber ?? 0) }
            let first = episodes[0].item
            let showTitle = first.seriesTitle ?? first.displayTitle
            let season = first.seasonNumber.map { $0 == 0 ? String(localized: "Specials") : String(localized: "Season \($0)") }
            return (show: showTitle, season: first.seasonNumber ?? 0, group: Shelf(
                id: key, title: [showTitle, season].compactMap { $0 }.joined(separator: " · "), records: episodes))
        }
        .sorted { lhs, rhs in
            let order = lhs.show.localizedStandardCompare(rhs.show)
            return order == .orderedSame ? lhs.season < rhs.season : order == .orderedAscending
        }
        .map(\.group)
        return (movies.isEmpty ? [] : [Shelf(id: "movies", title: String(localized: "Movies"), records: movies)]) + shows
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
                playback.play(download: record)
            case .failed: downloads.retry(recordID: record.id)
            case .pausedByUser: downloads.resume(recordID: record.id)
            default: break
            }
        } label: {
            IOSDownloadRow(record: record, isPreparing: actions.preparingID == record.item.ref.actionKey)
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(record.state.isSettled ? "Delete" : "Cancel", systemImage: "trash", role: .destructive) {
                downloads.delete(recordID: record.id)
            }
            if record.state == .pausedByUser {
                Button("Resume", systemImage: "play.fill") { downloads.resume(recordID: record.id) }
                    .tint(.blue)
            } else if !record.state.isSettled {
                Button("Pause", systemImage: "pause.fill") { downloads.pause(recordID: record.id) }
                    .tint(.orange)
            }
        }
    }
}

private struct IOSDownloadRow: View {
    let record: DownloadRecord
    let isPreparing: Bool
    @EnvironmentObject private var plex: IOSPlexSession

    private var item: MediaItem { record.item }

    /// The saved poster; failing that, a Plex server's art by path, or another server's own image URL.
    private var posterURL: URL? {
        record.posterFileName.map { IOSDownloadTransfer.directory.appending(path: $0) }
            ?? (record.isPlex ? plex.artworkURL(for: record.metadata, kind: .poster, width: 180, height: 270) : item.artwork.poster)
    }

    private var title: String {
        guard item.kind == .episode else { return item.displayTitle }
        return [item.episodeNumber.map { String(localized: "E\($0)") }, item.displayTitle].compactMap { $0 }.joined(separator: " · ")
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
                    .font(.subheadline.monospacedDigit())
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
            } else if let percent = record.percentText {
                // Sized to "100%" so the row doesn't reflow as the number grows.
                Text("100%").hidden()
                    .overlay(alignment: .trailing) { Text(percent) }
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(record.state == .completed ? "Plays"
            : isFailed ? "Retries the download" : record.state == .pausedByUser ? "Resumes the download" : "")
    }
}

// MARK: - Detail button

/// The detail page's download circle: Download, a progress ring, or a filled arrow with Play and Remove.
struct IOSDownloadButton: View {
    let item: MediaItem
    @EnvironmentObject private var downloads: IOSDownloadCenter
    @EnvironmentObject private var plex: IOSPlexSession
    @EnvironmentObject private var browse: IOSBrowseStore
    @Environment(\.plexActions) private var actions

    var body: some View {
        if let record = downloads.record(for: item.ref) {
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
            .accessibilityValue([record.statusText, record.percentText].compactMap { $0 }.joined(separator: ", "))
        } else {
            Button { actions.download(item) } label: {
                Image(systemName: "arrow.down").frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(!browse.canDownload(item))
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
            return String(localized: "Waiting for Wi-Fi")
        case .waitingForServer:
            return String(localized: "Waiting for Server")
        case .preparing(let progress):
            return String(localized: "Preparing on Server")
        case .downloading:
            guard let expected = expectedBytes, expected > 0 else {
                return receivedBytes > 0 ? size(receivedBytes) : String(localized: "Downloading")
            }
            // Received in the total's unit, padded with digit-wide figure spaces to its width.
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = expected >= 1_000_000_000 ? .useGB : .useMB
            formatter.zeroPadsFractionDigits = true
            let total = formatter.string(fromByteCount: expected)
            let received = formatter.string(fromByteCount: min(receivedBytes, expected))
            return String(repeating: "\u{2007}", count: max(0, total.count - received.count)) + "\(received) / \(total)"
        case .paused, .pausedByUser:
            return String(localized: "Paused")
        case .failed(let reason):
            return String(localized: "Failed: \(reason)")
        case .completed:
            return [String(localized: "Downloaded"), outputLabel, expectedBytes.map(size)].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// The row's trailing percent while there is progress to show.
    var percentText: String? { progress.map { "\(Int($0 * 100))%" } }

    /// 0 to 1 while the server converts or the file transfers.
    var progress: Double? {
        switch state {
        case .preparing(let progress):
            return min(max(progress / 100, 0), 1)
        case .downloading, .pausedByUser:
            guard let expected = expectedBytes, expected > 0 else { return nil }
            return min(Double(receivedBytes) / Double(expected), 1)
        default:
            return nil
        }
    }
}
