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
    private let sortOptionsBaseKey = "librarySortOptions"

    /// Retired in the #295 cleanup. Kept only so `loadSettingsForCurrentUser`
    /// can delete what old builds wrote; see the Home Screen Visibility note.
    private let retiredHomeVisibilityBaseKeys =
        ["librariesShownOnHome", "homeVisibilityConfigured"]

    /// Current user ID for per-user settings (nil = default/no profile)
    private var currentUserId: Int?

    /// The signed-in non-Plex servers whose libraries' settings are loaded.
    /// Their keys are saved under the server and its own signed-in user, never
    /// the Plex profile: a Jellyfin-only user has no profile, and switching
    /// Plex profile must not change which Jellyfin libraries show.
    private var providerScopes: [ProviderScope] = []

    struct ProviderScope: Equatable {
        let providerID: String
        /// The provider's signed-in user, nil when it has none.
        let accountID: String?
    }

    /// UserDefaults key under which `PlexUserProfileManager` persists the
    /// last-selected Plex Home profile id (`selectedUserIdKey` there).
    /// Read-only mirror — keep in sync with that owner of the key.
    private let persistedSelectedUserIdKey = "selectedPlexUserId"

    // MARK: - Initialization

    private init() {
        // Initialize with empty values - will be loaded when user is set
        self.hiddenLibraryKeys = []
        self.libraryOrder = []
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

    /// Where one non-Plex server's own hidden or order list is saved.
    private func providerKey(_ baseKey: String, _ scope: ProviderScope) -> String {
        "\(baseKey)_provider_\(scope.providerID)" + (scope.accountID.map { "_\($0)" } ?? "")
    }

    /// The server a provider key belongs to (`MediaLibrary.settingsKey` is
    /// "<providerID>/<library id>").
    private static func providerID(ofKey key: String) -> String {
        String(key.prefix { $0 != "/" })
    }

    /// The Plex profile's keys plus each loaded server's own.
    private func storedKeys(_ baseKey: String) -> [String] {
        let plex = (userDefaults.array(forKey: currentKey(baseKey)) as? [String] ?? [])
            .filter { !Self.isProviderKey($0) }
        let providers = providerScopes.flatMap {
            userDefaults.array(forKey: providerKey(baseKey, $0)) as? [String] ?? []
        }
        return plex + providers
    }

    /// Splits `keys` back into the Plex profile's list and each server's.
    private func save(_ keys: [String], baseKey: String) {
        userDefaults.set(keys.filter { !Self.isProviderKey($0) }, forKey: currentKey(baseKey))
        for scope in providerScopes {
            userDefaults.set(keys.filter { Self.isProviderKey($0) && Self.providerID(ofKey: $0) == scope.providerID },
                             forKey: providerKey(baseKey, scope))
        }
    }

    /// Called by `MediaProviderRegistry` whenever sign-ins change: loads the
    /// signed-in non-Plex servers' library settings in place of the last set.
    func setProviderScopes(_ scopes: [ProviderScope]) {
        guard scopes != providerScopes else { return }
        providerScopes = scopes
        loadSettingsForCurrentUser()
    }

    /// Load settings for the current user from UserDefaults
    private func loadSettingsForCurrentUser() {
        self.hiddenLibraryKeys = Set(storedKeys(hiddenLibrariesBaseKey))
        self.libraryOrder = storedKeys(libraryOrderBaseKey)

        pruneRetiredHomeVisibilityKeys()

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

    /// Toggle library visibility in the sidebar, and so on Home too.
    func toggleVisibility(for libraryKey: String) {
        if hiddenLibraryKeys.contains(libraryKey) {
            hiddenLibraryKeys.remove(libraryKey)
        } else {
            hiddenLibraryKeys.insert(libraryKey)
        }
    }

    /// Show a library in the sidebar, and so on Home too.
    func showLibrary(_ libraryKey: String) {
        hiddenLibraryKeys.remove(libraryKey)
    }

    /// Hide a library from sidebar
    func hideLibrary(_ libraryKey: String) {
        hiddenLibraryKeys.insert(libraryKey)
    }

    // MARK: - Home Screen Visibility
    //
    // There is no separate shown-on-Home set any more. `librariesShownOnHome`,
    // `homeVisibilityConfigured`, `isLibraryShownOnHome`, `setLibraryShownOnHome`
    // and `initializeHomeVisibility` all lived here with NO writer anywhere in
    // the app: the UIKit settings migration deleted the SwiftUI page that was
    // their only caller, so the flag never flipped and the whole concept
    // degraded to `isLibraryVisible`. Worse, anyone carrying
    // `homeVisibilityConfigured = true` from a build before that migration was
    // left with a frozen set they could no longer edit.
    //
    // Home visibility is now the sidebar toggle plus Plex's own pin; see
    // `PlexDataStore.librariesPinnedToHome`. Per-row control is
    // `HomeRowSettings`. Do not add a third one. The stale UserDefaults keys are
    // dropped in `pruneRetiredHomeVisibilityKeys` below.

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
            }
        }

        // Remove any libraries from order that no longer exist
        // Jellyfin keys are not this server's to prune: a Plex refresh would
        // otherwise delete every Jellyfin library's place and visibility.
        libraryOrder = libraryOrder.filter { currentKeys.contains($0) || Self.isProviderKey($0) }

        // Also clean up hidden keys for libraries that no longer exist
        hiddenLibraryKeys = hiddenLibraryKeys.filter { currentKeys.contains($0) || Self.isProviderKey($0) }
    }

    /// A non-Plex library's key (`MediaLibrary.settingsKey`). Plex section
    /// keys are bare numbers and never contain ":".
    static func isProviderKey(_ key: String) -> Bool { key.contains(":") }

    /// `filterAndSortLibraries` for a non-Plex server's libraries: hidden ones
    /// dropped, ordered ones first in their saved order, the rest in server order.
    func filterAndSort(_ libraries: [MediaLibrary]) -> [MediaLibrary] {
        sort(libraries).filter { isLibraryVisible($0.settingsKey) }
    }

    /// Saved order first, the rest in server order; hidden ones keep their place.
    func sort(_ libraries: [MediaLibrary]) -> [MediaLibrary] {
        let rank = Dictionary(libraryOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return libraries.enumerated()
            .sorted { (rank[$0.element.settingsKey] ?? .max, $0.offset) < (rank[$1.element.settingsKey] ?? .max, $1.offset) }
            .map(\.element)
    }

    /// One step up or down within `keys` (one server's libraries in displayed
    /// order). Rewrites `libraryOrder` as that run followed by every other
    /// key, so nothing is dropped. A step off either end of the run does
    /// nothing: the sidebar shows each server in its own section.
    func moveLibrary(key: String, up: Bool, among keys: [String]) {
        var run = keys
        guard let i = run.firstIndex(of: key) else { return }
        let j = up ? i - 1 : i + 1
        guard run.indices.contains(j) else { return }
        run.swapAt(i, j)
        libraryOrder = run + libraryOrder.filter { !run.contains($0) }
    }

    /// Show every library in the sidebar, and so on Home too.
    func showAllLibraries() {
        hiddenLibraryKeys = []
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
        case .addedAtAsc:      return "addedAtAsc"
        case .releaseDateAsc:  return "releaseDateAsc"
        case .lastContentAddedDesc: return "lastContentAddedDesc"
        case .ratingDesc:      return "ratingDesc"
        }
    }

    private func sortOptionFromString(_ string: String) -> SortOption? {
        switch string {
        case "titleAsc":        return .titleAsc
        case "titleDesc":       return .titleDesc
        case "releaseDateDesc": return .releaseDateDesc
        case "addedAtDesc":     return .addedAtDesc
        case "addedAtAsc":      return .addedAtAsc
        case "releaseDateAsc":  return .releaseDateAsc
        case "lastContentAddedDesc": return .lastContentAddedDesc
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
        save(Array(hiddenLibraryKeys), baseKey: hiddenLibrariesBaseKey)
    }

    private func saveLibraryOrder() {
        save(libraryOrder, baseKey: libraryOrderBaseKey)
    }

    /// Drop what pre-#295 builds wrote for the retired shown-on-Home set, so a
    /// long-lived install does not carry dead keys forever. Runs per profile,
    /// since these were namespaced the same way the live keys are.
    private func pruneRetiredHomeVisibilityKeys() {
        for base in retiredHomeVisibilityBaseKeys {
            userDefaults.removeObject(forKey: currentKey(base))
            userDefaults.removeObject(forKey: base)
        }
    }

    private func saveSortOptions() {
        if let data = try? JSONEncoder().encode(librarySortOptions) {
            userDefaults.set(data, forKey: currentKey(sortOptionsBaseKey))
        }
    }
}

extension MediaLibrary {
    /// Key in `LibrarySettingsManager`'s hidden and order lists and its
    /// per-library sort. Carries the provider, so it never equals a Plex
    /// section key and survives a Plex refresh (`isProviderKey`).
    var settingsKey: String { "\(providerID)/\(id)" }
}
