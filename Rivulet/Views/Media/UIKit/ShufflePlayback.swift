// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  Shuffle on tvOS (#543): a library's or a show's videos, played through the
//  playlist queue so Up Next walks it.

import UIKit

@MainActor
enum ShufflePlayback {
    /// True while a shuffle's titles load, so a second press starts nothing.
    private static var isLoading = false

    static func shuffle(_ library: MediaLibrary, unwatchedOnly: Bool = false, from presenter: UIViewController) {
        start(providerID: library.providerID, from: presenter) {
            try await $0.shuffleQueue(for: library, unwatchedOnly: unwatchedOnly)
        }
    }

    static func shuffle(show: MediaItem, from presenter: UIViewController) {
        let ref = show.ref
        start(providerID: ref.providerID, from: presenter) { try await $0.shuffleQueue(forShow: ref) }
    }

    /// A sidebar row's library when it is a video library on a signed-in server, else nil.
    static func library(for tab: SidebarTab) -> MediaLibrary? {
        let library: MediaLibrary?
        switch tab {
        case .library(let key):
            library = PlexDataStore.shared.libraries.first { $0.key == key }.flatMap { section in
                MediaProviderRegistry.shared.plexProvider.map { PlexMediaMapper.library(section, providerID: $0.id) }
            }
        case .providerLibrary(let providerID, let libraryID):
            library = ServerDataStore.shared.libraries.first { $0.providerID == providerID && $0.id == libraryID }
        default:
            library = nil
        }
        return library?.canShuffle == true ? library : nil
    }

    private static func start(providerID: String, from presenter: UIViewController,
                              queue: @escaping @Sendable (any MediaProvider) async throws -> PlayQueue<MediaItem>?) {
        guard !isLoading else { return }
        guard let provider = MediaProviderRegistry.shared.provider(for: providerID) else {
            ProviderPlayer.presentError(MediaProviderError.notFound, from: presenter)
            return
        }
        isLoading = true
        Task { [weak presenter] in
            defer { isLoading = false }
            do {
                // An empty library or show plays nothing, as an empty playlist does.
                guard let queue = try await queue(provider)?.playlistQueue, let presenter else { return }
                ProviderPlayer.play(queue.current.item, fromBeginning: false, playQueue: queue,
                                    from: presenter, onDismiss: nil)
            } catch {
                if let presenter { ProviderPlayer.presentError(error, from: presenter) }
            }
        }
    }
}
