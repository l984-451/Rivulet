// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// How one download is fetched: the part file as is, or a server conversion.
nonisolated enum DownloadPlan: Equatable, Sendable {
    case original(partID: Int)
    case converted(QualityStep)
    case refused(String)
}

/// The download decisions that need no files, network or UI.
nonisolated enum DownloadRules {
    static let relayReason = "Downloads need your home network or a direct remote connection"
    static let remotePassReason = "Plex requires Plex Pass or Remote Watch Pass for remote downloads; download at home"
    static let noSpaceReason = "Not enough free space on this device"
    static let multiPartReason = "This version is split into parts; choose a converted quality"
    static let noFileReason = "This item has no downloadable file"
    static let conversionGoneReason = "The server no longer has this conversion"
    static let mismatchReason = "The downloaded file didn't match the server's copy"
    static let shortFileReason = "The download was cut short"

    /// Transfer errors that mean the server or the network is out of reach for now.
    static let connectivityErrorCodes: Set<Int> = [
        NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
        NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet, NSURLErrorInternationalRoamingOff,
        NSURLErrorDataNotAllowed,
    ]

    /// A step at or above the source bitrate downloads the Original instead.
    static func plan(step: QualityStep?, media: PlexMedia?) -> DownloadPlan {
        guard let media else { return .refused(noFileReason) }
        if let step, step.kbps < (media.sourceKbps ?? .max) { return .converted(step) }
        let parts = media.Part ?? []
        guard parts.count <= 1 else { return .refused(multiPartReason) }
        guard let part = parts.first, part.key != nil else { return .refused(noFileReason) }
        return .original(partID: part.id)
    }

    /// The record state a queue item maps to. `.downloading` means the file is ready to fetch.
    static func state(for item: PlexDownloadQueueItem) -> DownloadState {
        switch item.status {
        case .deciding, .processing, .unknown: .preparing(progress: item.progress ?? 0)
        case .waiting: .waitingForServer
        case .available: .downloading
        case .error: .failed(reason: item.errorText ?? "The server couldn't convert this item")
        case .expired: .failed(reason: conversionGoneReason)
        }
    }

    /// A background transfer that stopped with an error. Waiting is never a failure.
    static func state(afterTransferError error: NSError) -> DownloadState {
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled,
           error.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] != nil {
            return .paused
        }
        if error.userInfo[NSURLErrorNetworkUnavailableReasonKey] != nil { return .waitingForNetwork }
        if error.domain == NSURLErrorDomain, connectivityErrorCodes.contains(error.code) { return .waitingForServer }
        return .failed(reason: error.localizedDescription)
    }

    /// The transfer's own non-2xx answer, or 0 when the file came up short. Retryable statuses wait.
    static func state(afterRejectedStatus status: Int, converted: Bool) -> DownloadState {
        if status == 0 { return .failed(reason: shortFileReason) }
        if status == 503, converted { return .preparing(progress: 100) }
        return failureReason(httpStatus: status).map { .failed(reason: $0) } ?? .waitingForServer
    }

    /// What a bound transfer needs on this path, given the setting and the cellular flag its request carries.
    nonisolated enum PathAction: Equatable, Sendable {
        case run
        /// Waits on its own for Wi-Fi; shown as waiting.
        case wait
        /// Cancel it, keeping resume data, until Wi-Fi.
        case stop
        /// Its flags can never use this path, and resume data keeps them, so start over.
        case restart
    }

    static func pathAction(away: Bool, cellularAllowed: Bool, taskAllowsCellular: Bool) -> PathAction {
        guard away else { return .run }
        switch (cellularAllowed, taskAllowsCellular) {
        case (true, true): return .run
        case (true, false): return .restart
        case (false, true): return .stop
        case (false, false): return .wait
        }
    }

    /// The reason to show for an HTTP status, or nil when it is worth retrying later.
    static func failureReason(httpStatus status: Int) -> String? {
        switch status {
        case 401: "Plex didn't accept the sign-in; sign in again, then retry"
        case 403: remotePassReason
        case 404, 410: "The file is no longer on the server"
        case 408, 429: nil
        case 400..<500: "The server refused the download (HTTP \(status))"
        default: nil
        }
    }

    nonisolated struct Reconciliation: Equatable, Sendable {
        /// Record id to the task that carries it.
        var attach: [String: Int] = [:]
        /// Orphans, duplicates, and tasks of finished records.
        var cancel: [Int] = []
    }

    /// Matches live tasks to unfinished records by `taskDescription`; one task per record.
    static func reconcile(_ records: [DownloadRecord], tasks: [(id: Int, recordID: String?)]) -> Reconciliation {
        let open = Set(records.filter { !$0.state.isSettled }.map(\.id))
        var result = Reconciliation()
        for task in tasks.sorted(by: { $0.id < $1.id }) {
            if let recordID = task.recordID, open.contains(recordID), result.attach[recordID] == nil {
                result.attach[recordID] = task.id
            } else {
                result.cancel.append(task.id)
            }
        }
        return result
    }

    /// A task bound to another host than the current server URL; it can never finish there.
    static func hostChanged(taskURL: URL?, serverURL: String) -> Bool {
        guard let taskHost = taskURL?.host?.lowercased(), let current = URL(string: serverURL),
              let currentHost = current.host?.lowercased() else { return false }
        return taskHost != currentHost || taskURL?.port != current.port
    }
}

extension DownloadState {
    /// Completed or failed: nothing runs until the user acts.
    nonisolated var isSettled: Bool {
        switch self {
        case .completed, .failed: true
        default: false
        }
    }
}
