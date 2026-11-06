// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProfilePickerOverlay.swift
//  Rivulet
//
//  Full-screen profile picker shown on app launch (optional)
//

import SwiftUI

/// Full-screen overlay for selecting a Plex Home user profile on app launch
struct ProfilePickerOverlay: View {
    @StateObject private var profileManager = PlexUserProfileManager.shared
    @Binding var isPresented: Bool
    /// Called when a profile was entered, just before the picker closes.
    var onSelected: () -> Void = {}

    @State private var selectedUserForPin: PlexHomeUser?
    @State private var showPinEntry = false
    @State private var pinEntryError: String?
    @State private var isLoading = false
    @FocusState private var focusedUserId: Int?

    var body: some View {
        ZStack {
            // Background
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()

            GeometryReader { proxy in
                VStack(spacing: 50) {
                    // Header
                    VStack(spacing: 12) {
                        Text("Who's Watching?")
                            .font(.system(size: 64, weight: .bold))
                            .foregroundStyle(Color.primary)
    
                        Text("Select a profile to continue")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.primary.opacity(0.6))
                    }
                    .padding(.top, 80)
    
                    Spacer()
    
                    // Profile grid. Hugs its rows and scrolls once they pass the header's room.
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: 40) {
                            ForEach(profileManager.homeUsers) { user in
                                ProfileAvatarButton(
                                    user: user,
                                    isLoading: isLoading && selectedUserForPin?.id == user.id,
                                    isFocused: focusedUserId == user.id,
                                    hasRememberedPin: profileManager.usersWithRememberedPins.contains(user.uuid)
                                ) {
                                    selectProfile(user)
                                }
                                .focused($focusedUserId, equals: user.id)
                            }
                        }
                        .padding(.horizontal, 120)
                        // Room for the focus grow inside the scroll view's clip.
                        .padding(.vertical, 20)
                    }
                    .frame(maxHeight: max(0, proxy.size.height - 320))
                    .fixedSize(horizontal: false, vertical: true)
    
                    // The profile list did not load (plex.tv unreachable): nothing to pick yet.
                    if profileManager.homeUsers.isEmpty {
                        Button("Try Again") {
                            Task { await profileManager.fetchHomeUsers() }
                        }
                        .disabled(profileManager.isLoadingUsers)
                    }
    
                    Spacer()
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .sheet(isPresented: $showPinEntry) {
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
        // The picker is a gate (launch setting, or content withheld): Menu must
        // not close it. Swallowing the exit command also keeps tvOS from
        // dismissing the cover. The PIN sheet handles its own Menu.
        .onExitCommand {}
        .onAppear {
            // Focus first profile
            if let first = profileManager.homeUsers.first {
                focusedUserId = first.id
            }
        }
    }

    private var gridColumns: [GridItem] {
        // Responsive columns based on number of users
        let count = profileManager.homeUsers.count
        let columnCount = min(count, 5)
        return Array(repeating: GridItem(.flexible(), spacing: 40), count: columnCount)
    }

    private func selectProfile(_ user: PlexHomeUser) {
        if user.requiresPin {
            // Try remembered PIN first
            if profileManager.hasRememberedPin(for: user) {
                Task {
                    isLoading = true
                    selectedUserForPin = user
                    let (success, pinWasInvalid) = await profileManager.selectUserWithRememberedPin(user)
                    if success {
                        isLoading = false
                        selectedUserForPin = nil
                        finish()
                    } else {
                        isLoading = false
                        // Show PIN entry with error if PIN was invalid
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
                let success = await profileManager.selectUser(user, pin: nil)
                isLoading = false
                selectedUserForPin = nil
                if success {
                    finish()
                }
            }
        }
    }

    private func finish() {
        onSelected()
        isPresented = false
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
            finish()
        } else {
            pinEntryError = String(localized: "Incorrect PIN. Please try again.")
        }

        isLoading = false
    }
}

// MARK: - Profile Avatar Button

private struct ProfileAvatarButton: View {
    let user: PlexHomeUser
    let isLoading: Bool
    let isFocused: Bool
    let hasRememberedPin: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 16) {
                // Avatar
                ZStack {
                    avatarView
                        .frame(width: 160, height: 160)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    isFocused ? Color.primary.opacity(0.8) : Color.primary.opacity(0.15),
                                    lineWidth: isFocused ? 3 : 1
                                )
                        )

                    if isLoading {
                        Circle()
                            .fill(.black.opacity(0.5))
                            .frame(width: 160, height: 160)

                        ProgressView()
                            .scaleEffect(1.5)
                    }

                    // PIN indicator
                    if user.protected && !isLoading {
                        Image(systemName: hasRememberedPin ? "lock.open.fill" : "lock.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(hasRememberedPin ? .green : .white)
                            .padding(8)
                            .background(Circle().fill(.black.opacity(0.6)))
                            .offset(x: 60, y: 60)
                    }
                }

                // Name
                Text(user.displayName)
                    .font(.system(size: 26, weight: isFocused ? .semibold : .regular))
                    .foregroundStyle(Color.primary.opacity(isFocused ? 1.0 : 0.7))
                    .lineLimit(1)
            }
        }
        .buttonStyle(NoFocusEffectButtonStyle())
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    @ViewBuilder
    private var avatarView: some View {
        if let thumbURL = user.thumb, let url = URL(string: thumbURL) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .empty:
                    avatarPlaceholder
                case .failure:
                    avatarPlaceholder
                @unknown default:
                    avatarPlaceholder
                }
            }
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Circle()
                .fill(profileColor.gradient)

            Text(user.displayName.prefix(1).uppercased())
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var profileColor: Color {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        return colors[abs(user.id) % colors.count]
    }
}

#Preview {
    ProfilePickerOverlay(isPresented: .constant(true))
}
