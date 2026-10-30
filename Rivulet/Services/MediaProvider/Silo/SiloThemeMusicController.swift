import AVFoundation
import Foundation
import UIKit

/// The detail surface calls activate only for its selected visible title.
@MainActor
final class SiloThemeMusicController {
    static let shared = SiloThemeMusicController()

    private(set) var isOffered = false
    private(set) var setting = SiloThemeMusicSetting()
    private var identity: String?
    private var revision: UInt64?
    private var generation = UUID()
    private var audio: SiloThemeMusicAudio?
    private var selectedOwner: String?
    private var suspended = false
    private let preferences = SiloThemeMusicPreferences()
    private var backgroundObserver: NSObjectProtocol?
    private var authorityObserver: NSObjectProtocol?

    init() {
        authorityObserver = NotificationCenter.default.addObserver(
            forName: .siloAuthorityDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.authorityDidChange() }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.suspend() }
        }
    }

    private func valid(_ provider: SiloProvider) -> Bool {
        SiloSession.account?.providerID == provider.id && SiloSession.authorityRevision == provider.authorityRevision
    }

    func offersSettings(for provider: SiloProvider) -> Bool {
        isOffered && identity == provider.id && revision == provider.authorityRevision && valid(provider)
    }

    func refresh(provider: SiloProvider?) async {
        guard let provider, valid(provider) else { authorityDidChange(); return }
        if identity == provider.id && revision == provider.authorityRevision { return }
        authorityDidChange()
        let capture = generation
        let offered = try? await SiloThemeMusicAPI(client: provider.client).isOffered()
        guard capture == generation, valid(provider) else { return }
        isOffered = offered == true
        identity = provider.id
        revision = provider.authorityRevision
        if isOffered, let account = SiloSession.account { setting = preferences.read(account: account) }
    }

    func setEnabled(_ value: Bool, provider: SiloProvider) {
        guard offersSettings(for: provider), let account = SiloSession.account else { return }
        setting.enabled = value
        preferences.write(setting, account: account)
        if !value { stopPlayback() }
    }

    func setLoop(_ value: Bool, provider: SiloProvider) {
        guard offersSettings(for: provider), let account = SiloSession.account else { return }
        setting.loop = value
        preferences.write(setting, account: account)
        audio?.loop = value
    }

    func activate(ownerID: String, provider: SiloProvider) async {
        if selectedOwner == ownerID, audio != nil, !suspended, valid(provider) { return }
        stopPlayback()
        guard isOffered, setting.enabled, !suspended, identity == provider.id,
              revision == provider.authorityRevision, valid(provider),
              !AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint else { return }
        selectedOwner = ownerID
        let capture = generation
        let api = SiloThemeMusicAPI(client: provider.client)
        guard let selection = try? await api.firstTheme(for: ownerID),
              capture == generation, selectedOwner == ownerID, !suspended, valid(provider) else { return }
        guard let grant = try? await api.grant(ownerID: selection.ownerID, themeID: selection.themeID),
              capture == generation, selectedOwner == ownerID, !suspended, valid(provider) else { return }
        let output = SiloThemeMusicAudio(grant: grant, loop: setting.loop)
        audio = output
        output.onFailure = { [weak self, weak output] in
            guard let self, self.audio === output else { return }
            self.stopPlayback()
        }
        await output.start()
        guard capture == generation, selectedOwner == ownerID, !suspended, valid(provider) else {
            if audio === output { stopPlayback() }
            else { output.stop() }
            return
        }
    }

    /// Call before video or trailer playback and during unresolved navigation.
    func suspend() { suspended = true; stopPlayback() }
    func resume() { suspended = false }
    /// Clear authority and local state after sign-out or a profile/server switch.
    func authorityDidChange() {
        stopPlayback()
        isOffered = false
        setting = SiloThemeMusicSetting()
        identity = nil
        revision = nil
    }
    /// Stop the selected title on title change or detail dismissal.
    func stop() { stopPlayback() }
    private func stopPlayback() {
        generation = UUID()
        selectedOwner = nil
        audio?.stop()
        audio = nil
    }
}
