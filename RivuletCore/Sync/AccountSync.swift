// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// How a sign-out or removal reaches the other devices.
nonisolated enum SignOutScope {
    /// This device only: the credential is not revoked, and stays out of this device until signed in here again.
    case thisDevice
    /// Every device: revoked where a server allows it, and a tombstone tells the others.
    case everywhere
    /// A tombstone arrived from another device. Signs out locally and touches nothing else.
    case syncedRemoval
}

nonisolated enum AdoptOutcome: Equatable {
    case adopted
    /// The server or the entry says no (token rejected, another server already signed in): not tried again until the record changes.
    case refused
    /// Could not find out (offline): tried again next cycle.
    case unavailable
}

/// What the Settings row and the sign-out question go by.
nonisolated enum CloudSyncStatus: Equatable { case off, on, noAccount }

nonisolated enum SyncAvailability {
    /// Whether an account or source is shared with the other devices right now: only then does signing out ask.
    static func isSynced(enabled: Bool, status: CloudSyncStatus, suppressed: Bool, blocked: Bool) -> Bool {
        enabled && status == .on && !suppressed && !blocked
    }
}

nonisolated extension SignOutScope {
    /// A synced credential is one token on every device, so only "everywhere" may revoke it.
    func revokesToken(everShared: Bool) -> Bool {
        switch self {
        case .everywhere: return true
        case .thisDevice: return !everShared
        case .syncedRemoval: return false
        }
    }

    func tombstones(synced: Bool) -> Bool { self == .everywhere && synced }
}

/// One account type the vault carries. Each kind lives next to its session.
struct SyncedAccountKind {
    let kind: String
    /// Whether a newer remote entry replaces an existing local one. Sign-ins do not: the first wins.
    let updatesInPlace: Bool
    /// What this device has now, secrets included.
    let export: @MainActor () -> [AccountExport]
    /// Signs in with a synced entry. False leaves it in iCloud for a later try.
    let adopt: @MainActor (SyncedAccounts.Entry) async -> AdoptOutcome
    /// A tombstone arrived: sign out here without revoking anything.
    let remove: @MainActor (SyncedAccounts.Entry) async -> Void
}

nonisolated struct AccountExport: Equatable {
    var id: String
    var kind: String
    var identity: String?
    var body: Data
}

/// What this device remembers between cycles. Never synced.
nonisolated struct AccountSyncState: Codable, Equatable {
    nonisolated struct Stamp: Codable, Equatable {
        var print: String
        var updatedAt: Date
    }
    /// Per id: the body and time this device last uploaded or applied.
    var ledger: [String: Stamp] = [:]
    /// Removals made here for every device, until the cloud holds them.
    var tombstones: [String: SyncedAccounts.Entry] = [:]
    /// Signed out here only: not taken from iCloud again until signed in here.
    var suppressed: Set<String> = []
    /// After an Apple account switch: what this device already had, kept out of the new account until changed here.
    var held: [String: String] = [:]
    /// Credentials that were ever uploaded to or taken from iCloud. A sign-out on one device never revokes these.
    var shared: Set<String> = []
}

