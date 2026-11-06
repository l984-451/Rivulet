// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CloudKit
import Combine
import CryptoKit
import Foundation
import UIKit

/// iCloud sync for both apps. Preferences ride `NSUbiquitousKeyValueStore` through `PreferenceMirror`;
/// `UserDefaults` stays the source of truth. Accounts and Live TV sources ride one encrypted CloudKit
/// record through `AccountSyncCoordinator`. The per-device switch is `SyncCatalog.enabledKey`, off by default.
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    /// Set by the host at launch, before `start()`: stores that cache a synced key reload here.
    static var onPreferencesApplied: ((Set<String>) -> Void)?
    /// Every account type the vault carries; both apps sign all of them in.
    static var accountKinds: [SyncedAccountKind] { [.plex, .liveTV, .jellyfin, .emby] }
    /// Accounts or sources were signed in or out here because another device changed them.
    static var onAccountsChanged: (() -> Void)?

    typealias Status = CloudSyncStatus

    /// `.on` means an iCloud account is signed in and CloudKit answers (iCloud Drive is not involved).
    @Published private(set) var status: Status = .off
    /// False from launch until the first look at the vault ends (or at once when there is nothing to look at).
    @Published private(set) var accountsReady = true
    /// Ids where iCloud holds somebody else's account (a second Plex account).
    @Published private(set) var blockedAccountIDs: Set<String> = []

    private let defaults = UserDefaults.standard
    private var started = false
    private var mirror: PreferenceMirror?
    private var debounce: Task<Void, Never>?
    private var accountDebounce: Task<Void, Never>?
    private var accountsRunning = false
    private var accountsAgain = false
    private var loggedUnreadableVault = false
    /// The key-value store already announced the switch of account; the next identity check must not repeat it.
    private var switchAnnounced = false
    private lazy var vault = AccountVault()
    private lazy var coordinator = AccountSyncCoordinator(vault: vault, kinds: Self.accountKinds)

    /// Off until this device turns it on.
    var isEnabled: Bool { defaults.bool(forKey: SyncCatalog.enabledKey) }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: SyncCatalog.enabledKey)
        enabled ? activate() : deactivate()
    }

    /// Call once at launch, after the host has set its hooks.
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            Task { @MainActor [weak self] in self?.keyValueStoreChanged(reason: reason) }
        }
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleReconcile() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.foregrounded() }
        }
        center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAccountSoon() }
        }
        isEnabled ? activate() : deactivate()
    }

    // MARK: - Accounts

    /// Whether this account or source is shared with the other devices now. Sign-out asks only then.
    func isSynced(accountID: String) -> Bool {
        SyncAvailability.isSynced(enabled: isEnabled, status: status,
                                  suppressed: coordinator.isSuppressed(accountID),
                                  blocked: blockedAccountIDs.contains(accountID))
    }

    /// Whether this was signed out here only, and stays out until signed in here again.
    func isSignedOutHere(accountID: String) -> Bool { coordinator.isSuppressed(accountID) }

    /// Whether this credential was ever uploaded to or taken from iCloud. A single-device sign-out never revokes one.
    func wasShared(accountID: String) -> Bool { coordinator.wasShared(accountID) }

    /// Call after an account or source was signed out or removed here (not for a removal another device asked for).
    func signedOut(accountID: String, identity: String?, scope: SignOutScope) {
        coordinator.signedOut(id: accountID, identity: identity, everywhere: scope.tombstones(synced: isSynced(accountID: accountID)))
        scheduleAccountSync()
    }

    /// Call after an account or source was signed in, added or changed here.
    func accountsChanged() {
        scheduleAccountSync()
    }

    // MARK: - Private

    private func activate() {
        mirror = mirror ?? PreferenceMirror(store: UbiquitousKeyValueStore())
        reconcile()
        accountsReady = false
        refreshAccountSoon()
    }

    private func deactivate() {
        debounce?.cancel()
        accountDebounce?.cancel()
        mirror = nil
        accountsReady = true
        status = .off
    }

    private func foregrounded() {
        reconcile()
        refreshAccountSoon()
    }

    private func refreshAccountSoon() {
        Task { [weak self] in await self?.refreshAccount() }
    }

    /// Asks CloudKit whether an account is signed in, notes a switch of account, and starts a vault cycle.
    private func refreshAccount() async {
        guard isEnabled else { status = .off; return }
        let available = await vault.accountAvailable()
        guard isEnabled else { return }
        status = available ? .on : .noAccount
        guard available else { accountsReady = true; return }
        if let identity = await vault.accountIdentity() { noteAppleAccount(identity) }
        scheduleAccountSync(after: .zero)
    }

    /// A different Apple account since the last look: take its settings, and keep this device's
    /// preferences and sign-ins out of it until they are changed here.
    private func noteAppleAccount(_ identity: String) {
        defer { switchAnnounced = false }
        let print = SHA256.hash(data: Data(identity.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let previous = defaults.string(forKey: SyncCatalog.accountPrintKey)
        defaults.set(print, forKey: SyncCatalog.accountPrintKey)
        guard let previous, previous != print, !switchAnnounced else { return }
        DiagLog.notice(.sync, "Apple account changed")
        accountSwitched()
    }

    private func accountSwitched() {
        mirror?.holdLocalValues()
        coordinator.accountChanged()
        reconcile()
    }

    private func reconcile() {
        guard isEnabled, let mirror else { return }
        let applied = mirror.reconcile()
        guard !applied.isEmpty else { return }
        LiveTVDataStore.shared.syncedPreferencesChanged(applied)
        PlexExtraServers.shared.syncedPreferencesChanged(applied)
        if applied.contains(JellyfinLiveTVProvider.hiddenKey) {
            _ = JellyfinLiveTVProvider.setHidden(defaults.bool(forKey: JellyfinLiveTVProvider.hiddenKey))
        }
        if applied.contains(EmbyLiveTVProvider.hiddenKey) {
            _ = EmbyLiveTVProvider.setHidden(defaults.bool(forKey: EmbyLiveTVProvider.hiddenKey))
        }
        Self.onPreferencesApplied?(applied)
    }

    private func scheduleReconcile() {
        guard isEnabled, mirror != nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    private func scheduleAccountSync(after delay: Duration = .seconds(3)) {
        guard isEnabled, status == .on else { accountsReady = true; return }
        accountDebounce?.cancel()
        accountDebounce = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.runAccountSync()
        }
    }

    private func runAccountSync() async {
        guard isEnabled, status == .on else { accountsReady = true; return }
        if accountsRunning { accountsAgain = true; return }
        accountsRunning = true
        do {
            if try await coordinator.sync() { Self.onAccountsChanged?() }
        } catch let error as VaultError {
            // The record is left exactly as it is; saying so once is enough.
            if !loggedUnreadableVault {
                loggedUnreadableVault = true
                DiagLog.error(.sync, "iCloud account record not readable by this version (\(error)); left untouched")
            }
        } catch {
            // Domain and code only: a CKError's description can carry the record it failed on.
            let ns = error as NSError
            DiagLog.error(.sync, "iCloud accounts: \(ns.domain) \(ns.code)")
        }
        blockedAccountIDs = coordinator.blocked
        accountsReady = true
        accountsRunning = false
        if accountsAgain {
            accountsAgain = false
            scheduleAccountSync()
        }
    }

    private func keyValueStoreChanged(reason: Int?) {
        switch reason {
        case NSUbiquitousKeyValueStoreAccountChange:
            switchAnnounced = true
            accountSwitched()
            refreshAccountSoon()
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            DiagLog.error(.sync, "iCloud key-value quota exceeded")
        default:
            reconcile()
        }
    }
}
