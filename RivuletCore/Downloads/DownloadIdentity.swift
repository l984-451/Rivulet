// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// How downloads name a server. Plex servers are keyed by machine id, which survives a URL change;
/// the registry's own id for the selected server can be a hash of its URL.
nonisolated enum DownloadIdentity {
    static func plexProviderID(machineID: String?) -> String { "plex:" + (machineID ?? "") }

    /// The record key for `ref`, nil for a Plex ref no signed-in server owns.
    static func providerID(for ref: MediaItemRef, selectedPlexMachineID: String?) -> String? {
        switch ref.plexRoute {
        case .selected?: plexProviderID(machineID: selectedPlexMachineID)
        case .extra(let machineID)?: plexProviderID(machineID: machineID)
        case .unknown?: nil
        case nil: ref.providerID
        }
    }

    /// Whether a record on `recordProviderID` belongs to a lookup on `key`. A bare "plex:" is a Plex
    /// server not yet known, so it fits any Plex server.
    static func matches(_ recordProviderID: String, _ key: String) -> Bool {
        if recordProviderID == key { return true }
        return recordProviderID.hasPrefix("plex:") && key.hasPrefix("plex:") && (recordProviderID == "plex:" || key == "plex:")
    }

    /// The Plex download key a progress report or offline entry is filed under.
    static func reportingKey(isLocal: Bool, downloadProviderID: String?, itemServerID: String?,
                             currentMachineID: String?) -> String? {
        let current = currentMachineID.flatMap { $0.isEmpty ? nil : $0 }
        let machineID: String?
        if isLocal, let downloadProviderID {
            machineID = plexMachineID(of: downloadProviderID) ?? current
        } else {
            machineID = itemServerID ?? current
        }
        return machineID.map { plexProviderID(machineID: $0) }
    }

    /// The machine id inside a Plex download key; nil when empty or not Plex.
    static func plexMachineID(of providerID: String) -> String? {
        guard providerID.hasPrefix("plex:") else { return nil }
        let id = String(providerID.dropFirst("plex:".count))
        return id.isEmpty ? nil : id
    }
}
