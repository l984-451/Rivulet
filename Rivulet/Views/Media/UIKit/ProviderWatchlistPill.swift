// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// Saved catalog titles have watchlist state on their own server, even before a file arrives.
@MainActor
enum ProviderWatchlistPill {
    static func bind(_ pill: FocusableActionButton, icon: UIImageView, title: UILabel?,
                     item: MediaItem, presenter: @escaping () -> UIViewController?) -> Bool {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID),
              provider.supportsWatchlist else { return false }
        let ref = item.ref
        title?.text = "Watchlist"
        icon.image = UIImage(systemName: "bookmark")
        var onList = false
        var inFlight = true
        Task { @MainActor [weak pill, weak icon] in
            let current = await provider.isOnWatchlist(ref)
            guard pill != nil, MediaProviderRegistry.shared.provider(for: ref.providerID) != nil else { return }
            onList = current
            inFlight = false
            icon?.image = UIImage(systemName: current ? "bookmark.fill" : "bookmark")
        }
        pill.onPrimaryAction = { [weak pill, weak icon] in
            guard !inFlight, let current = MediaProviderRegistry.shared.provider(for: ref.providerID) else { return }
            inFlight = true
            let target = !onList
            Task { @MainActor in
                defer { inFlight = false }
                do {
                    if target { try await current.addToWatchlist(ref) }
                    else { try await current.removeFromWatchlist(ref) }
                    guard pill != nil, MediaProviderRegistry.shared.provider(for: ref.providerID) != nil else { return }
                    onList = target
                    icon?.image = UIImage(systemName: target ? "bookmark.fill" : "bookmark")
                    NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
                } catch {
                    guard pill != nil, MediaProviderRegistry.shared.provider(for: ref.providerID) != nil else { return }
                    presenter()?.present(ConfirmationPopupViewController(
                        title: "Couldn't Update Watchlist",
                        message: "The server did not confirm the change. Refresh the list before trying again.",
                        confirmTitle: "OK", cancelTitle: nil,
                        onConfirm: {}, onCancel: {}), animated: true)
                }
            }
        }
        return true
    }
}
