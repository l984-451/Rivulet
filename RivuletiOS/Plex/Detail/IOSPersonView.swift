// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// A cast or crew member: portrait, biography and their titles on the server, then Known For.
/// The data comes from the shared `PersonFilmographyProvider`; port of `MacPersonView`.
struct IOSPersonView: View {
    let person: MediaPerson
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.displayScale) private var displayScale
    @State private var detail: PersonDetail?
    @State private var knownFor: [FilmographyEntry] = []
    @State private var failed = false
    @State private var bioExpanded = false

    private var providerID: String { person.providerID ?? "" }

    private var elsewhere: [MediaItem] {
        guard let detail else { return [] }
        return FilmographyEntry.excluding(detail.movies + detail.shows, from: knownFor).map(\.item)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let detail {
                    if !detail.movies.isEmpty {
                        IOSPlexRail(title: String(localized: "Movies"), kind: .poster, items: detail.movies.map(\.item)) {
                            IOSPlexPosterCard(item: $0, width: $1)
                        }
                    }
                    if !detail.shows.isEmpty {
                        IOSPlexRail(title: String(localized: "TV Shows"), kind: .poster, items: detail.shows.map(\.item)) {
                            IOSPlexPosterCard(item: $0, width: $1)
                        }
                    }
                    if detail.movies.isEmpty, detail.shows.isEmpty {
                        Text("Nothing with \(person.name) on your servers.")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    if !elsewhere.isEmpty {
                        IOSShelfRow(kind: .poster, items: elsewhere) {
                            IOSPlexShelfHeader(title: String(localized: "Known For"), badge: String(localized: "Not on your servers"))
                        } tile: { item, width in
                            IOSPlexPosterCard(item: item, width: width).opacity(0.7)
                        }
                    }
                } else if failed {
                    ContentUnavailableView {
                        Label("Couldn’t Load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Try again in a moment.")
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        let portrait = detail?.portraitURL ?? person.imageURL
        let pixels = Int((120 * displayScale).rounded(.up))
        return VStack(spacing: 12) {
            IOSPlexImage(url: browse.imageURL(portrait, providerID: providerID, width: pixels, height: pixels))
                .overlay {
                    if portrait == nil {
                        Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(Circle())
            Text(verbatim: person.name).font(.title.bold()).multilineTextAlignment(.center)
            if let bio = detail?.biography, !bio.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: bio).font(.subheadline).lineLimit(bioExpanded ? nil : 5)
                    Button(bioExpanded ? "Less" : "More") { bioExpanded.toggle() }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
    }

    private func load() async {
        failed = false
        let provider = PersonFilmographyProvider()
        do {
            detail = try await provider.load(person: person)
        } catch {
            failed = true
            return
        }
        knownFor = await provider.knownFor(person: person)
    }
}
