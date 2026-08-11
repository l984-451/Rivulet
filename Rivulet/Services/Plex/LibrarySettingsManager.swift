// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibrarySettingsManager.swift
//  Rivulet
//
//  Manages library visibility and ordering preferences
//

import Foundation
import Combine

/// Manages user preferences for library visibility and ordering in the sidebar
/// Settings are stored per-user for Plex Home accounts
@MainActor
class LibrarySettingsManager: ObservableObject {
    static let shared = LibrarySettingsManager()

    // MARK: - Published State

    /// Library keys that are hidden from the sidebar
    @Published var hiddenLibraryKeys: Set<String> {
        didSet {
            saveHiddenLibraries()
        }
    }

    /// Ordered list of library keys (libraries not in this list appear at the end in default order)
    @Published var libraryOrder: [String] {
        didSet {
            saveLibraryOrder()
        }
    }

    /// Library keys that should appear on the Home screen (separate from sidebar visibility)
    /// Empty set means "not yet configured" - all visible libraries will be shown by default
    @Published var librariesShownOnHome: Set<String> {
        didSet {
            saveHomeLibraries()
        }
    }

    /// Track whether Home visibility has been explicitly configured
    @Published private(set) var homeVisibilityConfigured: Bool {
        didSet {
            userDefaults.set(homeVisibilityConfigured, forKey: currentKey(homeVisibilityConfiguredBaseKey))
        }
    }

    /// Per-library sort options (libraryKey -> sort option)
    @Published var librarySortOptions: [String: LibrarySortOption] = [:] {
        didSet {
            saveSortOptions()
        }
    }

    // MARK: - UserDefaults Keys (base keys - user ID is appended)

    private let userDefaults = UserDefaults.standard
    private let hiddenLibrariesBaseKey = "hiddenLibraryKeys"
    private let libraryOrderBaseKey = "libraryOrder"
    private let homeLibrariesBaseKey = "librariesShownOnHome"
    private let homeVisibilityConfiguredBaseKey = "homeVisibilityConfigured"
    private let sortOptionsBaseKey = "librarySortOptions"

    /// Current user ID for per-user settings (nil = default/no profile)
    private var currentUserId: Int?

    /// UserDefaults key under which `PlexUserProfileManager` persists the
    /// last-selected Plex Home profile id (`selectedUserIdKey` there).
    /// Read-only mirror — keep in sync with that owner of the key.
    private let persistedSelectedUserIdKey = "selectedPlexUserId"

    // MARK: - Initialization

    private init() {
        // Initialize with empty values - will be loaded when user is set
        self.hiddenLibraryKeys = []
        self.libraryOrder = []
        self.librariesShownOnHome = []
        self.homeVisibilityConfigured = false
        self.librarySortOptions = [:]

        // PRIVACY: this singleton initializes before the Plex profile
        // resolves. If we loaded the BASE keys here, a Plex Home /
        // multi-profile account (whose real hidden set lives under
        // `<key>_user_<id>`) would get an EMPTY hidden set at launch, so
        // `isLibraryVisible` would report every library — including
        // private ones the profile hid — as visible until the async
        // per-user load lands. That race fails OPEN and leaks private
        // libraries into the launch list.
        //
        // The last-selected profile id is, however, already persisted
        // synchronously by PlexUserProfileManager (it restores from the
        // same key). Seed `currentUserId` from it so the FIRST load below
        // reads the correct per-user keys immediately — no race, no
        // network wait. `nil` (never selected a profile ⇒ legit
        // single-user / no Plex Home) keeps the base keys, which are
        // authoritative there. `onProfileSwitched` still corrects this if
        // the profile changes in-session.
        currentUserId = userDefaults.object(forKey: persistedSelectedUserIdKey) as? Int

        // Load settings for current user (if any)
        loadSettingsForCurrentUser()
    }

    // MARK: - Per-User Settings

    /// Generate a user-specific key
    private func currentKey(_ baseKey: String) -> String {
        if let userId = currentUserId {
            return "\(baseKey)_user_\(userId)"
        }
        return baseKey
    }