nonisolated enum AccountSyncPlanner {
    struct Plan {
        var merged: SyncedAccounts
        var apply: [SyncedAccounts.Entry]
        var remove: [SyncedAccounts.Entry]
        /// Ids where the cloud has a different person's account in the same slot.
        var blocked: Set<String>
        var state: AccountSyncState
        var needsUpload: Bool
    }

    /// `handled` is every kind this device can sign in; entries of other kinds pass through untouched.
    static func plan(exports: [AccountExport], handled: Set<String>, updatesInPlace: Set<String>,
                     remote: SyncedAccounts, state: AccountSyncState, now: Date) -> Plan {
        var state = state
        let exportByID = Dictionary(exports.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let prints = exportByID.mapValues { SyncedAccounts.bodyPrint($0.body) ?? "" }

        // Changed here since the Apple account switched: no longer held back.
        for (id, held) in state.held where prints[id] != held { state.held[id] = nil }

        var local: [SyncedAccounts.Entry] = []
        var blocked: Set<String> = []
        for export in exports {
            // A live account here means signed in again here.
            state.suppressed.remove(export.id)
            if state.held[export.id] != nil { continue }
            let remoteEntry = remote[export.id]
            if let r = remoteEntry, !r.deleted, let theirs = r.identity, let ours = export.identity, theirs != ours {
                blocked.insert(export.id)
                continue
            }
            let print = prints[export.id] ?? ""
            let stamp: Date
            if let known = state.ledger[export.id], known.print == print {
                stamp = known.updatedAt
            } else if let r = remoteEntry, !r.deleted, r.bodyPrint == print {
                stamp = r.updatedAt
            } else {
                stamp = now
            }
            state.tombstones[export.id] = nil
            local.append(.init(id: export.id, kind: export.kind, identity: export.identity,
                               updatedAt: stamp, deleted: false, body: export.body))
        }
        for (id, tombstone) in state.tombstones {
            if let r = remote[id], r.deleted, r.updatedAt >= tombstone.updatedAt {
                state.tombstones[id] = nil
            } else {
                local.append(tombstone)
            }
        }

        let merged = SyncedAccounts.merge(local: .init(entries: local), remote: remote).pruned(now: now)

        var apply: [SyncedAccounts.Entry] = []
        var remove: [SyncedAccounts.Entry] = []
        for entry in merged.entries where handled.contains(entry.kind) && !blocked.contains(entry.id) {
            let ours = exportByID[entry.id]
            if entry.deleted {
                guard let ours, state.held[entry.id] == nil else { continue }
                if let theirs = entry.identity, let mine = ours.identity, theirs != mine { continue }
                remove.append(entry)
            } else if remote[entry.id] == entry, !state.suppressed.contains(entry.id) {
                if ours == nil {
                    apply.append(entry)
                } else if updatesInPlace.contains(entry.kind), entry.bodyPrint != prints[entry.id] {
                    apply.append(entry)
                }
            }
        }

        for entry in local where !entry.deleted && merged[entry.id] == entry {
            state.ledger[entry.id] = .init(print: entry.bodyPrint ?? "", updatedAt: entry.updatedAt)
        }

        let sort: (SyncedAccounts.Entry, SyncedAccounts.Entry) -> Bool = { $0.id < $1.id }
        let needsUpload = merged.entries.sorted(by: sort) != remote.entries.sorted(by: sort)
        return Plan(merged: merged, apply: apply, remove: remove, blocked: blocked, state: state, needsUpload: needsUpload)
    }
}

// MARK: - Vault seam

struct VaultSnapshot {
    var accounts: SyncedAccounts
    /// What `save` needs to know the record has not changed since (the CKRecord).
    var token: AnyObject?
}

enum VaultSaveResult { case saved, conflict }

@MainActor
protocol AccountVaulting: AnyObject {
    func fetch() async throws -> VaultSnapshot
    func save(_ accounts: SyncedAccounts, over snapshot: VaultSnapshot) async throws -> VaultSaveResult
}

// MARK: - One cycle

/// Fetches the vault, plans, applies what other devices changed, and uploads what this one did.
@MainActor
final class AccountSyncCoordinator {
    private let vault: AccountVaulting
    private let kinds: [SyncedAccountKind]
    private let defaults: UserDefaults
    private let now: () -> Date
    private(set) var state: AccountSyncState
    private(set) var blocked: Set<String> = []
    /// Entries a sign-in refused, by the record they came in. Not retried until the record changes (or on relaunch).
    private var refused: [String: String] = [:]

    init(vault: AccountVaulting, kinds: [SyncedAccountKind], defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.vault = vault
        self.kinds = kinds
        self.defaults = defaults
        self.now = now
        state = defaults.data(forKey: SyncCatalog.accountStateKey)
            .flatMap { try? JSONDecoder().decode(AccountSyncState.self, from: $0) } ?? AccountSyncState()
    }

    /// True when it signed anything in or out here.
    @discardableResult
    func sync() async throws -> Bool {
        var changed = false
        for _ in 0..<3 {
            let snapshot = try await vault.fetch()
            let plan = AccountSyncPlanner.plan(
                exports: kinds.flatMap { $0.export() },
                handled: Set(kinds.map(\.kind)), updatesInPlace: Set(kinds.filter(\.updatesInPlace).map(\.kind)),
                remote: snapshot.accounts, state: state, now: now())
            state = plan.state
            blocked = plan.blocked
            save()

            for entry in plan.remove {
                guard let kind = kinds.first(where: { $0.kind == entry.kind }) else { continue }
                await kind.remove(entry)
                state.ledger[entry.id] = nil
                changed = true
            }
            for entry in plan.apply {
                guard let kind = kinds.first(where: { $0.kind == entry.kind }) else { continue }
                let record = "\(entry.updatedAt.timeIntervalSince1970)|\(entry.bodyPrint ?? "")"
                if refused[entry.id] == record { continue }
                switch await kind.adopt(entry) {
                case .adopted:
                    state.ledger[entry.id] = .init(print: entry.bodyPrint ?? "", updatedAt: entry.updatedAt)
                    state.shared.insert(entry.id)
                    refused[entry.id] = nil
                    changed = true
                case .refused:
                    refused[entry.id] = record
                    DiagLog.notice(.sync, "Sign-in from iCloud refused: \(entry.kind)")
                case .unavailable:
                    break
                }
            }
            save()

            guard plan.needsUpload else { markShared(in: plan.merged); return changed }
            if try await vault.save(plan.merged, over: snapshot) == .saved {
                markShared(in: plan.merged)
                return changed
            }
        }
        return changed
    }

    /// Whether this credential was ever uploaded to or taken from iCloud.
    func wasShared(_ id: String) -> Bool { state.shared.contains(id) }

    /// What the cloud now holds, unchanged, of what this device has is shared.
    private func markShared(in merged: SyncedAccounts) {
        for export in kinds.flatMap({ $0.export() }) {
            if let entry = merged[export.id], !entry.deleted, entry.bodyPrint == SyncedAccounts.bodyPrint(export.body) {
                state.shared.insert(export.id)
            }
        }
        save()
    }

    /// Call after signing out or removing something here. Without `everywhere` the other devices keep it.
    func signedOut(id: String, identity: String?, everywhere: Bool) {
        state.ledger[id] = nil
        state.shared.remove(id)
        if everywhere {
            state.suppressed.remove(id)
            state.tombstones[id] = .init(id: id, kind: Self.kind(of: id), identity: identity,
                                         updatedAt: now(), deleted: true, body: nil)
        } else {
            state.suppressed.insert(id)
            state.tombstones[id] = nil
        }
        save()
    }

    /// The Apple account changed: forget the old cloud's history, and keep what is here out of the new one.
    func accountChanged() {
        var held: [String: String] = [:]
        for export in kinds.flatMap({ $0.export() }) { held[export.id] = SyncedAccounts.bodyPrint(export.body) ?? "" }
        state = AccountSyncState(held: held)
        save()
    }

    func isSuppressed(_ id: String) -> Bool { state.suppressed.contains(id) }


    nonisolated static func kind(of id: String) -> String { String(id.prefix { $0 != ":" }) }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: SyncCatalog.accountStateKey) }
    }
}
