//
//  CastMemberCard.swift
//  Rivulet
//
//  Cast and crew member cards for detail view — circular photo style
//

import SwiftUI

// MARK: - Person Card (Circle)

/// Card for cast/crew members with circular photo, name, and role beneath
struct PersonCard: View {
    let name: String
    let subtitle: String?
    let thumbURL: URL?
    let serverURL: String
    let authToken: String

    private let circleSize: CGFloat = 188

    var body: some View {
        VStack(spacing: 10) {
            personImage
                .frame(width: circleSize, height: circleSize)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )

            VStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)

                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .frame(width: circleSize + 20)
        }
    }

    // MARK: - Person Image

    private var personImage: some View {
        CachedAsyncImage(url: fullThumbURL) { phase in
            switch phase {
            case .empty:
                Circle()
                    .fill(Color(white: 0.15))
                    .overlay {
                        ProgressView()
                            .tint(.white.opacity(0.3))
                    }
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failure:
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.18), Color(white: 0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
    }

    private var fullThumbURL: URL? {
        guard let thumbPath = thumbURL?.absoluteString else { return nil }
        if thumbPath.hasPrefix("http") {
            return thumbURL
        }
        var urlString = "\(serverURL)\(thumbPath)"
        if !urlString.contains("X-Plex-Token") {
            urlString += urlString.contains("?") ? "&" : "?"
            urlString += "X-Plex-Token=\(authToken)"
        }
        return URL(string: urlString)
    }
}

// MARK: - Cast & Crew Row

/// Horizontal scrolling row of cast and crew members with circular photos.
/// Accepts agnostic `MediaPerson` values — imageURL is already a fully-qualified
/// URL built by the mapper, so no serverURL/authToken threading is needed.
struct CastCrewRow: View {
    let cast: [MediaPerson]
    let directors: [MediaPerson]

    // tvOS's focus engine doesn't enter a section if it can't find a
    // focus-tracked target — without `@FocusState`/`.focused`, the row
    // is unreachable by D-pad and the horizontal ScrollView can't be
    // scrolled. Mirror the working pattern from the detail-page
    // Related row (`MediaItemAgnosticRow`): @FocusState focusedID +
    // `.focused($focusedID, equals: id)` per button.
    @FocusState private var focusedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cast & Crew")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 48)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    // Directors first
                    ForEach(directors) { director in
                        let isFocused = focusedID == director.id
                        Button { } label: {
                            PersonCard(
                                name: director.name,
                                subtitle: "Director",
                                thumbURL: director.imageURL,
                                serverURL: "",
                                authToken: ""
                            )
                            .scaleEffect(isFocused ? 1.10 : 1.0)
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFocused)
                        }
                        .buttonStyle(CircleCardButtonStyle())
                        .focused($focusedID, equals: director.id)
                    }

                    // Cast members
                    ForEach(cast) { actor in
                        let isFocused = focusedID == actor.id
                        Button { } label: {
                            PersonCard(
                                name: actor.name,
                                subtitle: actor.role,
                                thumbURL: actor.imageURL,
                                serverURL: "",
                                authToken: ""
                            )
                            .scaleEffect(isFocused ? 1.10 : 1.0)
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFocused)
                        }
                        .buttonStyle(CircleCardButtonStyle())
                        .focused($focusedID, equals: actor.id)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

// MARK: - Circle Card Button Style

/// Subtle focus style for circular cast/crew cards
struct CircleCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
