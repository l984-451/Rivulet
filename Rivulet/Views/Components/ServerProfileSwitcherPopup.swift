// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  ServerProfileSwitcherPopup.swift
//  Rivulet
//
//  The sidebar profile panel for Jellyfin and Emby users (`ServerUserProfiles`), laid out as
//  `ProfileSwitcherPopup` lays out Plex Home users. Server users have no PIN: Rivulet keeps a
//  token for each one added in Settings.
//

import SwiftUI

#if os(tvOS)

struct ServerProfileSwitcherPopup: View {
    @Binding var isPresented: Bool
    /// Runs after a switch to another user, so the shell can go to Home.
    let onSwitched: () -> Void

    @State private var profiles = ServerUserProfiles.profiles
    @State private var switchingID: String?
    @FocusState private var focusedID: String?

    // `ProfileSwitcherPopup`'s measurements: the Apple TV app's profile panel.
    private let columns = [
        GridItem(.fixed(180), spacing: -4),
        GridItem(.fixed(180))
    ]

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(profiles) { profile in
                        profileButton(for: profile)
                            .focused($focusedID, equals: profile.id)
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 14, bottom: 34, trailing: 14))
            }
            .frame(width: 384)
            .frame(maxHeight: max(0, proxy.size.height - 70 - 40))
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(.rect(cornerRadius: 50))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 50))
            .padding(.top, 70)
        }
        .onAppear {
            focusedID = profiles.first(where: \.isActive)?.id ?? profiles.first?.id
        }
        .onExitCommand {
            isPresented = false
        }
    }

    private func profileButton(for profile: ServerUserProfiles.Profile) -> some View {
        let isFocused = focusedID == profile.id
        let isSwitching = switchingID == profile.id
        let avatarSize: CGFloat = 160

        return Button {
            select(profile)
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    avatar(for: profile)
                        .frame(width: avatarSize, height: avatarSize)
                        .clipShape(Circle())
                        .overlay(
                            Circle().strokeBorder(
                                isFocused ? Color.primary.opacity(0.8) : Color.primary.opacity(0.15),
                                lineWidth: isFocused ? 3 : 1
                            )
                        )
                    if isSwitching {
                        Circle().fill(.black.opacity(0.5)).frame(width: avatarSize, height: avatarSize)
                        ProgressView()
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if profile.isActive && !isSwitching {
                        Image(systemName: "checkmark.circle.fill")
                            .resizable()
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .frame(width: 36, height: 36)
                    }
                }
                .scaleEffect(isFocused ? 180 / avatarSize : 1.0)

                Text(verbatim: ShellSidebarModel.firstName(of: profile.name))
                    .font(Font(UIFont.preferredFont(forTextStyle: .caption2)).weight(isFocused ? .semibold : .regular))
                    .padding(.horizontal, 5)
                    .foregroundStyle(Color.primary.opacity(isFocused ? 1.0 : 0.7))
                    .lineLimit(1)
            }
        }
        .buttonStyle(ServerProfileButtonStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    @ViewBuilder
    private func avatar(for profile: ServerUserProfiles.Profile) -> some View {
        if let url = profile.imageURL {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                default: placeholder(for: profile)
                }
            }
        } else {
            placeholder(for: profile)
        }
    }

    private func placeholder(for profile: ServerUserProfiles.Profile) -> some View {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        let color = colors[profile.userID.unicodeScalars.reduce(0) { $0 + Int($1.value) } % colors.count]
        return ZStack {
            Circle().fill(color.gradient)
            Text(verbatim: profile.name.prefix(1).uppercased())
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private func select(_ profile: ServerUserProfiles.Profile) {
        guard switchingID == nil else { return }
        guard !profile.isActive else {
            isPresented = false
            return
        }
        switchingID = profile.id
        Task { @MainActor in
            let switched = await ServerUserProfiles.switchTo(profile)
            switchingID = nil
            if switched { onSwitched() }
            isPresented = false
        }
    }
}

private struct ServerProfileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

#endif
