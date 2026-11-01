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
    /// Set by the host: the entered profile's plex.tv token, which reaches its
    /// other servers (tvOS `PlexExtraServers`). Not stored.
    static var onProfileEntered: (@MainActor (_ plexToken: String) -> Void)?

    // MARK: - Published State

    /// All available users in the Plex Home
    @Published var homeUsers: [PlexHomeUser] = []

    /// Currently selected user profile
    @Published var selectedUser: PlexHomeUser? {
        // Kept across launches: the home-user list loads seconds after launch, or not at all offline.
        didSet { if let selectedUser { userDefaults.set(selectedUser.restricted, forKey: restrictedKey) } }
    }

    /// A managed (restricted) Plex profile. It sees Plex content only: other
    /// servers, IPTV, sign-out, server and parental settings are the owner's.
    var isRestrictedProfile: Bool {
        selectedUser?.restricted ?? userDefaults.bool(forKey: restrictedKey)
    }

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

    /// True while content is withheld because the saved profile could not be
    /// entered. The host shows the profile picker; entering any profile clears it.
    @Published private(set) var needsProfileSelection = false

    // MARK: - UserDefaults Keys

    private let userDefaults = UserDefaults.standard
    private let selectedUserIdKey = PlexProfileSession.savedUserIDKey
    private let selectedUserUUIDKey = "selectedPlexUserUUID"
    private let selectedUserNameKey = "selectedPlexUserName"
    private let showProfilePickerOnLaunchKey = "showPlexProfilePickerOnLaunch"
    private let restrictedKey = "selectedPlexUserRestricted"

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
            // Restoring needs to know which user is the account itself.
            async let accountID: Void = PlexAuthManager.shared.loadAccountUserIDIfNeeded()
            let users = try await networkManager.getHomeUsers(authToken: authToken)
            await accountID
            homeUsers = users

            // Update remembered PINs state for UI
            updateRememberedPinsState()

            // Restore previously selected user or default to admin
            await restoreOrSelectDefaultUser()
            DiagLog.notice(.profile, "Home users: \(homeUsers.count), selected: \(selectedUser.map { "admin=\($0.admin) managed=\($0.isManagedUser) pin=\($0.requiresPin)" } ?? "none"), picker=\(needsProfileSelection)")

            isLoadingUsers = false
        } catch {
            DiagLog.error(.profile, "Home users fetch failed: \(DiagLog.describe(error))")
            usersError = "Failed to load profiles"
            isLoadingUsers = false

            // Without the list there is no profile switching. Content keeps the
            // token it already has: a profile's own, or none.
            homeUsers = []
            selectedUser = nil
        }
        // Nothing learned about a saved profile this build never resolved: it runs
        // as it did before the update instead of stranding an owner who is offline.
        if homeUsers.isEmpty, PlexAuthManager.shared.useAccountTokenWhileUnresolved() {
            LiveTVDataStore.shared.plexContentTokenChanged()
            Self.onInitialProfileSelected?()
        }
        // Still locked (PIN needed, profile gone, plex.tv unreachable): the host asks.
        if PlexAuthManager.shared.isContentWithheld {
            needsProfileSelection = true
        }
    }

    /// Enters the saved profile again, after a server change dropped its token.
    func reapplySelectedProfile() async {
        if hasLoadedProfiles {
            await restoreOrSelectDefaultUser()
        } else {
            await fetchHomeUsers()
        }
    }

    /// How an attempt to enter a profile through plex.tv ended.
    nonisolated enum Entry: Equatable {
        case entered
        /// plex.tv refused: the PIN is wrong, missing, or newly required.
        case rejected
        /// No answer, or no token for this server: nothing was learned.
        case unavailable
    }

    /// Select a user profile
    /// - Parameters:
    ///   - user: The user to switch to
    ///   - pin: Optional PIN if the user profile is protected
    /// - Returns: True if selection succeeded
    @discardableResult
    func selectUser(_ user: PlexHomeUser, pin: String? = nil) async -> Bool {
        await enter(user, pin: pin) == .entered
    }

    private func enter(_ user: PlexHomeUser, pin: String?) async -> Entry {
        // PIN required but not provided
        if user.requiresPin && (pin == nil || pin?.isEmpty == true) {
            return .rejected
        }

        guard let authToken = PlexAuthManager.shared.authToken,
              let serverURL = PlexAuthManager.shared.selectedServerURL else {
            return .unavailable
        }

        do {
            // Call switch endpoint to get user-specific plex.tv token
            guard let userPlexToken = try await networkManager.switchToHomeUser(
                userUUID: user.uuid,
                pin: pin,
                authToken: authToken
            ) else {
                DiagLog.notice(.profile, "PIN rejected by plex.tv")
                return .rejected
            }

            // Now get the server-specific access token using the user's plex.tv token
            guard let serverAccessToken = await networkManager.getServerAccessToken(
                authToken: userPlexToken,
                serverURL: serverURL,
                serverName: PlexAuthManager.shared.savedServerName
            ) else {
                DiagLog.error(.profile, "Profile entry: no server access token")
                return .unavailable
            }

            let wasWithheld = PlexAuthManager.shared.isContentWithheld
            let contentOwnerChanged = PlexAuthManager.shared.enterProfile(
                user, serverToken: serverAccessToken, usedPin: pin != nil)

            // Update selected user
            let previousUser = selectedUser
            selectedUser = user
            saveSelectedUser(user)
            needsProfileSelection = false

            // Notify whatever holds per-profile content and settings. Same
            // handoff as PlexAuthManager: this manager owns the profile, the
            // caches it invalidates are per platform. "Changed" is judged
            // against the user the loaded and cached content belongs to, so it
            // also covers a launch that started on someone else's.
            if contentOwnerChanged {
                await contentOwnerDidChange()
            } else {
                if wasWithheld {
                    LiveTVDataStore.shared.plexContentTokenChanged()
                }
                if previousUser == nil {
                    // Initial selection on app launch: sync user-specific settings
                    Self.onInitialProfileSelected?()
                }
            }
            Self.onProfileEntered?(userPlexToken)
            DiagLog.notice(.profile, "Profile entered: admin=\(user.admin) managed=\(user.isManagedUser) pin=\(pin != nil) owner_changed=\(contentOwnerChanged)")

            return .entered
        } catch {
            DiagLog.error(.profile, "Profile switch failed: \(DiagLog.describe(error))")
            return .unavailable
        }
    }

    /// Account-level content and Live TV belong to the previous user too.
    private func contentOwnerDidChange() async {
        PlexWatchlistService.shared.reset()
        Task { await PlexWatchlistService.shared.fetchWatchlist(force: true) }
        await Self.onProfileChanged?()
        LiveTVDataStore.shared.plexContentTokenChanged()
    }

    /// Withholds content until a profile is entered. The saved profile stays
    /// saved, so a relaunch is locked too.
    private func lock() async {
        let hadContent = PlexAuthManager.shared.selectedServerToken != nil
        PlexAuthManager.shared.withholdContent()
        selectedUser = nil
        needsProfileSelection = true
        if hadContent {
            await contentOwnerDidChange()
        }
    }

    /// Reset profile state (call on sign out)
    func reset() {
        // homeUsers can be empty (failed or deferred fetch), so clear by prefix.
        KeychainHelper.deleteAllPins()

        homeUsers = []
        selectedUser = nil
        userDefaults.removeObject(forKey: restrictedKey)
        usersError = nil
        usersWithRememberedPins = []

        needsProfileSelection = false

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
        let entry = await enterWithRememberedPin(user)
        return (entry == .entered, entry == .rejected)
    }

    /// Forgets the PIN only when plex.tv refused it, never on a failed request.
    private func enterWithRememberedPin(_ user: PlexHomeUser) async -> Entry {
        guard let savedPin = KeychainHelper.getPin(forUserUUID: user.uuid) else {
            return .unavailable
        }
        let entry = await enter(user, pin: savedPin)
        if entry == .rejected {
            forgetPin(for: user)
            DiagLog.notice(.profile, "Remembered PIN rejected, cleared")
        }
        return entry
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

    /// What a restore does once plex.tv has answered for the saved profile.
    nonisolated enum RestoreAction: Equatable {
        case none, keep, useAccount, lock
    }

    /// The account's own profile falls back to the account's token as before.
    /// Any other profile keeps a session of its own or is locked.
    nonisolated static func restoreAction(after entry: Entry, isAccount: Bool, ownTokenInUse: Bool) -> RestoreAction {
        if entry == .entered { return .none }
        if isAccount { return .useAccount }
        return entry == .unavailable && ownTokenInUse ? .keep : .lock
    }

    /// Restore previously selected user or select the admin user
    private func restoreOrSelectDefaultUser() async {
        // No users is a failed fetch (every account has itself): nothing was learned.
        guard !homeUsers.isEmpty else { return }

        if let savedId = userDefaults.object(forKey: selectedUserIdKey) as? Int {
            guard let savedUser = homeUsers.first(where: { $0.id == savedId }) else {
                // The saved profile left the Home.
                await lock()
                return
            }

            let entry: Entry
            if !savedUser.requiresPin {
                entry = await enter(savedUser, pin: nil)
            } else if hasRememberedPin(for: savedUser) {
                entry = await enterWithRememberedPin(savedUser)
            } else {
                entry = .rejected
            }

            switch Self.restoreAction(after: entry, isAccount: PlexAuthManager.shared.isAccount(savedUser),
                                      ownTokenInUse: PlexAuthManager.shared.isUsingToken(of: savedUser)) {
            case .none:
                break
            case .keep:
                selectedUser = savedUser
            case .useAccount:
                let wasWithheld = PlexAuthManager.shared.isContentWithheld
                selectedUser = savedUser
                needsProfileSelection = false
                if PlexAuthManager.shared.useAccountServerToken(for: savedUser) {
                    await contentOwnerDidChange()
                } else if wasWithheld {
                    LiveTVDataStore.shared.plexContentTokenChanged()
                    // The token arrived without an entry: the host loads under it.
                    Self.onInitialProfileSelected?()
                }
            case .lock:
                await lock()
            }
            return
        }

        // Default to the signed-in account's own profile
        if let accountUser = homeUsers.first(where: PlexAuthManager.shared.isAccount) {
            let success = await selectUser(accountUser, pin: nil)
            if !success {
                // It is the account (at sign-in no server is chosen yet): its
                // token needs no entry, and the record keeps the launch rule on it.
                selectedUser = accountUser
                saveSelectedUser(accountUser)
                _ = PlexAuthManager.shared.useAccountServerToken(for: accountUser)
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
