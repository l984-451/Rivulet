// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexUserProfileManager.swift
//  Rivulet
//
//  Manages Plex Home user profile selection and persistence
//

import Foundation
import Combine

/// Manages user profile selection for Plex Home accounts
@MainActor
class PlexUserProfileManager: ObservableObject {
    static let shared = PlexUserProfileManager()

    /// Set by the host. `onProfileChanged` fires when the user switches to a
    /// DIFFERENT profile and per-profile content must be dropped;
    /// `onInitialProfileSelected` fires once on launch to sync user-specific
    /// settings. They are separate because the launch case must not invalidate
    /// caches that were just populated.
    static var onProfileChanged: (@MainActor () async -> Void)?
    static var onInitialProfileSelected: (@MainActor () -> Void)?

    // MARK: - Published State

    /// All available users in the Plex Home
    @Published var homeUsers: [PlexHomeUser] = []

    /// Currently selected user profile
    @Published var selectedUser: PlexHomeUser?

    /// Loading state for user fetch
    @Published var isLoadingUsers = false

    /// Error message if user fetch fails
    @Published var usersError: String?

    /// Whether to show profile picker on app launch
    @Published var showProfilePickerOnLaunch: Bool {
        didSet {
            userDefaults.set(showProfilePickerOnLaunch, forKey: showProfilePickerOnLaunchKey)
        }
    }

    /// Set of user UUIDs that have remembered PINs (for UI updates)
    @Published var usersWithRememberedPins: Set<String> = []

    /// True while the launch-time "Who's Watching?" picker owns the screen.
    /// Only ever set on the profile-picker-on-launch path; lets the launch
    /// splash stand down so the picker isn't buried under it. Stays false for
    /// users who keep the picker off, so their launch path is unchanged.
    @Published var isPresentingLaunchPicker = false

    // MARK: - UserDefaults Keys

    private let userDefaults = UserDefaults.standard
    private let selectedUserIdKey = "selectedPlexUserId"
    private let selectedUserUUIDKey = "selectedPlexUserUUID"
    private let selectedUserNameKey = "selectedPlexUserName"
    private let showProfilePickerOnLaunchKey = "showPlexProfilePickerOnLaunch"

    // MARK: - Dependencies

    private let networkManager = PlexNetworkManager.shared

    // MARK: - Computed Properties

    /// The selected user's ID for API headers, or nil for default behavior
    var selectedUserId: Int? {
        selectedUser?.id
    }

    /// Whether the Plex Home has multiple profiles to choose from
    var hasMultipleProfiles: Bool {
        homeUsers.count > 1
    }

    /// Whether the current user is the admin/owner
    var isAdminUser: Bool {
        selectedUser?.admin ?? true
    }

    /// Whether profiles have been loaded
    var hasLoadedProfiles: Bool {
        !homeUsers.isEmpty
    }

    // MARK: - Initialization

    private init() {
        // Load saved preference for profile picker
        showProfilePickerOnLaunch = userDefaults.bool(forKey: showProfilePickerOnLaunchKey)

        // Load saved user info (will be validated when fetchHomeUsers is called)
    }

    // MARK: - Public Methods

    /// Fetch all users in the Plex Home
    /// Call this after authentication and on app launch
    func fetchHomeUsers() async {
        guard let authToken = PlexAuthManager.shared.authToken else {
            return
        }

        isLoadingUsers = true
        usersError = nil

        do {
            let users = try await networkManager.getHomeUsers(authToken: authToken)
            homeUsers = users

            // Update remembered PINs state for UI
            updateRememberedPinsState()

            // Restore previously selected user or default to admin
            await restoreOrSelectDefaultUser()

            isLoadingUsers = false
        } catch {
            print("👤 PlexUserProfileManager: Failed to fetch home users: \(error)")
            usersError = "Failed to load profiles"
            isLoadingUsers = false

            // If we can't fetch users, default to single-user mode (no profile switching)
            // The admin user's content will be shown via the main auth token
            homeUsers = []
            selectedUser = nil
        }
    }

    /// Select a user profile
    /// - Parameters:
    ///   - user: The user to switch to
    ///   - pin: Optional PIN if the user profile is protected
    /// - Returns: True if selection succeeded
    @discardableResult
    func selectUser(_ user: PlexHomeUser, pin: String? = nil) async -> Bool {

        // PIN required but not provided
        if user.requiresPin && (pin == nil || pin?.isEmpty == true) {
            return false
        }

        // Call switch endpoint to get user-specific plex.tv token
        guard let authToken = PlexAuthManager.shared.authToken else {
            print("👤 PlexUserProfileManager: No auth token available")
            return false
        }

        do {
            let userPlexToken = try await networkManager.switchToHomeUser(
                userUUID: user.uuid,
                pin: pin,
                authToken: authToken
            )

            guard let userPlexToken = userPlexToken else {
                print("👤 PlexUserProfileManager: Invalid PIN for \(user.displayName)")
                return false
            }

            // Now get the server-specific access token using the user's plex.tv token
            guard let serverURL = PlexAuthManager.shared.selectedServerURL else {
                print("👤 PlexUserProfileManager: No server URL available")
                return false
            }

            let serverAccessToken = await networkManager.getServerAccessToken(
                authToken: userPlexToken,
                serverURL: serverURL
            )

            guard let serverAccessToken = serverAccessToken else {
                print("👤 PlexUserProfileManager: Could not get server access token")
                return false
            }

            // Update the server token with the user's server-specific token
            PlexAuthManager.shared.updateServerToken(serverAccessToken)

            // Update selected user
            let previousUser = selectedUser
            selectedUser = user
            saveSelectedUser(user)

            // Notify whatever holds per-profile content and settings. Same
            // handoff as PlexAuthManager: this manager owns the profile, the
            // caches it invalidates are per platform.
            if let previousUser, previousUser.id != user.id {
                await Self.onProfileChanged?()
            } else if previousUser == nil {
                // Initial selection on app launch — sync user-specific settings
                Self.onInitialProfileSelected?()
            }

            return true
        } catch {
            print("👤 PlexUserProfileManager: ❌ Switch failed: \(error)")
            return false
        }
    }

