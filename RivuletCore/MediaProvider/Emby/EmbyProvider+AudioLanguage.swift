// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

extension EmbyProvider {

    /// Movies and episodes: their audio tracks, 50 per request. Shows: their next unwatched episode
    /// (`Shows/NextUp`), six at a time.
    func audioLanguageAvailability(_ language: String, for items: [MediaItem]) async -> [MediaItemRef: Bool] {
        let user = URLQueryItem(name: "UserId", value: userID)
        let fields = URLQueryItem(name: "Fields", value: "MediaSources")
        @Sendable func answer(_ dto: EmbyItem) -> Bool? {
            let audio = (dto.mediaSources ?? []).flatMap { $0.mediaStreams ?? [] }.filter { $0.type == "Audio" }
            guard !audio.isEmpty else { return nil }
            return audio.contains { TrackLanguage.normalize($0.language) == language }
        }
        var out: [MediaItemRef: Bool] = [:]

        // Movies and episodes: one request per 50.
        let direct = items.filter { $0.kind != .show }
        for start in stride(from: 0, to: direct.count, by: 50) {
            let chunk = direct[start..<min(start + 50, direct.count)]
            let ids = URLQueryItem(name: "Ids", value: chunk.map(\.ref.itemID).joined(separator: ","))
            guard let result: EmbyQueryResult = try? await client.get(itemsPath, [ids, fields]) else { continue }
            for dto in result.items ?? [] {
                guard let item = chunk.first(where: { $0.ref.itemID == dto.id.value }), let has = answer(dto) else { continue }
                out[item.ref] = has
            }
        }

        // Shows: their next unwatched episode, six at a time.
        let shows = items.filter { $0.kind == .show }
        let client = client
        await withTaskGroup(of: (MediaItemRef, Bool?).self) { group in
            var next = shows.makeIterator()
            func add() {
                guard let show = next.next() else { return }
                group.addTask {
                    let series = URLQueryItem(name: "SeriesId", value: show.ref.itemID)
                    let limit = URLQueryItem(name: "Limit", value: "1")
                    guard let result: EmbyQueryResult = try? await client.get("Shows/NextUp", [user, series, limit, fields])
                    else { return (show.ref, nil) }
                    guard let episode = result.items?.first else { return (show.ref, true) }
                    return (show.ref, answer(episode))
                }
            }
            for _ in 0..<6 { add() }
            while let (ref, has) = await group.next() {
                if let has { out[ref] = has }
                add()
            }
        }
        return out
    }
}
