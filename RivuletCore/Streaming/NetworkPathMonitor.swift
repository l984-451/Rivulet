// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Network

/// The device's network path. Cellular, a personal hotspot and Low Data Mode count as Away.
nonisolated final class NetworkPathMonitor: Sendable {
    static let shared = NetworkPathMonitor()
    private let monitor = NWPathMonitor()

    private init() {
        monitor.start(queue: DispatchQueue(label: "rivulet.network-path"))
    }

    var isAwayPath: Bool { Self.isAway(monitor.currentPath) }

    /// The interface in use, for diagnostics: ethernet, wifi, cellular, other, offline, or unknown
    /// before the monitor's first update.
    var interfaceKind: String {
        let path = monitor.currentPath
        if path.availableInterfaces.isEmpty { return path.status == .satisfied ? "other" : "unknown" }
        guard path.status == .satisfied else { return "offline" }
        let kinds: [(NWInterface.InterfaceType, String)] = [(.wiredEthernet, "ethernet"), (.wifi, "wifi"), (.cellular, "cellular")]
        return kinds.first { path.usesInterfaceType($0.0) }?.1 ?? "other"
    }

    static func isAway(_ path: NWPath) -> Bool {
        path.usesInterfaceType(.cellular) || path.isExpensive || path.isConstrained
    }
}

extension StreamingQuality {
    /// Home: a local server address on a path that is not cellular, expensive or constrained.
    nonisolated static func isHome(serverURL: String) -> Bool {
        ServerLocation.classify(serverURL) == .local && !NetworkPathMonitor.shared.isAwayPath
    }
}
