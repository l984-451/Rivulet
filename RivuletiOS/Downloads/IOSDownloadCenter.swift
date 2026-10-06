// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import Foundation
import Network
import UIKit

/// Downloads for offline playback: the records, server conversions, transfers and files.
/// Records are the source of truth; URLSession tasks are matched to them by id.
@MainActor
final class IOSDownloadCenter: ObservableObject {
    static let shared = IOSDownloadCenter()
    static let qualityKey = "downloadQuality"
    /// Original, then the converted sizes a phone can use.
    static let qualityChoices: [StreamingQuality] =
        [.original] + [8000, 4000, 2000, 1500, 720].compactMap(QualityStep.step(kbps:)).map { .step($0) }

    /// Every profile's and server's downloads; views use `visibleRecords`.
    @Published private(set) var records: [DownloadRecord] = []

    private let transfer = IOSDownloadTransfer.shared
    private let network = PlexNetworkManager.shared
    private let auth = PlexAuthManager.shared
    private let probe = URLSession(configuration: .ephemeral, delegate: PlexCertificateDelegate(), delegateQueue: nil)
    private static let directory = IOSDownloadTransfer.directory
    private static let manifestURL = directory.appending(path: "manifest.json")
    private static let removalsURL = directory.appending(path: "pending-removals.json")
    private static let serverIDKey = "downloadsServerID"

    /// A server queue item whose download is gone, deleted once that server is reachable.
    private nonisolated struct PendingRemoval: Codable, Equatable {
        var serverID: String
        var itemID: Int
    }

    /// Record id to the task carrying it; events from any other task are stale.
    private var activeTasks: [String: Int] = [:]
    /// Tasks the app cancelled; events they already posted are stale.
    private var retiredTasks = Set<Int>()
    private var pendingRemovals: [PendingRemoval] = []
    private let pathMonitor = NWPathMonitor()
    private var busy = Set<String>()
    private var authRetried = Set<String>()
    private var queueIDs: [String: Int] = [:]
    private var ticker: Task<Void, Never>?
    private var reconciled = false
    private var cancellables = Set<AnyCancellable>()
    /// The current server's machine id, kept across launches for offline use.
    private(set) var currentServerID: String? {
        didSet { UserDefaults.standard.set(currentServerID, forKey: Self.serverIDKey) }
    }

