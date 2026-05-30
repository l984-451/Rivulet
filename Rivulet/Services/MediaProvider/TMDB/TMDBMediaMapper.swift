//
//  TMDBMediaMapper.swift
//  Rivulet
//
//  TMDB DTO -> agnostic-type translations. Mirror of PlexMediaMapper for
//  the TMDB MetadataSource side.
//

import Foundation

enum TMDBMediaMapper {
    static let providerID = "tmdb"

    private static let backdropBase = "https://image.tmdb.org/t/p/original"
    private static let posterBase = "https://image.tmdb.org/t/p/w500"

    /// TMDB ids are not globally unique — id 100 can exist as a movie AND a TV
    /// show. `MediaItemRef.itemID` encodes both so callers that only have a ref
    /// can disambiguate without a second round-trip. Format: "{movie|tv}:{id}".
    /// Decoding tolerates bare numeric itemIDs for backward compatibility with
    /// anything persisted before this format landed.
    static func encodeItemID(tmdbId: Int, type: TMDBMediaType) -> String {
        "\(type.rawValue):\(tmdbId)"
    }

    static func decodeItemID(_ itemID: String) -> (tmdbId: Int, type: TMDBMediaType)? {
        let parts = itemID.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let type = TMDBMediaType(rawValue: parts[0]),
              let id = Int(parts[1]) else { return nil }
        return (id, type)
    }

    static func item(_ tmdb: TMDBListItem) -> MediaItem {
        // TMDBMediaType currently only has .movie / .tv (TMDBClient.swift).
        // If TMDB person results are ever supported, extend both that enum
        // and this mapping to cover .person.
        let kind: MediaKind = (tmdb.mediaType == .movie) ? .movie : .show
        let year: Int? = {
            guard let raw = tmdb.releaseDate?.prefix(4), !raw.isEmpty else { return nil }
            return Int(raw)
        }()
        let artwork = MediaArtwork(
            poster: tmdb.posterPath.flatMap { URL(string: "\(posterBase)\($0)") },
            backdrop: tmdb.backdropPath.flatMap { URL(string: "\(backdropBase)\($0)") },
            thumbnail: tmdb.posterPath.flatMap { URL(string: "\(posterBase)\($0)") },
            logo: nil
        )
        return MediaItem(
            ref: MediaItemRef(providerID: providerID, itemID: encodeItemID(tmdbId: tmdb.id, type: tmdb.mediaType)),
            kind: kind,
            title: tmdb.title,
            sortTitle: nil,
            overview: tmdb.overview,
            year: year,
            runtime: nil,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: artwork,
            parentArtwork: nil,
            grandparentArtwork: nil
        )
    }

    static func detail(_ tmdb: TMDBItemDetail) -> MediaItemDetail {
        let cast = tmdb.cast.map { credit in
            MediaPerson(
                id: "\(credit.id ?? 0)",
                name: credit.name ?? "",
                role: credit.character,
                imageURL: nil
            )
        }
        // Re-stub a TMDBListItem so we can reuse `item(_:)` for the embedded MediaItem.
        let stub = TMDBListItem(
            id: tmdb.id,
            title: tmdb.title,
            overview: tmdb.overview,
            posterPath: tmdb.posterPath,
            backdropPath: tmdb.backdropPath,
            releaseDate: tmdb.releaseDate,
            voteAverage: tmdb.voteAverage,
            mediaType: tmdb.mediaType
        )
        let runtime: TimeInterval? = tmdb.runtime.map { TimeInterval($0 * 60) }
        var embedded = item(stub)
        embedded = MediaItem(
            ref: embedded.ref,
            kind: embedded.kind,
            title: embedded.title,
            sortTitle: embedded.sortTitle,
            overview: embedded.overview,
            year: embedded.year,
            runtime: runtime,
            parentRef: embedded.parentRef,
            grandparentRef: embedded.grandparentRef,
            episodeNumber: embedded.episodeNumber,
            seasonNumber: embedded.seasonNumber,
            childProgress: embedded.childProgress,
            userState: embedded.userState,
            artwork: embedded.artwork,
            parentArtwork: embedded.parentArtwork,
            grandparentArtwork: embedded.grandparentArtwork
        )
        return MediaItemDetail(
            item: embedded,
            tagline: nil,
            genres: tmdb.genres.compactMap(\.name),
            studios: [],
            cast: cast,
            directors: [],
            writers: [],
            chapters: [],
            mediaSources: [],
            trailerURL: nil,
            contentRating: nil,
            rating: tmdb.voteAverage,
            nextEpisode: nil,
            collections: [],
            originallyAvailableAt: nil
        )
    }
}
