// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveProgramMenu.swift
//  Rivulet
//
//  The long-press menu for a programme in the guide (issue #318): what the
//  programme is (title, time, channel, description) and what can be done with
//  it — watch the channel, record the airing or the series, cancel a
//  recording. Built on the canonical tile menu, so it looks and behaves like
//  every other long-press menu in the app.
//

import UIKit

@MainActor
enum LiveProgramMenu {

    /// Present the menu for `program` on `channel` over `presenter`.
    /// `program` is nil for a row with no guide data; the menu then offers
    /// only what the channel itself supports.
    static func present(
        program: UnifiedProgram?,
        channel: UnifiedChannel,
        from presenter: UIViewController,
        sourceFrame: CGRect? = nil,
        onWatch: @escaping (UnifiedChannel) -> Void
    ) {
        Task { @MainActor in
            let sections = await makeSections(program: program, channel: channel,
                                              presenter: presenter, onWatch: onWatch)
            let popup = TileMenuPopupViewController(
                sections: sections,
                sourceFrame: sourceFrame,
                header: header(program: program, channel: channel)
            )
            topmost(from: presenter).present(popup, animated: false)
        }
    }

    // MARK: - Content

    private static func header(program: UnifiedProgram?, channel: UnifiedChannel) -> TileMenuHeader {
        let channelLine = [channel.channelNumber.map(String.init), channel.name]
            .compactMap { $0 }
            .joined(separator: " · ")
        guard let program, !program.id.contains(":placeholder:") else {
            return TileMenuHeader(title: channel.name, detail: channelLine)
        }
        let time = Date.FormatStyle.dateTime.hour().minute()
        var detailParts = [
            "\(program.startTime.formatted(time)) – \(program.endTime.formatted(time))",
            channelLine,
        ]
        if let episode = program.episodeNumber, !episode.isEmpty { detailParts.append(episode) }
        if let year = program.year { detailParts.append(String(year)) }
        if let rating = program.contentRating, !rating.isEmpty { detailParts.append(rating) }

        var title = program.title
        if let subtitle = program.subtitle, !subtitle.isEmpty, subtitle != program.title {
            title += " — \(subtitle)"
        }
        return TileMenuHeader(title: title, detail: detailParts.joined(separator: " · "),
                              summary: program.description)
    }

    private static func makeSections(
        program: UnifiedProgram?,
        channel: UnifiedChannel,
        presenter: UIViewController,
        onWatch: @escaping (UnifiedChannel) -> Void
    ) async -> [[TileMenuAction]] {
        let store = LiveTVDataStore.shared
        var watch: [TileMenuAction] = []
        var record: [TileMenuAction] = []

        let airingNow = program.map { $0.startTime <= Date() && $0.endTime > Date() } ?? true
        watch.append(TileMenuAction(
            title: airingNow ? "Watch Now" : "Watch \(channel.name)",
            systemImage: "play.fill"
        ) { onWatch(channel) })

        if let program, !program.id.contains(":placeholder:"),
           program.endTime > Date(), store.canRecord(channel) {
            if let recording = store.activeRecording(for: program) {
                record.append(TileMenuAction(
                    title: recording.status == .recording ? "Stop Recording" : "Cancel Recording",
                    systemImage: "stop.circle",
                    destructive: true
                ) {
                    run(on: presenter) { try await store.cancel(recording) }
                })
                if recording.ruleIsSeries {
                    record.append(TileMenuAction(
                        title: "Cancel Series",
                        systemImage: "square.stack.3d.up.slash",
                        destructive: true
                    ) {
                        run(on: presenter) { try await store.cancelSeries(of: recording) }
                    })
                }
            } else if let options = try? await store.recordOptions(for: program, on: channel) {
                for option in options {
                    record.append(TileMenuAction(
                        title: option.title,
                        systemImage: option.scope == .series ? "square.stack.3d.up" : "record.circle"
                    ) {
                        run(on: presenter) { try await store.record(option, program: program, on: channel) }
                    })
                }
            }
        }
        return [watch, record]
    }

    /// Runs a DVR change after the menu has closed, and says so if it failed.
    /// Success needs no message: the guide marks the programme.
    private static func run(on presenter: UIViewController, _ change: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await change()
            } catch {
                let alert = UIAlertController(
                    title: "Recording Didn't Change",
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                topmost(from: presenter).present(alert, animated: true)
            }
        }
    }

    private static func topmost(from presenter: UIViewController) -> UIViewController {
        var top = presenter
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// The app's topmost view controller, for callers that live in SwiftUI.
    static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let root = (scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first)?.rootViewController
        else { return nil }
        return topmost(from: root)
    }
}