    /// Reset profile state (call on sign out)
    func reset() {
        // Clear all remembered PINs before clearing homeUsers
        let userUUIDs = homeUsers.map { $0.uuid }
        KeychainHelper.deleteAllPins(forUserUUIDs: userUUIDs)

        homeUsers = []
        selectedUser = nil
        usersError = nil
        usersWithRememberedPins = []

        // Clear persisted selection
        userDefaults.removeObject(forKey: selectedUserIdKey)
        userDefaults.removeObject(forKey: selectedUserUUIDKey)
        userDefaults.removeObject(forKey: selectedUserNameKey)

    }

    // MARK: - Remember PIN Methods

    /// Check if a user has a remembered PIN
    func hasRememberedPin(for user: PlexHomeUser) -> Bool {
        KeychainHelper.hasSavedPin(forUserUUID: user.uuid)
    }

    /// Store a PIN for a user after successful validation
    func rememberPin(_ pin: String, for user: PlexHomeUser) {
        KeychainHelper.setPin(pin, forUserUUID: user.uuid)
        usersWithRememberedPins.insert(user.uuid)
    }

    /// Delete a stored PIN for a user
    func forgetPin(for user: PlexHomeUser) {
        KeychainHelper.deletePin(forUserUUID: user.uuid)
        usersWithRememberedPins.remove(user.uuid)
    }

    /// Attempt to select a user with their remembered PIN
    /// - Returns: A tuple of (success: Bool, pinWasInvalid: Bool)
    ///   - success: True if the user was successfully selected
    ///   - pinWasInvalid: True if the remembered PIN was invalid (cleared automatically)
    func selectUserWithRememberedPin(_ user: PlexHomeUser) async -> (success: Bool, pinWasInvalid: Bool) {
        guard let savedPin = KeychainHelper.getPin(forUserUUID: user.uuid) else {
            return (false, false)
        }

        let success = await selectUser(user, pin: savedPin)

        if success {
            return (true, false)
        } else {
            // PIN is no longer valid - clear it
            forgetPin(for: user)
            print("👤 PlexUserProfileManager: Remembered PIN invalid for \(user.displayName), cleared")
            return (false, true)
        }
    }

    /// Update the set of users with remembered PINs based on current homeUsers
    private func updateRememberedPinsState() {
        usersWithRememberedPins = Set(
            homeUsers
                .filter { KeychainHelper.hasSavedPin(forUserUUID: $0.uuid) }
                .map { $0.uuid }
        )
    }

    // MARK: - Private Methods

    /// Restore previously selected user or select the admin user
    private func restoreOrSelectDefaultUser() async {
        // Try to find previously selected user
        if let savedId = userDefaults.object(forKey: selectedUserIdKey) as? Int,
           let savedUser = homeUsers.first(where: { $0.id == savedId }) {

            // For non-protected users, switch to get their token
            if !savedUser.requiresPin {
                let success = await selectUser(savedUser, pin: nil)
                if success {
                    return
                }
            } else if hasRememberedPin(for: savedUser) {
                // Try remembered PIN for protected users
                let (success, pinWasInvalid) = await selectUserWithRememberedPin(savedUser)
                if success {
                    return
                } else if pinWasInvalid {
                    print("👤 PlexUserProfileManager: Remembered PIN was invalid for \(savedUser.displayName)")
                }
            }

            // For protected users without remembered PIN or if switch failed, just set locally
            // They'll need to re-enter PIN if they want their specific content
            selectedUser = savedUser
            return
        }

        // Default to admin user
        if let adminUser = homeUsers.first(where: { $0.admin }) {
            let success = await selectUser(adminUser, pin: nil)
            if !success {
                // Fallback: just set locally
                selectedUser = adminUser
                saveSelectedUser(adminUser)
            }
        } else if let firstUser = homeUsers.first, !firstUser.requiresPin {
            // Fallback to first non-protected user
            let success = await selectUser(firstUser, pin: nil)
            if !success {
                selectedUser = firstUser
                saveSelectedUser(firstUser)
            }
        }
    }

    /// Save selected user to UserDefaults
    private func saveSelectedUser(_ user: PlexHomeUser) {
        userDefaults.set(user.id, forKey: selectedUserIdKey)
        userDefaults.set(user.uuid, forKey: selectedUserUUIDKey)
        userDefaults.set(user.displayName, forKey: selectedUserNameKey)
    }
}
