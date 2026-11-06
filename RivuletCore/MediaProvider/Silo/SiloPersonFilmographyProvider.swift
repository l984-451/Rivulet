// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Opaque native identity tied to a provider authority revision.
nonisolated enum SiloPersonContext {
    private static let prefix = "silo-person:"

    static func identity(_ personID: String, provider: SiloProvider) -> String {
        identity(personID, providerID: provider.id, authorityRevision: provider.authorityRevision)
    }

    static func identity(_ personID: String, providerID: String, authorityRevision: UInt64) -> String {
        let owner = Data(providerID.utf8).base64EncodedString()
        let person = Data(personID.utf8).base64EncodedString()
        return "\(prefix)\(owner):\(authorityRevision):\(person)"
    }

    static func personID(_ identity: String, provider: SiloProvider) -> String? {
        guard identity.hasPrefix(prefix) else { return nil }
        let parts = identity.dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let ownerData = Data(base64Encoded: String(parts[0])),
              String(data: ownerData, encoding: .utf8) == provider.id,
              UInt64(parts[1]) == provider.authorityRevision,
              let personData = Data(base64Encoded: String(parts[2])),
              let personID = String(data: personData, encoding: .utf8), !personID.isEmpty else { return nil }
        return personID
    }

    static func result(_ person: SiloPerson, provider: SiloProvider) -> MediaPersonResult {
        MediaPersonResult(person: MediaPerson(id: identity(person.id, provider: provider), name: person.name,
                                              role: nil, imageURL: SiloMediaMapper.url(person.photoUrl, baseURL: provider.client.baseURL)),
                          providerID: provider.id)
    }
}

/// Native filmography scoped to the acting profile's visible libraries.
nonisolated final class SiloPersonFilmographyProvider: PersonFilmographyProviding, Sendable {
    let provider: SiloProvider
    let libraryIDs: [String]

    init(provider: SiloProvider, libraryIDs: [String]) {
        self.provider = provider
        self.libraryIDs = libraryIDs
    }

    func load(person: MediaPerson) async throws -> PersonDetail {
        guard let personID = SiloPersonContext.personID(person.id, provider: provider) else {
            throw SiloPeopleError.staleAuthority
        }
        let people = SiloPeople(provider: provider)
        let visible = Set(try await provider.libraries().map(\.id))
        let scope = libraryIDs.isEmpty ? visible.sorted() : Array(Set(libraryIDs)).sorted()
        guard scope.allSatisfy(visible.contains) else { throw SiloPeopleError.invalidScope }
        let native = try await people.detail(personID: personID)
        var entries: [FilmographyEntry] = []
        var seen = Set<MediaItemRef>()
        for libraryID in scope {
            var cursor: String?
            var visited = Set<String>()
            repeat {
                try Task.checkCancellation()
                let page = try await people.credits(personID: personID, libraryID: libraryID, cursor: cursor)
                for dto in page.items where dto.type == "movie" || dto.type == "series" {
                    let item = SiloMediaMapper.item(dto, providerID: provider.id, baseURL: provider.client.baseURL, libraryID: libraryID)
                    if seen.insert(item.ref).inserted { entries.append(FilmographyEntry(item: item, isOnServer: true)) }
                }
                cursor = page.nextCursor
                if let cursor, !visited.insert(cursor).inserted { throw SiloPeopleError.invalidPage }
            } while cursor != nil
        }
        return PersonDetail(id: person.id, name: native.name, biography: native.bio,
                            portraitURL: SiloMediaMapper.url(native.photoUrl, baseURL: provider.client.baseURL) ?? person.imageURL,
                            movies: entries.filter { $0.item.kind == .movie },
                            shows: entries.filter { $0.item.kind == .show })
    }
}

extension SiloProvider {
    func searchPeople(_ query: String, inLibraries libraryIDs: [String]) async throws -> [MediaPersonResult] {
        let visible = Set(try await libraries().map(\.id))
        guard libraryIDs.allSatisfy(visible.contains) else { throw SiloPeopleError.invalidScope }
        let people = SiloPeople(provider: self)
        let scoped = libraryIDs.isEmpty ? visible.sorted() : Array(Set(libraryIDs)).sorted()
        var results: [MediaPersonResult] = []
        var seen = Set<String>()
        for libraryID in scoped {
            for person in try await people.search(query, libraryID: libraryID) where seen.insert(person.id).inserted {
                results.append(SiloPersonContext.result(person, provider: self))
            }
        }
        return results
    }

    func personDetail(_ person: MediaPersonResult, inLibraries libraryIDs: [String]) async throws -> PersonDetail {
        guard person.providerID == id else { throw SiloPeopleError.staleAuthority }
        return try await SiloPersonFilmographyProvider(provider: self, libraryIDs: libraryIDs).load(person: person.person)
    }

    func personFilmographyProvider(inLibraries libraryIDs: [String]) -> SiloPersonFilmographyProvider {
        SiloPersonFilmographyProvider(provider: self, libraryIDs: libraryIDs)
    }
}