    /// Load settings for the current user from UserDefaults
    private func loadSettingsForCurrentUser() {
        // Load hidden libraries
        if let hidden = userDefaults.array(forKey: currentKey(hiddenLibrariesBaseKey)) as? [String] {
            self.hiddenLibraryKeys = Set(hidden)
        } else {
            self.hiddenLibraryKeys = []
        }

        // Load library order
        if let order = userDefaults.array(forKey: currentKey(libraryOrderBaseKey)) as? [String] {
            self.libraryOrder = order
        } else {
            self.libraryOrder = []
        }

        // Load Home screen libraries
        if let homeLibs = userDefaults.array(forKey: currentKey(homeLibrariesBaseKey)) as? [String] {
            self.librariesShownOnHome = Set(homeLibs)
        } else {
            self.librariesShownOnHome = []
        }

        // Load whether Home visibility has been configured
        self.homeVisibilityConfigured = userDefaults.bool(forKey: currentKey(homeVisibilityConfiguredBaseKey))

        // Load per-library sort options
        if let sortData = userDefaults.data(forKey: currentKey(sortOptionsBaseKey)),
           let sortOptions = try? JSONDecoder().decode([String: LibrarySortOption].self, from: sortData) {
            self.librarySortOptions = sortOptions
        } else {
            self.librarySortOptions = [:]
        }

    }

    /// Switch to a different user's settings
    /// - Parameter userId: The user ID to switch to, or nil for default
    func switchToUser(_ userId: Int?) {
        guard currentUserId != userId else { return }

        currentUserId = userId
        loadSettingsForCurrentUser()
    }

    /// Called when profile is switched - reloads settings for the new user
    func onProfileSwitched() {
        let newUserId = PlexUserProfileManager.shared.selectedUserId
        switchToUser(newUserId)
    }

    // MARK: - Public Methods

    /// Check if a library is visible
    /// Sidebar visibility is THIS DEVICE'S own preference, deliberately.
    ///
    /// There is no Plex-side sidebar pin list to follow. Measured against a live
    /// PMS 1.43.3 and plex.tv: the server exposes no pin field, plex.tv exposes
    /// no pinned-sources endpoint, and `/hubs/promoted` returns the same rows
    /// whatever `pinnedContentDirectoryID` you pass it. The client PASSES that
    /// parameter, which is the tell: the server has to be told, because it does
    /// not know. Every Plex app keeps its own pinned list, so "the user's Plex
    /// sidebar" is not one thing to match.
    ///
    /// `PlexLibrary.hidden` is NOT it. On the reference account Audio Books
    /// (`hidden == 1`) was pinned while musicDemo (`hidden == 0`) was not, so
    /// the two are independent. `hidden` governs HOME (see
    /// `PlexDataStore.projectHomeItems`), which IS account-level and shared, and
    /// that is the one Rivulet follows.
    func isLibraryVisible(_ libraryKey: String) -> Bool {
        !hiddenLibraryKeys.contains(libraryKey)
    }

    /// Toggle library visibility in sidebar
    /// When showing a library, it's automatically added to Home screen
    func toggleVisibility(for libraryKey: String) {
        if hiddenLibraryKeys.contains(libraryKey) {
            // Showing the library - also add to Home
            hiddenLibraryKeys.remove(libraryKey)
            if homeVisibilityConfigured {
                librariesShownOnHome.insert(libraryKey)
            }
        } else {
            hiddenLibraryKeys.insert(libraryKey)
        }
    }

    /// Show a library in sidebar (also adds to Home screen)
    func showLibrary(_ libraryKey: String) {
        hiddenLibraryKeys.remove(libraryKey)
        if homeVisibilityConfigured {
            librariesShownOnHome.insert(libraryKey)
        }
    }

    /// Hide a library from sidebar
    func hideLibrary(_ libraryKey: String) {
        hiddenLibraryKeys.insert(libraryKey)
    }

    // MARK: - Home Screen Visibility

    /// Check if a library should appear on the Home screen
    /// If not yet configured, all visible libraries are shown by default
    func isLibraryShownOnHome(_ libraryKey: String) -> Bool {
        if !homeVisibilityConfigured {
            // Not configured yet - show all visible libraries
            return isLibraryVisible(libraryKey)
        }
        return librariesShownOnHome.contains(libraryKey)
    }