    private init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        IOSDownloadTransfer.excludeFromBackup(Self.directory)
        let present = Set((try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? [])
        let loaded = DownloadManifest.load(from: Self.manifestURL)
        let checked = loaded.reconciled(filesPresent: present)
        records = checked.records
        if checked != loaded { save() }
        currentServerID = UserDefaults.standard.string(forKey: Self.serverIDKey)
        pendingRemovals = DownloadsJSONFile.load([PendingRemoval].self, from: Self.removalsURL) ?? []
        // A delete that raced a finishing transfer leaves a file named for no record.
        let ids = Set(records.map(\.id))
        for name in present {
            let owner = String(name.prefix { $0 != "." })
            if UUID(uuidString: owner) != nil, !ids.contains(owner) { removeFile(name) }
        }

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in Task { await self?.serverChanged() } }
            .store(in: &cancellables)
        // willSet: the new URL is in place once the Task runs.
        auth.$selectedServerURL.dropFirst().removeDuplicates()
            .sink { [weak self] _ in Task { await self?.serverChanged() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in UserDefaults.standard.bool(forKey: IOSDownloadTransfer.cellularKey) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in await self?.networkChanged(away: NetworkPathMonitor.shared.isAwayPath) } }
            .store(in: &cancellables)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let away = NetworkPathMonitor.isAway(path)
            Task { @MainActor in await self?.networkChanged(away: away) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "rivulet.downloads.path"))
    }

    /// Launch: re-attach live transfers, cancel orphans, then resume everything unfinished.
    func start() {
        Task {
            // Read on main after the await: a task whose completion already ran is no longer live.
            let tasks = await transfer.allTasks().filter { $0.state == .running || $0.state == .suspended }
            let plan = DownloadRules.reconcile(records, tasks: tasks.map { ($0.taskIdentifier, $0.taskDescription) })
            for task in tasks where plan.cancel.contains(task.taskIdentifier) { retire(task) }
            for (id, taskID) in plan.attach {
                activeTasks[id] = taskID
                update(id) { $0.state = .downloading }
            }
            reconciled = true
            await refreshServerID()
            ensureTicking()
            await networkChanged(away: NetworkPathMonitor.shared.isAwayPath)
            await drainRemovals()
        }
    }

    // MARK: - Queries

    /// The current Plex Home profile, or the last one when offline.
    var currentProfileID: String? {
        let id = PlexUserProfileManager.shared.selectedUser?.id
            ?? UserDefaults.standard.object(forKey: "selectedPlexUserId") as? Int
        return id.map(String.init)
    }

    /// The current profile's downloads; all of them when there are no profiles.
    var visibleRecords: [DownloadRecord] {
        guard let profile = currentProfileID else { return records }
        return records.filter { $0.profileID == nil || $0.profileID == profile }
    }

    /// The download of `ratingKey` on `serverID`, or on the current server.
    func record(for ratingKey: String, serverID: String? = nil) -> DownloadRecord? {
        let server = serverID ?? currentServerID
        return visibleRecords.first {
            $0.ratingKey == ratingKey && (server == nil || $0.serverID.isEmpty || $0.serverID == server)
        }
    }

    func state(for ratingKey: String) -> DownloadState? { record(for: ratingKey)?.state }

    /// Bytes on disk for every download, posters and subtitles included.
    var storageUsed: Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: keys)) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0) }
    }

    /// `item`'s download on `serverID`, or on the current server, as a playback request.
    func localPlayback(for item: PlexMetadata, serverID: String? = nil) -> IOSPlexPlaybackRequest? {
        guard let key = item.ratingKey, let record = record(for: key, serverID: serverID) else { return nil }
        return localPlayback(record: record, serverItem: item)
    }

    /// A finished download as a playback request: local file, no headers, stored markers.
    /// `serverItem`'s resume point wins unless an unsent offline one is newer.
    func localPlayback(record: DownloadRecord, serverItem: PlexMetadata? = nil) -> IOSPlexPlaybackRequest? {
        guard record.state == .completed, let name = record.fileName else { return nil }
        let url = Self.directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail(record.id, "File missing")
            return nil
        }

        var meta = record.metadata
        if var media = meta.Media, let index = media.firstIndex(where: { $0.id == record.mediaID }) {
            media.insert(media.remove(at: index), at: 0)
            meta.Media = media
        }
        if let serverItem {
            let pending = IOSOfflineProgress.log.entries.first {
                $0.serverID == record.serverID && $0.profileID == currentProfileID && $0.ratingKey == record.ratingKey
            }
            meta.viewOffset = OfflineProgressLog.resumeOffsetMs(
                serverOffsetMs: serverItem.viewOffset,
                serverLastViewedAt: serverItem.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                pending: pending)
        }
        let resume = meta.resumeSeconds
        let resumes = meta.durationSeconds > 0
            ? WatchProgressPolicy.hasResumePoint(offsetSeconds: resume, runtimeSeconds: meta.durationSeconds)
            : WatchProgressPolicy.hasResumePoint(offsetSeconds: resume)
        // Progress reports go to the server only when it is the one that made the download.
        let session = record.serverID == currentServerID ? config() : nil

        var request = IOSPlexPlaybackRequest(
            item: meta,
            url: url,
            headers: [:],
            markers: (meta.Marker ?? []).sorted { ($0.startTimeOffset ?? 0) < ($1.startTimeOffset ?? 0) },
            serverURL: session?.serverURL ?? "",
            token: session?.token ?? "",
            quality: .original,
            plan: .original,
            sourceKbps: nil,
            mediaIndex: 0,
            transcodeSessionID: nil,
            measuredKbps: nil,
            measuredAt: nil,
            startTime: resumes ? resume : nil
        )
        request.localSidecars = record.subtitleFiles.map {
            AetherPlayer.SidecarSubtitle(
                url: Self.directory.appending(path: $0.fileName), name: $0.title, language: $0.language,
                isForced: $0.isForced, isHearingImpaired: false, isDefault: false, formatHint: $0.codec)
        }
        request.localArtworkURL = record.posterFileName.map { Self.directory.appending(path: $0) }
        request.downloadServerID = record.serverID
        return request
    }

    /// Keeps a download's resume point current so an offline play resumes where the last one stopped.
    func noteProgress(ratingKey: String, serverID: String?, offsetMs: Int, watched: Bool, persist: Bool) {
        guard let id = record(for: ratingKey, serverID: serverID)?.id, let index = records.firstIndex(where: { $0.id == id }) else { return }
        // Written directly: PlexMetadata's == sees only ratingKey, so `update` would skip it.
        if watched {
            records[index].metadata.viewOffset = nil
            records[index].metadata.viewCount = max(1, records[index].metadata.viewCount ?? 0)
        } else {
            records[index].metadata.viewOffset = offsetMs
        }
        if persist { save() }
    }

    // MARK: - Actions

    /// Starts a download at `quality`, or the Download Quality setting. A failed one retries.
    func download(_ item: PlexMetadata, quality: StreamingQuality? = nil) {
        guard let key = item.ratingKey, config() != nil else { return }
        if let existing = record(for: key) {
            if case .failed = existing.state { retry(recordID: existing.id) }
            return
        }
        // Auto has no meaning offline, so anything but a step is Original.
        var chosen = StreamingQuality.original
        if case .step(let step)? = quality
            ?? UserDefaults.standard.string(forKey: Self.qualityKey).flatMap(StreamingQuality.init(rawValue:)) {
            chosen = .step(step)
        }
        records.append(DownloadRecord(
            serverID: currentServerID ?? "", profileID: currentProfileID, ratingKey: key, mediaID: 0,
            quality: chosen.rawValue, state: .waitingForServer, metadata: item))
        save()
        ensureTicking()
    }

    /// Every episode of a season, started together so the session queues them at once.
    func downloadSeason(_ season: PlexMetadata, quality: StreamingQuality? = nil) async throws {
        guard let key = season.ratingKey, let (serverURL, token) = config() else { throw IOSPlexSessionError.notConfigured }
        let episodes = try await network.getChildren(serverURL: serverURL, authToken: token, ratingKey: key)
        for episode in episodes.sorted(by: { ($0.index ?? 0) < ($1.index ?? 0) }) {
            download(episode, quality: quality)
        }
    }

    func retry(recordID id: String) {
        guard let record = record(id), case .failed = record.state else { return }
        authRetried.remove(id)
        update(id) {
            $0.state = .waitingForServer
            $0.fileName = nil
            $0.completedAt = nil
        }
        ensureTicking()
    }

    /// Cancels or removes a download: its task, files, resume data, record and server queue item.
    func delete(recordID id: String) {
        guard let record = record(id) else { return }
        records.removeAll { $0.id == id }
        activeTasks[id] = nil
        save()
        removeFiles(id)
        Task {
            await transfer.cancel(recordID: id)
            removeFiles(id)
            await removeServerItem(record.queueItemID, serverID: record.serverID)
        }
    }

    func deleteAll() {
        for record in records { delete(recordID: record.id) }
    }

    // MARK: - Transfer events

    func handle(_ event: IOSDownloadTransfer.Event) {
        switch event {
        case let .progress(id, taskID, received):
            guard accepts(id, taskID, progress: true) else { return }
            activeTasks[id] = taskID
            update(id, save: false) {
                guard !$0.state.isSettled else { return }
                $0.receivedBytes = received
                $0.state = .downloading
            }

        case let .finished(id, taskID, fileName, bytes, etag):
            guard accepts(id, taskID), let record = record(id) else {
                // A deleted or superseded download's file has no owner.
                if record(id)?.fileName != fileName { removeFile(fileName) }
                return
            }
            activeTasks[id] = nil
            authRetried.remove(id)
            // PMS ignores If-Range, so a resume onto a changed file only shows here.
            if (record.expectedBytes.map { $0 != bytes } ?? false) || (record.etag != nil && etag != nil && record.etag != etag) {
                removeFile(fileName)
                return fail(id, DownloadRules.mismatchReason)
            }
            update(id) {
                $0.fileName = fileName
                $0.receivedBytes = bytes
                $0.expectedBytes = bytes
                $0.state = .completed
                $0.completedAt = Date()
                $0.queueItemID = nil
            }
            Task { await removeServerItem(record.queueItemID, serverID: record.serverID) }

        case let .rejected(id, taskID, status):
            guard accepts(id, taskID) else { return }
            activeTasks[id] = nil
            try? FileManager.default.removeItem(at: IOSDownloadTransfer.resumeDataURL(id))
            if status == 404 { forgetConversion(id) }
            if status == 401, authRetried.insert(id).inserted {
                // Resume data replays the old token; start over with the current one.
                set(id, .waitingForServer)
            } else {
                set(id, DownloadRules.state(afterRejectedStatus: status, converted: record(id)?.queueItemID != nil))
            }
            ensureTicking()

        case let .interrupted(id, taskID, state):
            guard accepts(id, taskID) else { return }
            activeTasks[id] = nil
            set(id, state)
            ensureTicking()
        }
    }

    /// Events from a retired task are stale, and so is progress from an unbound one once launch reconciled.
    private func accepts(_ id: String, _ taskID: Int, progress: Bool = false) -> Bool {
        guard record(id) != nil, !retiredTasks.contains(taskID) else { return false }
        if let bound = activeTasks[id] { return bound == taskID }
        return !(progress && reconciled)
    }

    // MARK: - Work loop

    /// Every 3 s while anything waits: conversions poll, waiting items retry, paused ones resume.
    private func ensureTicking() {
        guard reconciled, ticker == nil else { return }
        ticker = Task {
            while advanceWaiting() {
                try? await Task.sleep(for: .seconds(3))
            }
            ticker = nil
        }
    }

    /// Starts work on each record that has no transfer. False when none needs any.
    private func advanceWaiting() -> Bool {
        let pending = records.filter { !$0.state.isSettled && activeTasks[$0.id] == nil }
        for record in pending where !busy.contains(record.id) {
            Task { await advance(record.id) }
        }
        return !pending.isEmpty
    }

    /// One step for one record: plan it, poll its conversion, or start its transfer.
    private func advance(_ id: String) async {
        guard busy.insert(id).inserted else { return }
        defer { busy.remove(id) }
        guard let record = record(id), !record.state.isSettled, activeTasks[id] == nil else { return }
        guard let (serverURL, token) = config() else { return set(id, .waitingForServer) }
        if ServerLocation.classify(serverURL) == .relay {
            return record.mediaID == 0 ? fail(id, DownloadRules.relayReason) : set(id, .waitingForServer)
        }
        if currentServerID == nil { await refreshServerID() }
        guard let serverID = currentServerID else { return set(id, .waitingForServer) }
        if record.serverID.isEmpty { update(id) { $0.serverID = serverID } }
        // Another server's download waits until that server is selected again.
        guard self.record(id)?.serverID == serverID else { return set(id, .waitingForServer) }

        do {
            if record.mediaID == 0 {
                try await plan(id, serverURL: serverURL, token: token)
            }
            guard let planned = self.record(id), !planned.state.isSettled else { return }
            if planned.quality == StreamingQuality.original.rawValue {
                try await startOriginal(id, serverURL: serverURL, token: token)
            } else {
                try await advanceConversion(id, serverURL: serverURL, token: token)
            }
        } catch PlexAPIError.httpError(let status, _) {
            if status == 404 { forgetConversion(id) }
            if let reason = DownloadRules.failureReason(httpStatus: status) { fail(id, reason) } else { set(id, .waitingForServer) }
        } catch PlexAPIError.parsingError {
            fail(id, "The server sent a response Rivulet couldn't read")
        } catch {
            set(id, .waitingForServer)
        }
    }

    /// Full metadata, the version, and Original vs a conversion. Saves the poster and subtitles.
    private func plan(_ id: String, serverURL: String, token: String) async throws {
        guard let key = record(id)?.ratingKey else { return }
        let full = try await network.getFullMetadata(serverURL: serverURL, authToken: token, ratingKey: key)
        guard let record = record(id) else { return }
        let step: QualityStep? = if case .step(let step) = StreamingQuality(rawValue: record.quality) { step } else { nil }
        let chosen = VersionRanking.select(.best, in: full.Media ?? [], capKbps: step?.kbps).media.first

        switch DownloadRules.plan(step: step, media: chosen) {
        case .refused(let reason):
            update(id) { $0.metadata = full }
            return fail(id, reason)
        case .original(let partID):
            update(id) {
                $0.metadata = full
                $0.mediaID = chosen?.id ?? 0
                $0.partID = partID
                $0.quality = StreamingQuality.original.rawValue
            }
        case .converted(let step):
            update(id) {
                $0.metadata = full
                $0.mediaID = chosen?.id ?? 0
                $0.partID = chosen?.Part?.first?.id
                $0.quality = StreamingQuality.step(step).rawValue
            }
        }
        await saveExtras(id, serverURL: serverURL, token: token)
    }

    private func startOriginal(_ id: String, serverURL: String, token: String) async throws {
        guard let record = record(id),
              let part = record.metadata.Media?.first(where: { $0.id == record.mediaID })?
                .Part?.first(where: { $0.id == record.partID }),
              let key = part.key,
              let request = network.partDownloadRequest(serverURL: serverURL, authToken: token, partKey: key)
        else { return fail(id, DownloadRules.noFileReason) }
        try await startTransfer(id, request: request, fallbackSize: part.size.map(Int64.init))
    }

    /// Queues the conversion, polls it, and fetches the file once the server has it.
    private func advanceConversion(_ id: String, serverURL: String, token: String) async throws {
        guard let record = record(id), let step = QualityStep.step(kbps: Int(record.quality) ?? 0) else {
            return fail(id, DownloadRules.noFileReason)
        }
        let queueID = try await queueID(serverURL: serverURL, token: token)
        guard let itemID = record.queueItemID else {
            // An add that timed out may have queued it anyway; take that one over a second conversion.
            let queued = try await network.liveDownloadQueueItemIDs(
                serverURL: serverURL, authToken: token, queueID: queueID, ratingKey: record.ratingKey)
            let claimed = Set(records.compactMap(\.queueItemID) + pendingRemovals.map(\.itemID))
            let itemID: Int
            if let free = queued.first(where: { !claimed.contains($0) }) {
                itemID = free
            } else {
                let media = record.metadata.Media ?? []
                let index = media.count > 1 ? media.firstIndex { $0.id == record.mediaID } : nil
                itemID = try await network.addToDownloadQueue(
                    serverURL: serverURL, authToken: token, queueID: queueID,
                    ratingKey: record.ratingKey, mediaIndex: index, maxVideoBitrateKbps: step.kbps)
            }
            guard self.record(id) != nil else {
                // Deleted while the request was out.
                return await removeServerItem(itemID, serverID: record.serverID)
            }
            return update(id) {
                $0.queueItemID = itemID
                $0.state = .preparing(progress: 0)
            }
        }

        let item: PlexDownloadQueueItem
        do {
            item = try await network.downloadQueueItem(serverURL: serverURL, authToken: token, queueID: queueID, itemID: itemID)
        } catch PlexAPIError.notFound {
            forgetConversion(id)
            return fail(id, DownloadRules.conversionGoneReason)
        }
        switch DownloadRules.state(for: item) {
        case .downloading:
            if record.outputLabel == nil,
               let decision = try? await network.downloadQueueDecision(
                serverURL: serverURL, authToken: token, queueID: queueID, itemID: itemID),
               let height = decision.height {
                update(id) { $0.outputLabel = "\(height)p" }
            }
            guard let request = network.downloadQueueMediaRequest(
                serverURL: serverURL, authToken: token, queueID: queueID, itemID: itemID) else { return }
            try await startTransfer(id, request: request, fallbackSize: nil)
        case .failed(let reason):
            forgetConversion(id)
            fail(id, reason)
            await removeServerItem(itemID, serverID: record.serverID)
        case let state:
            set(id, state)
        }
    }

    /// Checks the file, space and network, then starts or resumes the background transfer.
    private func startTransfer(_ id: String, request: URLRequest, fallbackSize: Int64?) async throws {
        let cellular = UserDefaults.standard.bool(forKey: IOSDownloadTransfer.cellularKey)
        let away = NetworkPathMonitor.shared.isAwayPath
        if !cellular, away { return set(id, .waitingForNetwork) }
        var head = request
        head.httpMethod = "HEAD"
        head.timeoutInterval = 20
        let (_, response) = try await probe.data(for: head)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 503, record(id)?.queueItemID != nil { return set(id, .preparing(progress: 100)) }
        guard (200...299).contains(http.statusCode) else {
            throw PlexAPIError.httpError(statusCode: http.statusCode, data: nil)
        }
        let length = http.expectedContentLength > 0 ? http.expectedContentLength : fallbackSize
        let etag = http.value(forHTTPHeaderField: "ETag")
        if let length, !hasRoom(for: length) { return fail(id, DownloadRules.noSpaceReason) }
        guard let record = record(id), !record.state.isSettled, activeTasks[id] == nil else { return }

        // PMS ignores If-Range, so resume only onto the same file: same size and ETag.
        // Resume data also keeps its request's cellular flag, which must still work on this path.
        let resumeURL = IOSDownloadTransfer.resumeDataURL(id)
        let flagFits = DownloadRules.pathAction(
            away: away, cellularAllowed: cellular, taskAllowsCellular: record.cellularAllowed ?? false) == .run
        let resumeData = flagFits && record.expectedBytes == length && record.etag == etag
            ? try? Data(contentsOf: resumeURL) : nil
        try? FileManager.default.removeItem(at: resumeURL)
        activeTasks[id] = if let resumeData {
            transfer.resume(data: resumeData, recordID: id, expectedBytes: length)
        } else {
            transfer.start(request: request, recordID: id, expectedBytes: length, cellular: cellular)
        }
        update(id) {
            $0.etag = etag
            $0.expectedBytes = length
            if resumeData == nil {
                $0.receivedBytes = 0
                $0.cellularAllowed = cellular
            }
            $0.state = .downloading
        }
    }

    /// Foreground or a server switch: learn the server's id, and move transfers whose host is gone.
    private func serverChanged() async {
        await refreshServerID()
        if let (serverURL, _) = config(), let serverID = currentServerID {
            for task in await transfer.allTasks() {
                guard let id = task.taskDescription, record(id)?.serverID == serverID,
                      DownloadRules.hostChanged(taskURL: task.originalRequest?.url, serverURL: serverURL) else { continue }
                // Resume data is bound to the old host, so this one starts over.
                retire(task)
                activeTasks[id] = nil
                try? FileManager.default.removeItem(at: IOSDownloadTransfer.resumeDataURL(id))
                set(id, .waitingForServer)
            }
        }
        ensureTicking()
        await drainRemovals()
    }

    /// The path or the cellular setting changed: show or lift Waiting for Wi-Fi, and move
    /// transfers whose request can't use this path.
    private func networkChanged(away: Bool) async {
        guard reconciled, !activeTasks.isEmpty else { return }
        let cellular = UserDefaults.standard.bool(forKey: IOSDownloadTransfer.cellularKey)
        let tasks = await transfer.allTasks()
        for (id, taskID) in activeTasks {
            guard let record = record(id), let task = tasks.first(where: { $0.taskIdentifier == taskID }) else { continue }
            switch DownloadRules.pathAction(away: away, cellularAllowed: cellular, taskAllowsCellular: record.cellularAllowed ?? false) {
            case .run:
                if record.state == .waitingForNetwork { set(id, .downloading) }
            case .wait:
                set(id, .waitingForNetwork)
            case .stop:
                retiredTasks.insert(taskID)
                transfer.pause(task)
                activeTasks[id] = nil
                set(id, .waitingForNetwork)
            case .restart:
                retire(task)
                activeTasks[id] = nil
                try? FileManager.default.removeItem(at: IOSDownloadTransfer.resumeDataURL(id))
            }
        }
        ensureTicking()
    }

    // MARK: - Helpers

    private func config() -> (serverURL: String, token: String)? {
        guard let url = auth.selectedServerURL, let token = auth.selectedServerToken else { return nil }
        return (url, token)
    }

    private func refreshServerID() async {
        if let id = auth.selectedServer?.clientIdentifier {
            currentServerID = id
        } else if let (url, token) = config(), let id = try? await network.serverIdentity(serverURL: url, authToken: token) {
            currentServerID = id
        }
    }

    private func queueID(serverURL: String, token: String) async throws -> Int {
        if let cached = queueIDs[serverURL] { return cached }
        let id = try await network.downloadQueueID(serverURL: serverURL, authToken: token)
        queueIDs[serverURL] = id
        return id
    }

    /// Remembers the queue item so a delete made offline or on another server still reaches it.
    private func removeServerItem(_ itemID: Int?, serverID: String) async {
        guard let itemID, !serverID.isEmpty else { return }
        pendingRemovals.append(PendingRemoval(serverID: serverID, itemID: itemID))
        saveRemovals()
        await drainRemovals()
    }

    /// Deletes the current server's pending queue items; ones that fail wait for the next try.
    private func drainRemovals() async {
        guard let serverID = currentServerID, pendingRemovals.contains(where: { $0.serverID == serverID }),
              let (url, token) = config(), let queueID = try? await queueID(serverURL: url, token: token) else { return }
        for removal in pendingRemovals where removal.serverID == serverID {
            do {
                try await network.removeDownloadQueueItem(serverURL: url, authToken: token, queueID: queueID, itemID: removal.itemID)
            } catch PlexAPIError.notFound, PlexAPIError.httpError(statusCode: 404, _) {
            } catch {
                continue
            }
            pendingRemovals.removeAll { $0 == removal }
        }
        saveRemovals()
    }

    private func saveRemovals() {
        try? DownloadsJSONFile.save(pendingRemovals, to: Self.removalsURL)
    }

    /// Cancels a task the app no longer wants; anything it already posted is ignored.
    private func retire(_ task: URLSessionTask) {
        retiredTasks.insert(task.taskIdentifier)
        transfer.cancel(task)
    }

    private func removeFile(_ name: String) {
        try? FileManager.default.removeItem(at: Self.directory.appending(path: name))
    }

    /// Room for the file plus 1 GB, so a download never fills the device.
    private func hasRoom(for bytes: Int64) -> Bool {
        let values = try? Self.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return free >= bytes + 1_000_000_000
    }

    /// The poster, and for an Original its sidecar subtitles with real extensions. Failures are skipped.
    private func saveExtras(_ id: String, serverURL: String, token: String) async {
        guard let record = record(id) else { return }
        var poster: String?
        if let path = record.metadata.posterPath,
           let url = network.buildThumbnailURL(serverURL: serverURL, authToken: token, thumbPath: path, width: 600, height: 900),
           let data = await fetch(url, token: token) {
            poster = "\(id).poster.jpg"
            try? data.write(to: Self.directory.appending(path: "\(id).poster.jpg"), options: .atomic)
        }

        var subtitles: [DownloadRecord.SubtitleFile] = []
        if record.quality == StreamingQuality.original.rawValue {
            let streams = record.metadata.Media?.first { $0.id == record.mediaID }?.Part?.first?.Stream ?? []
            for (n, stream) in streams.enumerated() where stream.isSubtitle {
                guard let key = stream.key, let url = URL(string: serverURL + key),
                      let data = await fetch(url, token: token) else { continue }
                let ext = switch stream.codec?.lowercased() {
                case "subrip"?, nil: "srt"
                case "webvtt"?: "vtt"
                case let codec?: codec
                }
                let name = "\(id).sub\(n).\(ext)"
                guard (try? data.write(to: Self.directory.appending(path: name), options: .atomic)) != nil else { continue }
                subtitles.append(.init(
                    fileName: name, language: stream.languageCode ?? stream.language,
                    title: stream.displayTitle ?? stream.extendedDisplayTitle, codec: ext, isForced: stream.forced ?? false))
            }
        }
        // Deleted while these were fetched.
        guard self.record(id) != nil else { return removeFiles(id) }
        update(id) {
            $0.posterFileName = poster
            $0.subtitleFiles = subtitles
        }
    }

    /// A small authenticated GET with the token in a header, never the query.
    private func fetch(_ url: URL, token: String) async -> Data? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = components.queryItems?.filter { $0.name != "X-Plex-Token" }
        guard let clean = components.url else { return nil }
        var request = URLRequest(url: clean, timeoutInterval: 30)
        for (key, value) in network.downloadHeaders(authToken: token) { request.setValue(value, forHTTPHeaderField: key) }
        guard let (data, response) = try? await probe.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Every file a record owns is named `<id>.<something>`: media, poster, subtitles, resume data.
    private func removeFiles(_ id: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? []
        for name in names where name.hasPrefix("\(id).") {
            try? FileManager.default.removeItem(at: Self.directory.appending(path: name))
        }
    }

    private func record(_ id: String) -> DownloadRecord? {
        records.first { $0.id == id }
    }

    private func update(_ id: String, save shouldSave: Bool = true, _ change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var record = records[index]
        change(&record)
        guard record != records[index] else { return }
        records[index] = record
        if shouldSave { save() }
    }

    /// The server lost the conversion, so Retry queues a new one.
    private func forgetConversion(_ id: String) {
        update(id) { $0.queueItemID = nil }
    }

    private func set(_ id: String, _ state: DownloadState) {
        update(id) { $0.state = state }
    }

    private func fail(_ id: String, _ reason: String) {
        set(id, .failed(reason: reason))
    }

    private func save() {
        try? DownloadManifest(records: records).save(to: Self.manifestURL)
    }
}
