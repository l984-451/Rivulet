// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// A cast or crew member: portrait, biography and their titles on the server, then Known For.
/// Parity source: tvOS `Person/UIKit`; the data comes from the shared `PersonFilmographyProvider`.
struct MacPersonView: View {
    let person: MediaPerson
    let providerID: String
    @EnvironmentObject private var browse: BrowseStore
    @State private var detail: PersonDetail?
    @State private var knownFor: [FilmographyEntry] = []
    @State private var failed = false
    @State private var bioExpanded = false

    private var elsewhere: [MediaItem] {
        guard let detail else { return [] }
        return FilmographyEntry.excluding(detail.movies + detail.shows, from: knownFor).map(\.item)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let detail {
                    if !detail.movies.isEmpty {
                        MacRail(title: String(localized: "Movies"), items: detail.movies.map(\.item)) { item, width in
                            MacTileButton(item: item) { MacPosterCard(item: item, width: width) }
                        }
                    }
                    if !detail.shows.isEmpty {
                        MacRail(title: String(localized: "TV Shows"), items: detail.shows.map(\.item)) { item, width in
                            MacTileButton(item: item) { MacPosterCard(item: item, width: width) }
                        }
                    }
                    if detail.movies.isEmpty, detail.shows.isEmpty {
                        Text("Nothing with \(person.name) on your servers.")
                            .foregroundStyle(.secondary).padding(.horizontal, MacMetrics.pageMargin)
                    }
                    if !elsewhere.isEmpty {
                        MacRail(title: String(localized: "Known For"), items: elsewhere,
                                badge: String(localized: "Not on your servers")) { item, width in
                            MacPosterCard(item: item, width: width).opacity(0.7)
                        }
                    }
                } else if failed {
                    MacErrorView(title: "Couldn't Load", message: String(localized: "Try again in a moment.")) { await load() }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.vertical, 24)
        }
        .navigationTitle(person.name)
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            MacImage(url: browse.imageURL(detail?.portraitURL ?? person.imageURL, providerID: providerID,
                                          width: 360, height: 360))
                .overlay {
                    if (detail?.portraitURL ?? person.imageURL) == nil {
                        Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 140, height: 140)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: person.name).font(.largeTitle.bold())
                if let bio = detail?.biography, !bio.isEmpty {
                    Text(verbatim: bio).lineLimit(bioExpanded ? nil : 5).frame(maxWidth: 720, alignment: .leading)
                    Button(bioExpanded ? "Less" : "More") { bioExpanded.toggle() }.buttonStyle(.link)
                }
            }
        }
        .padding(.horizontal, MacMetrics.pageMargin)
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
