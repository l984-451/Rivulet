// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The detail page's Request pill: for a title the library doesn't have,
// it takes Play's place and shows Seerr's state. A movie is requested in place; a show opens its
// season list. `MediaDetailChromeView` puts it first in its metadata-only action row.

import os
import UIKit

@MainActor
enum SeerrRequestPill {
    /// The pill for `item`, or nil when Seerr is off, the profile is restricted, or the item is in a library.
    static func make(for item: MediaItem) -> FocusableActionButton? {
        guard SeerrCatalog.isAvailable, let target = SeerrCatalog.target(item) else { return nil }
        let model = Model()
        let pill = model.build()
        let year = item.year.map(String.init)

        model.render(.requestable)
        Task { [weak model] in
            guard let client = SeerrClient.configured else { return }
            do {
                let state = target.kind == .movie
                    ? try await client.movieAvailability(target.tmdbID)
                    : try await client.show(target.tmdbID).pillState
                model?.render(state)
            } catch {
                SeerrCatalog.log.error("Seerr status failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // The button keeps the model alive through this closure; the model holds the button weakly.
        pill.onPrimaryAction = { [model] in
            guard let pill = model.button, !model.isBusy, let host = model.host else { return }
            switch target.kind {
            case .movie:
                guard model.state.canRequest else { return }
                model.isBusy = true
                SeerrRequestFlow.requestMovie(target.tmdbID, title: item.title, from: host,
                                              sourceFrame: pill.convert(pill.bounds, to: nil)) { state in model.render(state) }
                // A failure shows its own popup; the pill can be pressed again after a moment.
                Task { try? await Task.sleep(for: .seconds(3)); model.isBusy = false }
            case .tv:
                SeerrRequestFlow.presentSeasons(of: target.tmdbID, title: item.title, detail: year, from: host,
                                                sourceFrame: pill.convert(pill.bounds, to: nil)) { state in
                    model.render(state)
                }
            }
        }
        return pill
    }

    @MainActor
    private final class Model {
        weak var button: FocusableActionButton?
        private weak var icon: UIImageView?
        private weak var label: UILabel?
        private(set) var state: SeerrAvailability = .requestable
        var isBusy = false

        var host: UIViewController? {
            guard let button else { return nil }
            return sequence(first: button as UIResponder, next: \.next).first { $0 is UIViewController } as? UIViewController
        }

        /// Same geometry as the detail page's Play and Watchlist pills: centered icon and title,
        /// at least `HeroPillButton.pillWidth` wide.
        func build() -> FocusableActionButton {
            let pill = FocusableActionButton()
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.layer.cornerRadius = HeroPillButton.buttonHeight / 2
            pill.layer.cornerCurve = .continuous
            let icon = UIImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.tintColor = .white
            icon.contentMode = .scaleAspectFit
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = HeroPillButton.titleFont
            label.textColor = .white
            let content = UIStackView(arrangedSubviews: [icon, label])
            content.translatesAutoresizingMaskIntoConstraints = false
            content.axis = .horizontal
            content.alignment = .center
            content.spacing = HeroPillButton.iconGap
            pill.addSubview(content)
            let resting = pill.widthAnchor.constraint(equalToConstant: HeroPillButton.pillWidth)
            resting.priority = .defaultLow
            NSLayoutConstraint.activate([
                pill.widthAnchor.constraint(greaterThanOrEqualToConstant: HeroPillButton.pillWidth),
                resting,
                pill.heightAnchor.constraint(equalToConstant: HeroPillButton.buttonHeight),
                content.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
                content.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                content.leadingAnchor.constraint(greaterThanOrEqualTo: pill.leadingAnchor, constant: HeroPillButton.sidePadding),
                content.trailingAnchor.constraint(lessThanOrEqualTo: pill.trailingAnchor, constant: -HeroPillButton.sidePadding),
                icon.widthAnchor.constraint(equalToConstant: 24),
                icon.heightAnchor.constraint(equalToConstant: 24),
            ])
            pill.invertOnFocus = [icon, label]
            button = pill
            self.icon = icon
            self.label = label
            return pill
        }

        func render(_ state: SeerrAvailability) {
            self.state = state
            isBusy = false
            icon?.image = UIImage(systemName: state.symbolName)
            let text = state.badge ?? String(localized: "Request")
            label?.text = text
            button?.accessibilityLabel = text
        }
    }
}
