// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchTogetherCoordinator.swift
//  Rivulet
//
//  Connects the room to the tvOS player: which view model follows it, what to
//  present when the room's title changes, and when this device steps away.
//

import Combine
import OpenWatchParty
import UIKit

@MainActor
final class WatchTogetherCoordinator {
    static let shared = WatchTogetherCoordinator()

    let session = WatchTogetherSession.shared
    private weak var viewModel: UniversalPlayerViewModel?
    private var adapter: WatchTogetherPlayerAdapter?
    private var item: WatchTogetherItem?
    private var isAway = false
    private var playerCancellables = Set<AnyCancellable>()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        session.resolver = { try await WatchTogetherResolver.candidates(for: $0) }
        session.onOpen = { [weak self] item, position in self?.open(item, at: position) }
        session.onMismatch = { [weak self] delta in self?.askAboutMismatch(delta) }
        session.onNoCopy = { [weak self] title in self?.reportNoCopy(title) }
        session.onRoleChange = { [weak self] in self?.roleChanged() }
        session.notices
            .sink { [weak self] notice in self?.viewModel?.showWatchTogetherNotice(notice) }
            .store(in: &cancellables)
        // The room stops waiting for a device off screen, and it catches up on return.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.stepAway() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.stepBack() }
            .store(in: &cancellables)
    }

    private static var client: String {
        "Rivulet/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"
    }

    private static var displayName: String {
        let profile = PlexUserProfileManager.shared.selectedUser?.displayName
        return profile ?? PlexAuthManager.shared.username ?? UIDevice.current.name
    }

    // MARK: - Starting

    /// Opens a room on what `viewModel` is playing, paused until someone presses play.
    func host(from viewModel: UniversalPlayerViewModel) async throws {
        try await session.create(name: Self.displayName, client: Self.client)
        do {
            try await share(viewModel, holdPaused: true)
        } catch {
            session.leave()
            throw error
        }
    }

    func join(code: String) async throws {
        try await session.join(code: code, name: Self.displayName, client: Self.client)
    }

    private func share(_ viewModel: UniversalPlayerViewModel, holdPaused: Bool) async throws {
        let (media, item) = try await describe(viewModel)
        try session.share(media, item: item, at: holdPaused ? viewModel.currentTime : 0, holdPaused: holdPaused)
        bind(viewModel, item: item)
    }

    private func describe(_ viewModel: UniversalPlayerViewModel) async throws -> (Media, WatchTogetherItem) {
        let ref: MediaItemRef
        if case .provider(let playback) = viewModel.source {
            ref = playback.item.ref
        } else {
            let url = viewModel.serverURL
            guard let ratingKey = viewModel.metadata.ratingKey,
                  let provider = WatchTogetherResolver.providers.first(where: { ($0 as? PlexProvider)?.serverURL == url })
                    ?? MediaProviderRegistry.shared.plexProvider
            else { throw PartyError(.invalidMessage) }
            ref = MediaItemRef(providerID: provider.id, itemID: ratingKey)
        }
        let media = try await WatchTogetherResolver.describe(ref, durationMs: Int64(max(viewModel.duration, 1) * 1000))
        return (media, WatchTogetherItem(providerID: ref.providerID, itemID: ref.itemID, sourceID: viewModel.playingMediaID))
    }

    private func bind(_ viewModel: UniversalPlayerViewModel, item: WatchTogetherItem) {
        self.adapter?.stopTrimming()
        let adapter = WatchTogetherPlayerAdapter(player: viewModel)
        self.viewModel = viewModel
        self.adapter = adapter
        self.item = item
        isAway = false
        session.attach(adapter, item: item)
        adapter.startTrimming { [weak self, weak adapter] in
            adapter.flatMap { self?.session.drift(of: $0) }
        }
        playerCancellables = []
        viewModel.$itemGeneration.dropFirst()
            .sink { [weak self, weak viewModel] _ in
                guard let self, let viewModel else { return }
                // @Published fires before the new value lands; a hop reads the new item.
                self.session.detach()
                Task { @MainActor in await self.itemChanged(viewModel) }
            }
            .store(in: &playerCancellables)
    }

    /// The host moved to another title (Up Next, a playlist): the room follows.
    private func itemChanged(_ viewModel: UniversalPlayerViewModel) async {
        guard self.viewModel === viewModel, session.isActive, session.isHost else { return }
        try? await share(viewModel, holdPaused: false)
    }

    /// The sidebar's Watch Together row: asks for a code, then joins.
    func presentJoin(from presenter: UIViewController) {
        let entry = TextEntryViewController(
            title: String(localized: "Join a Room"),
            message: String(localized: "Enter the code from the person hosting and select Continue."),
            fieldName: String(localized: "Room Code"),
            initialText: "",
            submitTitle: String(localized: "Continue"),
            allowsEmpty: false,
            onCommit: { [weak self] code in
                Task { @MainActor in
                    do {
                        try await self?.join(code: code)
                    } catch {
                        self?.reportJoinFailure(error)
                    }
                }
            })
        presenter.present(entry, animated: true)
    }

    private func reportJoinFailure(_ error: Error) {
        let message = switch WatchTogetherSession.failure(for: error) {
        case .roomNotFound: String(localized: "No room has that code. Rooms end when everyone leaves.")
        case .roomFull: String(localized: "That room is full or locked.")
        case .invalidCode: String(localized: "Room codes have 6 letters and numbers.")
        case .unavailable, .unreachable: String(localized: "Couldn't reach Watch Together. Check your connection and try again.")
        case .other: String(localized: "Couldn't join that room.")
        }
        let popup = ConfirmationPopupViewController(
            title: String(localized: "Couldn't Join"), message: message,
            confirmTitle: String(localized: "OK"), cancelTitle: nil, onConfirm: {})
        Self.topViewController?.present(popup, animated: true)
    }

    // MARK: - Presses

    /// True when `viewModel` follows a room, which takes the press instead of the player.
    func play(from viewModel: UniversalPlayerViewModel) -> Bool { follows(viewModel) && session.requestPlay() }
    func pause(from viewModel: UniversalPlayerViewModel) -> Bool { follows(viewModel) && session.requestPause() }
    func seek(to time: TimeInterval, from viewModel: UniversalPlayerViewModel) -> Bool {
        follows(viewModel) && session.requestSeek(to: time)
    }

    private func follows(_ viewModel: UniversalPlayerViewModel) -> Bool {
        self.viewModel === viewModel && session.isActive && !isAway
    }

    /// What plays next is the host's call.
    func blocksLocalAdvance(_ viewModel: UniversalPlayerViewModel) -> Bool {
        follows(viewModel) && session.isGuest
    }

    // MARK: - Opening the room's title

    /// ponytail: a guest re-presents the player between episodes; the view model's
    /// in-place swap would keep the screen up if the flash ever bothers anyone.
    private func open(_ item: WatchTogetherItem, at position: TimeInterval?) {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.providerID) else { return }
        let ref = MediaItemRef(providerID: item.providerID, itemID: item.itemID)
        // Leaving the old player must not read as leaving the room.
        adapter?.stopTrimming()
        viewModel = nil
        adapter = nil
        session.detach()
        Task { @MainActor in
            guard let detail = try? await provider.fullDetail(for: ref),
                  let root = Self.rootViewController else { return }
            let present = {
                ProviderPlayer.play(detail.item, fromBeginning: true, sourceID: item.sourceID, explicitStartOffset: position,
                                    configure: { [weak self] viewModel in self?.bind(viewModel, item: item) },
                                    from: root, onDismiss: nil)
            }
            if root.presentedViewController != nil {
                root.dismiss(animated: false, completion: present)
            } else {
                present()
            }
        }
    }

    private func askAboutMismatch(_ delta: TimeInterval) {
        let seconds = Int(abs(delta).rounded())
        let message = delta > 0
            ? String(localized: "Your copy is \(seconds) seconds longer than the room's, so it may not line up.")
            : String(localized: "Your copy is \(seconds) seconds shorter than the room's, so it may not line up.")
        let popup = ConfirmationPopupViewController(
            title: String(localized: "Different Version"), message: message,
            confirmTitle: String(localized: "Play Anyway"), cancelTitle: String(localized: "Sit This One Out"),
            onConfirm: { [weak self] in self?.session.answerMismatch(accept: true) },
            onCancel: { [weak self] in self?.session.answerMismatch(accept: false) })
        Self.topViewController?.present(popup, animated: true)
    }

    private func reportNoCopy(_ title: String) {
        let popup = ConfirmationPopupViewController(
            title: String(localized: "Not in Your Library"),
            message: String(localized: "None of your servers have \(title)."),
            confirmTitle: String(localized: "Leave Room"), cancelTitle: String(localized: "Stay"),
            onConfirm: { [weak self] in self?.session.leave() })
        Self.topViewController?.present(popup, animated: true)
    }

    // MARK: - Stepping away

    private func stepAway() {
        guard session.isActive, viewModel != nil, !isAway else { return }
        isAway = true
        session.detach()
    }

    private func stepBack() {
        guard isAway else { return }
        isAway = false
        if session.isActive, let adapter, let item { session.attach(adapter, item: item) }
    }

    /// Menu out of the player leaves the room; the others carry on.
    func playerClosed(_ viewModel: UniversalPlayerViewModel) {
        guard self.viewModel === viewModel else { return }
        adapter?.stopTrimming()
        self.viewModel = nil
        adapter = nil
        item = nil
        playerCancellables = []
        session.leave()
    }

    /// A guest parked at the end waits for the host; once it isn't a guest it finishes normally.
    private func roleChanged() {
        if !session.isActive { adapter?.stopTrimming() }
        guard !session.isGuest else { return }
        viewModel?.finishParkedPlayback()
    }

    #if DEBUG
    var debugStatus: String {
        guard let viewModel else { return "no player, members=\(session.members.map(\.name))" }
        let local = viewModel.syncPosition
        let room = session.roomPosition
        let drift = room.map { String(format: "%+.0fms", (local - $0) * 1000) } ?? "?"
        return String(format: "local=%.2f room=%@ drift=%@ intends=%d buffering=%d rate=%.3f accuracy=%lldms members=%@",
                      local, room.map { String(format: "%.2f", $0) } ?? "?", drift,
                      viewModel.syncIntendsToPlay ? 1 : 0, viewModel.isBuffering ? 1 : 0,
                      viewModel.debugRate, adapter?.seekAccuracyMs ?? 0,
                      session.members.map { "\($0.name):\($0.status)" }.joined(separator: ","))
    }
    #endif

    // MARK: - Screens

    private static var rootViewController: UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { return nil }
        return window.rootViewController
    }

    private static var topViewController: UIViewController? {
        rootViewController?.topmostPresented
    }
}