    /// Set whether a library appears on the Home screen
    /// - Parameters:
    ///   - libraryKey: The library key
    ///   - shown: Whether to show on Home
    ///   - allLibraryKeys: All current library keys (needed for first-time setup)
    func setLibraryShownOnHome(_ libraryKey: String, shown: Bool, allLibraryKeys: [String]? = nil) {
        // When first configuring, populate with all libraries as ON, then apply change
        if !homeVisibilityConfigured {
            if let allKeys = allLibraryKeys {
                // Start with all libraries visible on Home
                for key in allKeys {
                    librariesShownOnHome.insert(key)
                }
            }
            homeVisibilityConfigured = true
        }

        if shown {
            librariesShownOnHome.insert(libraryKey)
        } else {
            librariesShownOnHome.remove(libraryKey)
        }
    }

    /// Toggle Home screen visibility for a library
    /// - Parameters:
    ///   - libraryKey: The library key to toggle
    ///   - allLibraryKeys: All current visible library keys (needed for first-time setup)
    func toggleHomeVisibility(for libraryKey: String, allLibraryKeys: [String] = []) {
        setLibraryShownOnHome(libraryKey, shown: !isLibraryShownOnHome(libraryKey), allLibraryKeys: allLibraryKeys)
    }

    /// Initialize Home visibility for all visible libraries
    /// Called when libraries are first loaded to set up defaults
    func initializeHomeVisibility(for libraries: [PlexLibrary]) {
        guard !homeVisibilityConfigured else { return }

        // Default: show all visible video and music libraries on Home
        for library in libraries where (library.isVideoLibrary || library.isMusicLibrary) && isLibraryVisible(library.key) {
            librariesShownOnHome.insert(library.key)
        }
        homeVisibilityConfigured = true
    }

    /// Move a library in the order list
    /// - Parameters:
    ///   - fromIndex: Source index in the ordered list
    ///   - toIndex: Destination index in the ordered list
    func moveLibrary(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < libraryOrder.count,
              toIndex >= 0, toIndex <= libraryOrder.count else {
            return
        }

        let key = libraryOrder.remove(at: fromIndex)
        let adjustedIndex = toIndex > fromIndex ? toIndex - 1 : toIndex
        libraryOrder.insert(key, at: min(adjustedIndex, libraryOrder.count))
    }

