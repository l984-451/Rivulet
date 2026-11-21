// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveProgramMenu.swift
//  Rivulet
//
//  The long-press menu for a programme in the guide (issue #318): what the
//  programme is (title, time, channel, description) and what can be done with
//  it — watch the channel, favourite it, put it on one of the viewer's own
//  lists, record the airing or the series, cancel a recording. Built on the canonical tile menu, so it looks and behaves like
//  every other long-press menu in the app.
//

import UIKit

@MainActor
enum LiveProgramMenu {

    /// Present the menu for `program` on `channel` over `presenter`.
    /// `program` is nil for a row with no guide data; the menu then offers
    /// only what the channel itself supports. `onMultiview` adds "Watch in
    /// Multiview" where the host has a multiview to open.
    static func present(
        program: UnifiedProgram?,
        channel: UnifiedChannel,
        from presenter: UIViewController,
        sourceFrame: CGRect? = nil,
        onWatch: @escaping (UnifiedChannel) -> Void,
        onMultiview: ((UnifiedChannel) -> Void)? = nil
    ) {
        Task { @MainActor in
            let sections = await makeSections(program: program, channel: channel,
                                              presenter: presenter, onWatch: onWatch,
                                              onMultiview: onMultiview)
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
        let channelLine = [channel.displayNumber.map(String.init), channel.displayName]
            .compactMap { $0 }
            .joined(separator: " · ")
        guard let program, !program.id.contains(":placeholder:") else {
            return TileMenuHeader(title: channel.displayName, detail: channelLine)
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
        onWatch: @escaping (UnifiedChannel) -> Void,
        onMultiview: ((UnifiedChannel) -> Void)?
    ) async -> [[TileMenuAction]] {
        let store = LiveTVDataStore.shared
        var watch: [TileMenuAction] = []
        var record: [TileMenuAction] = []

        let airingNow = program.map { $0.startTime <= Date() && $0.endTime > Date() } ?? true
        watch.append(TileMenuAction(
            title: airingNow ? "Watch Now" : "Watch \(channel.displayName)",
            systemImage: "play.fill"
        ) { onWatch(channel) })
        if let onMultiview, airingNow {
            watch.append(TileMenuAction(title: "Watch in Multiview", systemImage: "rectangle.split.2x2") {
                onMultiview(channel)
            })
        }
        let isFavorite = store.isFavorite(channel)
        watch.append(TileMenuAction(
            title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
            systemImage: isFavorite ? "star.slash" : "star"
        ) { store.toggleFavorite(channel) })
        watch.append(TileMenuAction(title: "Add to List…", systemImage: "text.badge.plus") {
            presentListChooser(for: channel, from: presenter)
        })

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
                        verbatim: option.title,
                        systemImage: option.scope == .series ? "square.stack.3d.up" : "record.circle"
                    ) {
                        run(on: presenter) { try await store.record(option, program: program, on: channel) }
                    })
                }
            }
        }
        return [watch, record]
    }

    // MARK: - Own lists

    /// The viewer's lists, ticked where the channel is on one: Select adds it
    /// or takes it off. "New List…" names a new one holding the channel.
    static func presentListChooser(for channel: UnifiedChannel, from presenter: UIViewController) {
        let lists = LiveChannelListStore.shared
        // A smart list fills itself; only the viewer's own lists take a channel.
        let rows = lists.lists.filter { !$0.isSmart }.map { list in
            TileMenuAction(verbatim: list.name,
                           systemImage: list.channelIds.contains(channel.id) ? "checkmark" : "list.bullet") {
                lists.toggle(channel.id, in: list.id)
            }
        }
        let new = TileMenuAction(title: "New List…", systemImage: "plus") {
            presentNameEntry(title: "New List", initialText: "", from: presenter) { name in
                lists.createList(named: name, with: channel.id)
            }
        }
        let popup = TileMenuPopupViewController(
            sections: [rows, [new]],
            header: TileMenuHeader(title: String(localized: "Add to List"), detail: channel.displayNumberAndName))
        // The programme menu has just closed; present after it.
        DispatchQueue.main.async { topmost(from: presenter).present(popup, animated: false) }
    }

    /// The keyboard for a list's name, presented once any closing menu is gone.
    static func presentNameEntry(title: String.LocalizationValue, initialText: String,
                                 from presenter: UIViewController, onCommit: @escaping (String) -> Void) {
        let entry = TextEntryViewController(title: String(localized: title), fieldName: String(localized: "List Name"),
                                            initialText: initialText, allowsEmpty: false) { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { onCommit(trimmed) }
        }
        DispatchQueue.main.async {
            let top = topmost(from: presenter)
            if let transition = top.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { _ in topmost(from: presenter).present(entry, animated: true) }
            } else {
                top.present(entry, animated: true)
            }
        }
    }

    /// Runs a DVR change after the menu has closed, and says so if it failed.
    /// Success needs no message: the guide marks the programme.
    private static func run(on presenter: UIViewController, _ change: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await change()
            } catch {
                let alert = UIAlertController(
                    title: String(localized: "Recording Didn't Change"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                topmost(from: presenter).present(alert, animated: true)
            }
        }
    }

    static func topmost(from presenter: UIViewController) -> UIViewController {
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