#if DEBUG
// Field-test hooks: RIVULET_OWP_RELAY names a relay, RIVULET_WT_HOST=1 opens a room on
// the first title that plays, RIVULET_WT_JOIN=<code> joins at launch. Both log the drift.
extension WatchTogetherCoordinator {
    func debugHostIfAsked(_ viewModel: UniversalPlayerViewModel) {
        guard ProcessInfo.processInfo.environment["RIVULET_WT_HOST"] == "1", !session.isActive else { return }
        Task {
            do {
                try await host(from: viewModel)
                NSLog("[WatchTogether] %@", "hosting \(session.code ?? "?")")
                debugLogDrift()
                viewModel.showControlsTemporarily()
                viewModel.enterControlsFocus()
                try? await Task.sleep(for: .seconds(1))
                PlayerContainerViewController.debugCurrent?.debugPresentPane("watchTogether")
            } catch {
                NSLog("[WatchTogether] %@", "host failed: \(error)")
            }
        }
    }

    func debugJoinIfAsked() {
        guard let code = ProcessInfo.processInfo.environment["RIVULET_WT_JOIN"] else { return }
        Task {
            try? await Task.sleep(for: .seconds(8))
            do {
                try await join(code: code)
                NSLog("[WatchTogether] %@", "joined \(session.code ?? "?")")
                debugLogDrift()
            } catch {
                NSLog("[WatchTogether] %@", "join failed: \(error)")
            }
        }
    }

    private func debugLogDrift() {
        Task {
            while session.isActive {
                NSLog("[WatchTogether] %@", "\(debugStatus)")
                try? await Task.sleep(for: .seconds(1))
            }
            NSLog("[WatchTogether] %@", "ended")
        }
    }
}
#endif
