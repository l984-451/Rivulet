// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The one background URLSession for downloads. Nonisolated so the finished
/// file is moved inside the delegate callback, before the system deletes it.
nonisolated final class IOSDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = IOSDownloadTransfer()
    static let sessionIdentifier = "com.gstudios.rivulet.downloads"
    static let cellularKey = "downloadOverCellular"
    static let directory = URL.applicationSupportDirectory.appending(path: "Downloads", directoryHint: .isDirectory)

    static func resumeDataURL(_ recordID: String) -> URL {
        directory.appending(path: "\(recordID).resume")
    }

    /// Delivered to `IOSDownloadCenter` on the main queue, in order.
    enum Event: Sendable {
        case progress(recordID: String, taskID: Int, received: Int64)
        case finished(recordID: String, taskID: Int, fileName: String, bytes: Int64, etag: String?)
        /// A non-2xx body, or 0 when the file is shorter than the response said.
        case rejected(recordID: String, taskID: Int, status: Int)
        case interrupted(recordID: String, taskID: Int, state: DownloadState)
    }

    private(set) var session: URLSession!
    private let trust = PlexCertificateDelegate()
    private let lock = NSLock()
    private var cancelledByApp = Set<Int>()
    /// Touched only on the serial delegate queue.
    private var lastProgress: [Int: Date] = [:]

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 2
        // Open here; each request carries the Download over Cellular setting.
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "rivulet.downloads"
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    // MARK: - Control

    /// Starts a fresh transfer; the token travels in the request's headers only.
    func start(request: URLRequest, recordID: String, expectedBytes: Int64?, cellular: Bool) -> Int {
        var request = request
        request.allowsCellularAccess = cellular
        request.allowsExpensiveNetworkAccess = cellular
        request.allowsConstrainedNetworkAccess = cellular
        return launch(session.downloadTask(with: request), recordID: recordID, expectedBytes: expectedBytes)
    }

    func resume(data: Data, recordID: String, expectedBytes: Int64?) -> Int {
        launch(session.downloadTask(withResumeData: data), recordID: recordID, expectedBytes: expectedBytes)
    }

    func allTasks() async -> [URLSessionTask] {
        await session.allTasks
    }

    /// Cancels without reporting back: the caller already knows.
    func cancel(_ task: URLSessionTask) {
        lock.withLock { _ = cancelledByApp.insert(task.taskIdentifier) }
        task.cancel()
    }

    /// Cancels without reporting back, saving resume data for a later start.
    func pause(_ task: URLSessionTask) {
        guard let download = task as? URLSessionDownloadTask, let recordID = task.taskDescription else { return cancel(task) }
        lock.withLock { _ = cancelledByApp.insert(task.taskIdentifier) }
        download.cancel { data in
            guard let data else { return }
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try? data.write(to: Self.resumeDataURL(recordID), options: .atomic)
        }
    }

    func cancel(recordID: String) async {
        for task in await allTasks() where task.taskDescription == recordID { cancel(task) }
    }

    private func launch(_ task: URLSessionDownloadTask, recordID: String, expectedBytes: Int64?) -> Int {
        task.taskDescription = recordID
        if let expectedBytes { task.countOfBytesClientExpectsToReceive = expectedBytes + 16_384 }
        task.resume()
        return task.taskIdentifier
    }

    private func send(_ event: Event) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { IOSDownloadCenter.shared.handle(event) }
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let recordID = downloadTask.taskDescription,
              !lock.withLock({ cancelledByApp.contains(downloadTask.taskIdentifier) }) else { return }
        let now = Date()
        if let last = lastProgress[downloadTask.taskIdentifier], now.timeIntervalSince(last) < 0.5 { return }
        lastProgress[downloadTask.taskIdentifier] = now
        send(.progress(recordID: recordID, taskID: downloadTask.taskIdentifier, received: totalBytesWritten))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let taskID = downloadTask.taskIdentifier
        guard let recordID = downloadTask.taskDescription,
              !lock.withLock({ cancelledByApp.contains(taskID) }) else { return }
        // An error body also arrives as a finished file.
        guard let http = downloadTask.response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            return send(.rejected(recordID: recordID, taskID: taskID, status: status))
        }
        let bytes = Int64((try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
        if let total = Self.totalLength(http), total != bytes {
            return send(.rejected(recordID: recordID, taskID: taskID, status: 0))
        }

        let name = "\(recordID).\(Self.fileExtension(http, task: downloadTask))"
        let destination = Self.directory.appending(path: name)
        let files = FileManager.default
        do {
            try files.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            // A repeated callback for one task must not fail on the first copy.
            try? files.removeItem(at: destination)
            try files.moveItem(at: location, to: destination)
        } catch {
            let state = DownloadState.failed(reason: "Couldn't save the file: \(error.localizedDescription)")
            return send(.interrupted(recordID: recordID, taskID: taskID, state: state))
        }
        Self.excludeFromBackup(destination)
        Self.excludeFromBackup(Self.directory)
        try? files.removeItem(at: Self.resumeDataURL(recordID))
        send(.finished(recordID: recordID, taskID: taskID, fileName: name, bytes: bytes,
                       etag: http.value(forHTTPHeaderField: "ETag")))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lastProgress[task.taskIdentifier] = nil
        let byApp = lock.withLock { cancelledByApp.remove(task.taskIdentifier) != nil }
        guard let error = error as NSError?, !byApp, let recordID = task.taskDescription else { return }
        if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try? data.write(to: Self.resumeDataURL(recordID), options: .atomic)
        }
        send(.interrupted(recordID: recordID, taskID: task.taskIdentifier,
                          state: DownloadRules.state(afterTransferError: error)))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Queued after the events above, so the manifest is saved first.
        DispatchQueue.main.async { MainActor.assumeIsolated { IOSAppDelegate.backgroundEventsFinished() } }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        trust.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    // MARK: - Files

    /// The full size the response promised: Content-Range's total, else Content-Length.
    private static func totalLength(_ http: HTTPURLResponse) -> Int64? {
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            return total
        }
        return http.statusCode == 200 && http.expectedContentLength > 0 ? http.expectedContentLength : nil
    }

    /// Plex names the file in Content-Disposition; a conversion is an MP4.
    private static func fileExtension(_ http: HTTPURLResponse, task: URLSessionTask) -> String {
        let candidates = [http.suggestedFilename, task.originalRequest?.url?.lastPathComponent]
        let ext = candidates.lazy.compactMap { $0.map { ($0 as NSString).pathExtension.lowercased() } }
            .first { !$0.isEmpty && $0.count <= 4 }
        return ext ?? "mp4"
    }

    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
