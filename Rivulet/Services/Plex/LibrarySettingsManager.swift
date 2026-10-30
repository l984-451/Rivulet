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

    /// Server-wide library visibility, separate from each library's own choice.
    @Published var hiddenLibraryServerIDs: Set<String> = [] {
        didSet {
            userDefaults.set(Array(hiddenLibraryServerIDs.filter { $0.hasPrefix("plex:") }),
                             forKey: currentKey(hiddenLibraryServersBaseKey))
            for scope in providerScopes where !scope.providerID.hasPrefix("plex:") {
                userDefaults.set(hiddenLibraryServerIDs.contains(scope.providerID),
                                 forKey: providerKey(hiddenLibraryServersBaseKey, scope))
            }
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
    private let hiddenLibraryServersBaseKey = "hiddenLibraryServerIDs"
    private let libraryOrderBaseKey = "libraryOrder"
    private let sortOptionsBaseKey = "librarySortOptions"
    /// The order across every server, per Plex profile. Each server's own list
    /// keeps its libraries' relative order; this one says how they interleave.
    private let combinedOrderBaseKey = "libraryOrderAllServers"

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

        // Privacy: seed the persisted profile id so the first load reads that profile's
        // keys. Base keys here would show its hidden libraries until the profile resolves.
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
        let plexServers = userDefaults.array(forKey: currentKey(hiddenLibraryServersBaseKey)) as? [String] ?? []
        let nativeServers = providerScopes.filter {
            !$0.providerID.hasPrefix("plex:")
                && userDefaults.bool(forKey: providerKey(hiddenLibraryServersBaseKey, $0))
        }.map(\.providerID)
        hiddenLibraryServerIDs = Set(plexServers + nativeServers)
        self.hiddenLibraryKeys = Set(storedKeys(hiddenLibrariesBaseKey))
        let combined = userDefaults.array(forKey: currentKey(combinedOrderBaseKey)) as? [String] ?? []
        self.libraryOrder = Self.arrange(storedKeys(libraryOrderBaseKey), key: { $0 }, savedOrder: combined)
        seedSidebarOrderIfNeeded()

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

    /// Sidebar visibility is this device's preference. Plex keeps sidebar pins per app: PMS 1.43.3
    /// and plex.tv expose no pin list, and `/hubs/promoted` ignores `pinnedContentDirectoryID`.
    /// `PlexLibrary.hidden` is the Home pin, independent of the sidebar.
    func isLibraryVisible(_ libraryKey: String) -> Bool {
        guard !hiddenLibraryKeys.contains(libraryKey) else { return false }
        if Self.isProviderKey(libraryKey) {
            return areServerLibrariesVisible(Self.providerID(ofKey: libraryKey))
        }
        guard !SidebarArrangement.isAppRow(libraryKey),
              let providerID = MediaProviderRegistry.shared.plexProvider?.id else { return true }
        return areServerLibrariesVisible(providerID)
    }

    func areServerLibrariesVisible(_ providerID: String) -> Bool {
        !hiddenLibraryServerIDs.contains(providerID)
    }

    /// Does not rewrite library hide choices or order; new libraries inherit this gate.
    func setServerLibrariesVisible(_ visible: Bool, providerID: String) {
        if visible { hiddenLibraryServerIDs.remove(providerID) }
        else { hiddenLibraryServerIDs.insert(providerID) }
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
    // Home visibility is the sidebar toggle plus Plex's pin (`PlexDataStore.librariesPinnedToHome`),
    // and per-row control is `HomeRowSettings`. Do not add a third.

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

        // A new library goes after this server's last one, never past another
        // server's, so it does not split the user's order into mixed servers.
        var order = libraryOrder
        for library in libraries where !orderedKeys.contains(library.key) {
            order = SidebarArrangement.insert(library.key, into: order)
        }

        // Remove any libraries from order that no longer exist
        // Jellyfin keys are not this server's to prune: a Plex refresh would
        // otherwise delete every Jellyfin library's place and visibility.
        // Nor are the sidebar's other rows.
        libraryOrder = order.filter { currentKeys.contains($0) || Self.isProviderKey($0) || SidebarArrangement.isAppRow($0) }

        // Also clean up hidden keys for libraries that no longer exist
        hiddenLibraryKeys = hiddenLibraryKeys.filter {
            currentKeys.contains($0) || Self.isProviderKey($0) || SidebarArrangement.isAppRow($0)
        }
    }

    /// A non-Plex library's key (`MediaLibrary.settingsKey`). Plex section
    /// keys are bare numbers and never contain ":".
    nonisolated static func isProviderKey(_ key: String) -> Bool {
        key.contains(":") && !SidebarArrangement.isAppRow(key)
    }

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

    /// Every server's libraries in the one sidebar and Home order (#87). `items`
    /// come grouped by server, the selected Plex server first.
    func arrange<T>(_ items: [T], key: (T) -> String) -> [T] {
        Self.arrange(items, key: key, savedOrder: libraryOrder)
    }

    /// Saved keys first, in saved order. An unsaved key (a new library) goes right
    /// after the last of its own server's, so it never splits a server's run; one
    /// whose server has none saved goes last.
    nonisolated static func arrange<T>(_ items: [T], key: (T) -> String, savedOrder: [String]) -> [T] {
        let rank = Dictionary(savedOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var result = items.filter { rank[key($0)] != nil }.sorted { rank[key($0)]! < rank[key($1)]! }
        for item in items where rank[key(item)] == nil {
            let server = serverID(ofKey: key(item))
            if let last = result.lastIndex(where: { serverID(ofKey: key($0)) == server }) {
                result.insert(item, at: last + 1)
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// The server a key belongs to: "" for the selected Plex server's bare section
    /// keys, else the provider id of a "<providerID>/<library id>" key.
    nonisolated static func serverID(ofKey key: String) -> String {
        isProviderKey(key) ? String(key.prefix { $0 != "/" }) : ""
    }

    /// Whether each server's libraries sit together in `keys`, so the sidebar can
    /// head them with the server's name instead of badging each one.
    nonisolated static func isGroupedByServer(_ keys: [String]) -> Bool {
        var seen: Set<String> = []
        var current: String?
        for key in keys {
            let server = serverID(ofKey: key)
            guard server != current else { continue }
            guard seen.insert(server).inserted else { return false }
            current = server
        }
        return true
    }

    /// One step up or down within `keys` (the libraries in displayed order).
    /// Rewrites `libraryOrder` as that run followed by every other key, so
    /// nothing is dropped. A step off either end of the run does nothing.
    func moveLibrary(key: String, up: Bool, among keys: [String]) {
        var run = keys
        guard let i = run.firstIndex(of: key) else { return }
        let j = up ? i - 1 : i + 1
        guard run.indices.contains(j) else { return }
        run.swapAt(i, j)
        libraryOrder = run + libraryOrder.filter { !run.contains($0) }
    }

    /// Show every library in the sidebar, and so on Home too. Other rows keep theirs.
    func showAllLibraries() {
        hiddenLibraryKeys = hiddenLibraryKeys.filter(SidebarArrangement.isAppRow)
    }

    /// Hide every library from the sidebar. Other rows keep theirs.
    func hideAllLibraries(_ allLibraryKeys: [String]) {
        hiddenLibraryKeys = hiddenLibraryKeys.filter(SidebarArrangement.isAppRow).union(allLibraryKeys)
    }

    // MARK: - Sidebar rows

    /// One step up or down among the sidebar's shown rows (`visible`, in order).
    func moveSidebarRow(key: String, up: Bool, visible: [String]) {
        libraryOrder = SidebarArrangement.move(key, up: up, visible: visible, order: libraryOrder)
    }

    /// A Playlists row's visibility. The retired Show Playlists toggle hid them all.
    func isPlaylistsRowVisible(_ key: String) -> Bool {
        !hiddenLibraryKeys.contains(key) && !hiddenLibraryKeys.contains(SidebarArrangement.allPlaylistsHidden)
    }

    /// `allKeys`: every server's Playlists key, so turning one on keeps the others off.
    func setPlaylistsRow(_ key: String, visible: Bool, allKeys: [String]) {
        var hidden = hiddenLibraryKeys
        if hidden.remove(SidebarArrangement.allPlaylistsHidden) != nil { hidden.formUnion(allKeys) }
        if visible { hidden.remove(key) } else { hidden.insert(key) }
        hiddenLibraryKeys = hidden
    }

    /// Settings > Sidebar > Reset: the default order with every row shown.
    func resetSidebar() {
        hiddenLibraryKeys = []
        libraryOrder = SidebarArrangement.seed(libraryOrder: [], discoverAbove: true, liveTVAbove: false)
    }

    /// The first load on a build with an arrangeable sidebar keeps today's layout.
    private func seedSidebarOrderIfNeeded() {
        guard !SidebarArrangement.isSeeded(libraryOrder) else { return }
        let flag = { (key: String, fallback: Bool) in self.userDefaults.object(forKey: key) as? Bool ?? fallback }
        libraryOrder = SidebarArrangement.seed(libraryOrder: libraryOrder,
                                               discoverAbove: flag("discoverAboveLibraries", true),
                                               liveTVAbove: flag("liveTVAboveLibraries", false))
        if !flag("showPlaylistsTab", true) { hiddenLibraryKeys.insert(SidebarArrangement.allPlaylistsHidden) }
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

    // MARK: - View mode

    private let viewModeBaseKey = "libraryViewMode"

    /// The view this profile last left the library on.
    func viewMode(_ libraryKey: String) -> LibraryViewMode {
        (userDefaults.dictionary(forKey: currentKey(viewModeBaseKey))?[libraryKey] as? String)
            .flatMap(LibraryViewMode.init) ?? .titles
    }

    func setViewMode(_ mode: LibraryViewMode, for libraryKey: String) {
        var modes = userDefaults.dictionary(forKey: currentKey(viewModeBaseKey)) ?? [:]
        modes[libraryKey] = mode.rawValue
        userDefaults.set(modes, forKey: currentKey(viewModeBaseKey))
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
        userDefaults.set(libraryOrder, forKey: currentKey(combinedOrderBaseKey))
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
