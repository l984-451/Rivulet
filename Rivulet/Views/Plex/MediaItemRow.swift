//
//  MediaItemRow.swift
//  Rivulet
//
//  Reusable horizontal scroll row for displaying media items (collections, recommendations)
//

import SwiftUI

/// Horizontal scrolling row of media items with poster cards
struct MediaItemRow: View {
    let title: String
    let items: [PlexMetadata]
    let serverURL: String
    let authToken: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 48)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(items, id: \.ratingKey) { item in
                        NavigationLink(value: item) {
                            MediaPosterCard(
                                item: item,
                                serverURL: serverURL,
                                authToken: authToken
                            )
                        }
                        #if os(tvOS)
                        .buttonStyle(CardButtonStyle())
                        #else
                        .buttonStyle(.plain)
                        #endif
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 32)  // Room for shadow/focus overflow
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        MediaItemRow(
            title: "Collection Title",
            items: [],
            serverURL: "",
            authToken: ""
        )
    }
}