    /// Sort libraries according to saved preferences
    /// - Parameter libraries: The full list of libraries from Plex
    /// - Returns: Libraries sorted by user preference, with unordered ones at the end
    func sortLibraries(_ libraries: [PlexLibrary]) -> [PlexLibrary] {
        // Create a lookup for quick access
        // Use uniquingKeysWith to handle potential duplicate keys (keep first occurrence)
        let libraryByKey = Dictionary(
            libraries.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var result: [PlexLibrary] = []

        // First, add libraries in the specified order
        for key in libraryOrder {
            if let library = libraryByKey[key] {
                result.append(library)
            }
        }

        // Then add any libraries not in the order list (in their original order)
        let orderedKeys = Set(libraryOrder)
        for library in libraries {
            if !orderedKeys.contains(library.key) {
                result.append(library)
            }
        }

        return result
    }

    /// Filter libraries to only visible ones
    /// - Parameter libraries: The full list of libraries
    /// - Returns: Only libraries that are not hidden
    func filterVisibleLibraries(_ libraries: [PlexLibrary]) -> [PlexLibrary] {
        libraries.filter { isLibraryVisible($0.key) }
    }

    /// Filter and sort libraries according to user preferences
    /// - Parameter libraries: The full list of libraries from Plex
    /// - Returns: Visible libraries sorted by user preference
    func filterAndSortLibraries(_ libraries: [PlexLibrary]) -> [PlexLibrary] {
        let visible = filterVisibleLibraries(libraries)
        return sortLibraries(visible)
    }

    /// Update the order list to include all current libraries
    /// This ensures new libraries get added to the order list
    func syncOrderWithLibraries(_ libraries: [PlexLibrary]) {
        let currentKeys = Set(libraries.map { $0.key })
        let orderedKeys = Set(libraryOrder)

        // Add any new libraries to the end of the order
        for library in libraries {
            if !orderedKeys.contains(library.key) {
                libraryOrder.append(library.key)

                // If Home visibility is already configured, add new video/music libraries to Home by default
                if homeVisibilityConfigured && (library.isVideoLibrary || library.isMusicLibrary) && isLibraryVisible(library.key) {
                    librariesShownOnHome.insert(library.key)
                }
            }
        }

        // Remove any libraries from order that no longer exist
        libraryOrder = libraryOrder.filter { currentKeys.contains($0) }

        // Also clean up hidden keys for libraries that no longer exist
        hiddenLibraryKeys = hiddenLibraryKeys.filter { currentKeys.contains($0) }

        // Clean up Home visibility for libraries that no longer exist
        librariesShownOnHome = librariesShownOnHome.filter { currentKeys.contains($0) }
    }

    /// Reset all library settings to defaults
    func resetToDefaults() {
        hiddenLibraryKeys = []
        libraryOrder = []
        librariesShownOnHome = []
        homeVisibilityConfigured = false
        librarySortOptions = [:]
    }

    /// Show every library in the sidebar (and on Home if Home visibility is configured).
    func showAllLibraries(_ allLibraryKeys: [String]) {
        hiddenLibraryKeys = []
        if homeVisibilityConfigured {
            for key in allLibraryKeys {
                librariesShownOnHome.insert(key)
            }
        }
    }

    /// Hide every library from the sidebar.
    func hideAllLibraries(_ allLibraryKeys: [String]) {
        hiddenLibraryKeys = Set(allLibraryKeys)
    }

    // MARK: - Sort Options

    /// Get the sort option for a specific library
    /// - Parameter libraryKey: The library key
    /// - Returns: The configured sort option, or `.addedAtDesc` as default
    func getSortOption(for libraryKey: String) -> LibrarySortOption {
        librarySortOptions[libraryKey] ?? .addedAtDesc
    }

    /// Set the sort option for a specific library
    /// - Parameters:
    ///   - option: The sort option to use
    ///   - libraryKey: The library key
    func setSortOption(_ option: LibrarySortOption, for libraryKey: String) {
        librarySortOptions[libraryKey] = option
    }

    // MARK: - MediaLibrary SortOption persistence
    //
    // Independent of LibrarySortOption above. Keyed by a distinct prefix so
    // they never collide. Stable string mapping (explicit switch) — NOT
    // String(describing:) which is unstable across compiler versions.

    private let mediaSortBaseKey = "mediaLibrarySort"

    private func mediaSortKey(for libraryKey: String) -> String {
        "\(mediaSortBaseKey).\(libraryKey)"
    }

    private func sortOptionString(_ option: SortOption) -> String {
        switch option {
        case .titleAsc:        return "titleAsc"
        case .titleDesc:       return "titleDesc"
        case .releaseDateDesc: return "releaseDateDesc"
        case .addedAtDesc:     return "addedAtDesc"
        case .ratingDesc:      return "ratingDesc"
        }
    }

    private func sortOptionFromString(_ string: String) -> SortOption? {
        switch string {
        case "titleAsc":        return .titleAsc
        case "titleDesc":       return .titleDesc
        case "releaseDateDesc": return .releaseDateDesc
        case "addedAtDesc":     return .addedAtDesc
        case "ratingDesc":      return .ratingDesc
        default:                return nil
        }
    }

    /// Returns the persisted SortOption for a given library, or nil if none stored.
    func getMediaSortOption(for libraryKey: String) -> SortOption? {
        guard let raw = userDefaults.string(forKey: mediaSortKey(for: libraryKey)) else { return nil }
        return sortOptionFromString(raw)
    }

    /// Persists a SortOption for a given library.
    func setMediaSortOption(_ option: SortOption, for libraryKey: String) {
        userDefaults.set(sortOptionString(option), forKey: mediaSortKey(for: libraryKey))
    }

    // MARK: - Private Methods

    private func saveHiddenLibraries() {
        userDefaults.set(Array(hiddenLibraryKeys), forKey: currentKey(hiddenLibrariesBaseKey))
    }

    private func saveLibraryOrder() {
        userDefaults.set(libraryOrder, forKey: currentKey(libraryOrderBaseKey))
    }

    private func saveHomeLibraries() {
        userDefaults.set(Array(librariesShownOnHome), forKey: currentKey(homeLibrariesBaseKey))
    }

    private func saveSortOptions() {
        if let data = try? JSONEncoder().encode(librarySortOptions) {
            userDefaults.set(data, forKey: currentKey(sortOptionsBaseKey))
        }
    }
}
