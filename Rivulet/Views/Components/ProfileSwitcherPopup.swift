// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProfileSwitcherPopup.swift
//  Rivulet
//
//  Compact profile switcher popup for the sidebar account tab
//

import SwiftUI

#if os(tvOS)

struct ProfileSwitcherPopup: View {
    @Binding var isPresented: Bool
    @ObservedObject var profileManager: PlexUserProfileManager

    @State private var selectedUserForPin: PlexHomeUser?
    @State private var showPinEntry = false
    @State private var pinEntryError: String?
    @State private var isLoading = false
    @FocusState private var focusedUserId: Int?

    // The Apple TV app's profile panel: 384 wide, insets 14 / 14 / 34,
    // two columns that overlap 4pt, rows 10 apart, 160pt avatars growing to 180.
    private let columns = [
        GridItem(.fixed(180), spacing: -4),
        GridItem(.fixed(180))
    ]

    var body: some View {
        GeometryReader { proxy in
            // Popup card — positioned top-left directly below sidebar pill. It hugs
            // its rows and scrolls past the screen: Plex Home allows 15 profiles.
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(profileManager.homeUsers) { user in
                        profileButton(for: user)
                            .focused($focusedUserId, equals: user.id)
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
            focusedUserId = profileManager.selectedUser?.id ?? profileManager.homeUsers.first?.id
        }
        .onExitCommand {
            isPresented = false
        }
        // Close as soon as the profile is entered: by the time this runs its token
        // is installed and the old content dropped, so Home loads in view.
        // A PIN sheet closes first and its onDismiss closes the panel.
        .onChange(of: profileManager.selectedUser?.id) { _, _ in
            guard didEnterRequestedProfile else { return }
            if showPinEntry { showPinEntry = false } else { isPresented = false }
        }
        .sheet(isPresented: $showPinEntry, onDismiss: { if didEnterRequestedProfile { isPresented = false } }) {
            if let user = selectedUserForPin {
                PinEntrySheet(
                    user: user,
                    error: $pinEntryError,
                    onSubmit: { pin, rememberPin in
                        Task {
                            await verifyAndSwitch(user: user, pin: pin, rememberPin: rememberPin)
                        }
                    },
                    onCancel: {
                        showPinEntry = false
                        selectedUserForPin = nil
                        pinEntryError = nil
                    }
                )
            }
        }
    }

    private var didEnterRequestedProfile: Bool {
        selectedUserForPin != nil && selectedUserForPin?.id == profileManager.selectedUser?.id
    }

    private func profileButton(for user: PlexHomeUser) -> some View {
        let isCurrent = profileManager.selectedUser?.id == user.id
        let isFocused = focusedUserId == user.id
        let isLoadingThis = isLoading && selectedUserForPin?.id == user.id

        let firstName = ShellSidebarModel.firstName(of: user.displayName)
        let avatarSize: CGFloat = 160

        return Button {
            selectProfile(user)
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    avatarView(for: user)
                        .frame(width: avatarSize, height: avatarSize)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    isFocused ? Color.primary.opacity(0.8) : Color.primary.opacity(0.15),
                                    lineWidth: isFocused ? 3 : 1
                                )
                        )

                    if isLoadingThis {
                        Circle()
                            .fill(.black.opacity(0.5))
                            .frame(width: avatarSize, height: avatarSize)
                        ProgressView()
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isCurrent && !isLoadingThis {
                        // 36pt badge, the TV app's size.
                        Image(systemName: "checkmark.circle.fill")
                            .resizable()
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .frame(width: 36, height: 36)
                    } else if user.protected && !isCurrent && !isLoadingThis {
                        Image(systemName: profileManager.usersWithRememberedPins.contains(user.uuid)
                              ? "lock.open.fill" : "lock.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(profileManager.usersWithRememberedPins.contains(user.uuid)
                                             ? .green : .white)
                            .padding(6)
                            .background(Circle().fill(.black.opacity(0.6)))
                            .offset(x: 4, y: -4)
                    }
                }
                // Only the avatar grows on focus; the name stays put.
                .scaleEffect(isFocused ? 180 / avatarSize : 1.0)

                Text(firstName)
                    .font(Font(UIFont.preferredFont(forTextStyle: .caption2)).weight(isFocused ? .semibold : .regular))
                    .padding(.horizontal, 5)
                    .foregroundStyle(Color.primary.opacity(isFocused ? 1.0 : 0.7))
                    .lineLimit(1)
            }
        }
        .buttonStyle(ProfileSwitcherButtonStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    @ViewBuilder
    private func avatarView(for user: PlexHomeUser) -> some View {
        if let thumbURL = user.thumb, let url = URL(string: thumbURL) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .empty:
                    avatarPlaceholder(for: user)
                case .failure:
                    avatarPlaceholder(for: user)
                @unknown default:
                    avatarPlaceholder(for: user)
                }
            }
        } else {
            avatarPlaceholder(for: user)
        }
    }

    private func avatarPlaceholder(for user: PlexHomeUser) -> some View {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        let color = colors[abs(user.id) % colors.count]
        return ZStack {
            Circle().fill(color.gradient)
            Text(user.displayName.prefix(1).uppercased())
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Profile Selection

    private func selectProfile(_ user: PlexHomeUser) {
        // Already selected
        if profileManager.selectedUser?.id == user.id {
            isPresented = false
            return
        }

        if user.requiresPin {
            if profileManager.hasRememberedPin(for: user) {
                Task {
                    isLoading = true
                    selectedUserForPin = user
                    let (success, pinWasInvalid) = await profileManager.selectUserWithRememberedPin(user)
                    if success {
                        isLoading = false
                        selectedUserForPin = nil
                        isPresented = false
                    } else {
                        isLoading = false
                        pinEntryError = pinWasInvalid ? String(localized: "Saved PIN is no longer valid. Please enter your PIN.") : nil
                        showPinEntry = true
                    }
                }
            } else {
                selectedUserForPin = user
                pinEntryError = nil
                showPinEntry = true
            }
        } else {
            Task {
                isLoading = true
                selectedUserForPin = user
                // Usually closed already by the selectedUser change above; this is the fallback.
                let success = await profileManager.selectUser(user, pin: nil)
                isLoading = false
                selectedUserForPin = nil
                if success { isPresented = false }
            }
        }
    }

    private func verifyAndSwitch(user: PlexHomeUser, pin: String, rememberPin: Bool) async {
        isLoading = true
        pinEntryError = nil

        let success = await profileManager.selectUser(user, pin: pin)

        if success {
            if rememberPin {
                profileManager.rememberPin(pin, for: user)
                // The switch's Home fetch ran before the PIN was saved, and cleared Top Shelf.
                Task { await TopShelfFeed.refresh() }
            }
            showPinEntry = false
            selectedUserForPin = nil
            isPresented = false
        } else {
            pinEntryError = String(localized: "Incorrect PIN. Please try again.")
        }

        isLoading = false
    }
}

// MARK: - Button Style

private struct ProfileSwitcherButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

#endif
