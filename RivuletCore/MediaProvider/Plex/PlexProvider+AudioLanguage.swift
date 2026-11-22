// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

extension PlexProvider {

    /// Movies and episodes: their audio streams, 50 per request. Shows: their On Deck episode,
    /// found six at a time, then read the same way.
    func audioLanguageAvailability(_ language: String, for items: [MediaItem]) async -> [MediaItemRef: Bool] {
        let network = networkManager, serverURL = serverURL, authToken = authToken
        var out: [MediaItemRef: Bool] = [:]
        // Rating key to read -> the items it answers for (a show's next episode answers for the show).
        var answersFor: [String: [MediaItemRef]] = [:]
        for item in items where item.kind != .show { answersFor[item.ref.itemID, default: []].append(item.ref) }

        let shows = items.filter { $0.kind == .show }
        await withTaskGroup(of: (MediaItemRef, String??).self) { group in
            var next = shows.makeIterator()
            func add() {
                guard let show = next.next() else { return }
                group.addTask {
                    // Not `try?`: it would flatten a failure into "none left".
                    do {
                        let key = try await network.getNextEpisodeKey(serverURL: serverURL, authToken: authToken,
                                                                      showRatingKey: show.ref.itemID)
                        return (show.ref, .some(key))
                    } catch {
                        return (show.ref, nil)
                    }
                }
            }
            for _ in 0..<6 { add() }
            while let (ref, key) = await group.next() {
                switch key {
                case .none: break                       // the request failed: unknown
                case .some(.none): out[ref] = true      // nothing left to watch
                case .some(.some(let episode)): answersFor[episode, default: []].append(ref)
                }
                add()
            }
        }

        let keys = Array(answersFor.keys)
        for start in stride(from: 0, to: keys.count, by: 50) {
            let chunk = Array(keys[start..<min(start + 50, keys.count)])
            guard let metas = try? await network.getStreams(serverURL: serverURL, authToken: authToken, ratingKeys: chunk)
            else { continue }
            for meta in metas {
                guard let key = meta.ratingKey, let has = Self.hasAudio(in: language, meta) else { continue }
                for ref in answersFor[key] ?? [] { out[ref] = has }
            }
        }
        return out
    }

    /// Nil when Plex lists no audio stream for the item.
    nonisolated static func hasAudio(in language: String, _ meta: PlexMetadata) -> Bool? {
        let audio = (meta.Media ?? []).flatMap { $0.Part ?? [] }.flatMap { $0.Stream ?? [] }.filter { $0.streamType == 2 }
        guard !audio.isEmpty else { return nil }
        return audio.contains { TrackLanguage.normalize($0.languageCode ?? $0.languageTag ?? $0.language) == language }
    }
}
