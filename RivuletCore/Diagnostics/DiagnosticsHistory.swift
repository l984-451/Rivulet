// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The platform-neutral sections of a diagnostics report: the persisted log, playback
// history and process state. Each app adds its own device and account sections.

import Foundation

nonisolated enum DiagnosticsHistory {
    /// JSON-safe sections keyed by name.
    static func sections() -> [String: Any] {
        let tail = PersistentLog.shared.tail()
        return [
            "log_history": [
                "previous_launch_last_state": tail.previousEnd,
                "previous_launch": tail.previous,
                "this_launch": tail.current,
            ],
            "playback_history": PlaybackHistory.shared.report(),
            "process": processState(),
        ]
    }

    static func processState() -> [String: Any] {
        let process = ProcessInfo.processInfo
        return [
            "launch_age_s": Int(-DiagLaunch.startedAt.timeIntervalSinceNow),
            "system_uptime_min": Int(process.systemUptime / 60),
            "thermal_state": ["nominal", "fair", "serious", "critical"][min(process.thermalState.rawValue, 3)],
            "low_power_mode": process.isLowPowerModeEnabled,
            "footprint_mb": footprintMB(),
        ]
    }

    /// Resident footprint, the number the jetsam limit is measured against; -1 if unreadable.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}
