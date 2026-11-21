// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Asking Seerr for a movie or a show's seasons, shared by the Search
// tile's long-press menu and the detail page's Request pill.

import os
import UIKit

@MainActor
enum SeerrRequestFlow {
    // MARK: - Requests

    /// Asks for a movie, after its quality. `done` gets its new state; a failure shows its reason instead.
    static func requestMovie(_ tmdbID: Int, title: String, from presenter: UIViewController, sourceFrame: CGRect?,
                             done: @escaping @MainActor (SeerrAvailability) -> Void) {
        chooseQuality(.movie, title: title, from: presenter, sourceFrame: sourceFrame) { quality in
            send(from: presenter, { try await $0.requestMovie(tmdbID, quality: quality) }, onSuccess: { done(.requested) })
        }
    }

    // MARK: - Quality

    /// Lets the person pick a quality profile, then runs `then` with it. With one profile or none
    /// (or Radarr/Sonarr unreadable) there is nothing to pick, and Seerr's default applies.
    static func chooseQuality(_ kind: SeerrTitle.Kind, title: String, from presenter: UIViewController,
                              sourceFrame: CGRect?, then: @escaping @MainActor (SeerrQualityOption?) -> Void) {
        Task {
            let options = await SeerrCatalog.qualityOptions(kind)
            guard options.count > 1 else { return then(nil) }
            let rows = options.map { option in
                TileMenuAction(verbatim: option.title, systemImage: option.is4K ? "4k.tv" : "tv") { then(option) }
            }
            await waitUntilFree(presenter)
            // Just the choices: the title is already on screen, and a header adds a rule above them.
            present([rows], header: nil, from: presenter, sourceFrame: sourceFrame)
        }
    }

    /// A menu dismisses itself as its action runs; the next popup waits for it to leave.
    private static func waitUntilFree(_ presenter: UIViewController) async {
        for _ in 0..<20 where presenter.presentedViewController != nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The season list for a show: All Seasons when more than one can be asked for, then each
    /// season with its state, then `extra` (More Info from Search). The title heads the list only
    /// from a Search tile (where `extra` is passed); the detail page already shows it. `done` gets
    /// the show's new state after a request.
    static func presentSeasons(of tmdbID: Int, title: String, detail: String?, from presenter: UIViewController,
                               sourceFrame: CGRect?, extra: [TileMenuAction] = [],
                               done: @escaping @MainActor (SeerrAvailability) -> Void) {
        Task {
            guard let client = SeerrClient.configured else { return showError(SeerrError.notConfigured, from: presenter) }
            do {
                let show = try await client.show(tmdbID)
                let sections = seasonMenu(show, tmdbID: tmdbID, title: title, from: presenter,
                                          sourceFrame: sourceFrame, done: done)
                present(sections + (extra.isEmpty ? [] : [extra]),
                        header: extra.isEmpty ? nil : TileMenuHeader(title: title, detail: detail),
                        from: presenter, sourceFrame: sourceFrame)
            } catch {
                showError(error, from: presenter)
            }
        }
    }

    private static func seasonMenu(_ show: SeerrShow, tmdbID: Int, title: String, from presenter: UIViewController,
                                   sourceFrame: CGRect?,
                                   done: @escaping @MainActor (SeerrAvailability) -> Void) -> [[TileMenuAction]] {
        let seasons = show.seasons
        let open = SeerrSeasons.requestableNumbers(seasons)
        func ask(_ numbers: [Int]) {
            chooseQuality(.tv, title: title, from: presenter, sourceFrame: sourceFrame) { quality in
                send(from: presenter, { try await $0.requestShow(tmdbID, seasons: numbers, quality: quality) }, onSuccess: {
                    done(SeerrSeasons.availability(after: numbers, of: seasons, was: show.pillState))
                })
            }
        }
        var sections: [[TileMenuAction]] = []
        if open.count > 1 {
            sections.append([TileMenuAction(title: "Request All Seasons",
                                            systemImage: "plus.circle") { ask(open) }])
        }
        let rows = seasons.map { season -> TileMenuAction in
            let name = season.name.isEmpty ? String(localized: "Season \(season.number)") : season.name
            guard season.availability.canRequest else {
                return TileMenuAction(verbatim: "\(name) · \(season.availability.badge ?? "")",
                                      systemImage: season.availability.symbolName, handler: {})
            }
            return TileMenuAction(title: "Request \(name)",
                                  systemImage: "plus.circle") { ask([season.number]) }
        }
        if !rows.isEmpty { sections.append(rows) }
        return sections
    }

    // MARK: - Shared pieces

    static func present(_ sections: [[TileMenuAction]], header: TileMenuHeader?,
                        from presenter: UIViewController, sourceFrame: CGRect?) {
        guard presenter.presentedViewController == nil, sections.contains(where: { !$0.isEmpty }) else { return }
        // animated: false: the popup runs its own grow-from-the-source entrance, as the app's other menus.
        presenter.present(TileMenuPopupViewController(sections: sections, sourceFrame: sourceFrame, header: header),
                          animated: false)
    }

    private static func send(from presenter: UIViewController,
                             _ call: @escaping @Sendable (SeerrClient) async throws -> Void,
                             onSuccess: @escaping @MainActor () -> Void) {
        Task {
            guard let client = SeerrClient.configured else { return showError(SeerrError.notConfigured, from: presenter) }
            do {
                try await call(client)
                onSuccess()
            } catch {
                showError(error, from: presenter)
            }
        }
    }

    static func showError(_ error: Error, from presenter: UIViewController) {
        SeerrCatalog.log.error("Seerr failed: \(error.localizedDescription, privacy: .public)")
        Task {
            await waitUntilFree(presenter)
            guard presenter.presentedViewController == nil else { return }
            presenter.present(ConfirmationPopupViewController(
                title: String(localized: "Couldn’t Request"),
                message: error.localizedDescription,
                confirmTitle: String(localized: "OK"),
                cancelTitle: nil, onConfirm: {}), animated: true)
        }
    }
}
