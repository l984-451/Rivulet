// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import UIKit

extension SettingsContent {
    private static var siloDraft: AddSourceDraft?
    private static var siloProfileList: [SiloProfile] = []
    private static var siloPendingProfile: SiloProfile?
    private static var siloPIN = ""
    private static var siloFlowID = UUID()
    private static var siloBusy = false
    private static var siloLoadedProfiles = false

    /// Called only on entry to the complete flow, not on its profile/PIN pushes.
    static func beginSiloFlow() {
        cancelSiloFlow()
        siloDraft = AddSourceDraft()
    }

    /// Settings owns the lifetime of passwords and PINs. Invalidate the session
    /// operation too: a late sign-in/profile response must not commit offscreen.
    static func cancelSiloFlow() {
        siloFlowID = UUID()
        siloDraft?.password = ""
        siloDraft = nil
        siloPIN = ""
        siloPendingProfile = nil
        siloProfileList = []
        siloLoadedProfiles = false
        siloBusy = false
        SiloSession.cancelPendingSignIn()
    }

    /// A Menu pop within the flow cancels page-owned work without discarding
    /// the staged account needed by the profile page below the PIN page.
    static func leaveSiloPage(_ page: SettingsPage) {
        siloFlowID = UUID()
        siloBusy = false
        siloDraft?.status = .idle
        if page == .siloProfilePIN { siloPIN = "" }
        SiloSession.cancelProfileSelection()
    }

    static var silo: [SettingsRowItem] {
        if let account = SiloSession.account {
            let provider = SiloSession.storedProvider()
            return [
                SettingsRowItem(id: "siloServerInfo", title: "Server", kind: .info(value: { account.serverName })),
                SettingsRowItem(id: "siloAddressInfo", title: "Address", kind: .info(value: { account.serverURL.absoluteString })),
                serverLibrariesToggle(id: "siloLibraries", providerID: account.providerID),
                SettingsRowItem(id: "siloUserInfo", title: "User", kind: .info(value: { account.userName })),
                SettingsRowItem(id: "siloProfiles", title: siloBusy ? "Loading Profiles…" : "Profile",
                                kind: .action(destructive: false, handler: { vc in
                    loadSiloProfiles(on: vc, push: true)
                }), isEnabled: { !siloBusy }, isBusy: { siloBusy }),
                SettingsRowItem(id: "siloProfileInfo", title: "Selected Profile", kind: .info(value: { account.profileName })),
                siloSignOutRow
            ] + (provider.map { SiloPlaybackSettingsContent.rows(provider: $0, account: account) } ?? [])
        }
        if SiloSession.hasPendingSignIn {
            return [SettingsRowItem(id: "siloProfiles", title: "Choose Profile", kind: .navigation(.siloProfiles)), siloSignOutRow]
        }
        guard let draft = siloDraft else { return [] }
        return siloSteps(draft).map(\.row) + [
            SettingsRowItem(id: "siloDeviceSignIn", title: "Sign In with Phone",
                            kind: .action(destructive: false, handler: { vc in startSiloDeviceSignIn(draft, on: vc) }),
                            isEnabled: { !siloBusy }),
            SettingsRowItem(id: "siloSignIn", title: siloBusy ? "Signing In…" : "Sign In",
                            kind: .action(destructive: false, handler: { vc in signInSilo(draft, on: vc) }),
                            isEnabled: { !siloBusy }, isBusy: { siloBusy })
        ]
    }

    static var siloProfiles: [SettingsRowItem] {
        var rows = siloProfileList.map { profile in
            SettingsRowItem(id: "siloProfile_\(profile.id)", title: profile.name,
                            kind: .selectable(isSelected: { SiloSession.account?.profileID == profile.id },
                                              value: { profile.hasPIN ? "PIN Required" : nil }, handler: { vc in
                guard !siloBusy else { return }
                if profile.hasPIN {
                    siloPendingProfile = profile
                    siloPIN = ""
                    (vc as? SettingsPageViewController)?.onPush?(.siloProfilePIN)
                } else {
                    selectSiloProfile(profile, pin: nil, on: vc)
                }
            }), isEnabled: { !siloBusy }, isBusy: { siloBusy && siloPendingProfile?.id == profile.id })
        }
        if siloLoadedProfiles && siloProfileList.isEmpty {
            rows.append(SettingsRowItem(id: "siloNoProfiles", title: "No household profiles are available.", kind: .info(value: { "" })))
        }
        rows.append(SettingsRowItem(id: "siloProfiles", title: siloBusy ? "Loading…" : "Reload Profiles",
                                    kind: .action(destructive: false, handler: { vc in loadSiloProfiles(on: vc, push: false) }),
                                    isEnabled: { !siloBusy }, isBusy: { siloBusy }))
        rows.append(siloSignOutRow)
        return rows
    }

    static var siloProfilePIN: [SettingsRowItem] {
        guard let profile = siloPendingProfile else { return [] }
        return [
            SettingsRowItem(id: "siloPINProfile", title: "Profile", kind: .info(value: { profile.name })),
            EntryStep(id: "siloProfilePIN", title: "Profile PIN",
                      message: "Enter the PIN for \(profile.name). Silo limits incorrect attempts; each press of Unlock checks the PIN once.",
                      placeholder: "Required", keyboard: .asciiCapable, contentType: .password, isSecure: true,
                      value: { siloPIN }, set: {
                          siloPIN = $0
                          siloFlowID = UUID()
                          siloBusy = false
                          SiloSession.cancelProfileSelection()
                      }).row,
            SettingsRowItem(id: "siloUnlock", title: siloBusy ? "Unlocking…" : "Unlock",
                            kind: .action(destructive: false, handler: { vc in
                guard !siloPIN.isEmpty else {
                    siloFailure(on: vc, title: "Couldn't Unlock Profile", error: SiloSignInError.pinRequired)
                    return
                }
                let pin = siloPIN
                siloPIN = ""
                selectSiloProfile(profile, pin: pin, on: vc)
            }), isEnabled: { !siloBusy }, isBusy: { siloBusy })
        ]
    }

    private static var siloSignOutRow: SettingsRowItem {
        SettingsRowItem(id: "siloSignOut", title: "Sign Out", kind: .action(destructive: true, handler: { vc in
            cancelSiloFlow()
            let flow = siloFlowID
            Task { @MainActor in
                await SiloSession.signOut()
                guard flow == siloFlowID else { return }
                siloDraft = AddSourceDraft()
                let page = vc as? SettingsPageViewController
                if page?.page == .silo { page?.reloadRows() }
                else if page?.page == .siloProfilePIN { page?.onPopTwo?() }
                else { page?.onPop?() }
            }
        }))
    }

    private static func siloSteps(_ draft: AddSourceDraft) -> [EntryStep] {
        [
            EntryStep(id: "siloURL", title: "Server Address",
                      message: "Enter Silo's web address, including any reverse-proxy path, for example https://media.example.com/silo. Do not use the Jellyfin compatibility port.",
                      placeholder: "Required", keyboard: .URL, contentType: .URL,
                      value: { draft.serverURL }, set: { draft.serverURL = $0; invalidateSiloInput(draft) }),
            EntryStep(id: "siloUsername", title: "Username",
                      message: "Enter your Silo account username or email address.",
                      placeholder: "Required", keyboard: .asciiCapable, contentType: .username,
                      value: { draft.username }, set: { draft.username = $0; invalidateSiloInput(draft) }),
            EntryStep(id: "siloPassword", title: "Password", message: "Enter your Silo account password.",
                      placeholder: "Required", keyboard: .asciiCapable, contentType: .password, isSecure: true,
                      value: { draft.password }, set: { draft.password = $0; invalidateSiloInput(draft) })
        ]
    }

    private static func invalidateSiloInput(_ draft: AddSourceDraft) {
        siloFlowID = UUID()
        siloBusy = false
        draft.status = .idle
        SiloSession.cancelPendingSignIn()
    }

    private static func signInSilo(_ draft: AddSourceDraft, on vc: UIViewController) {
        guard !siloBusy else { return }
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        var address = draft.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.contains("://") { address = "http://" + address }
        guard let url = URL(string: address), let host = url.host, !host.isEmpty, !username.isEmpty, !draft.password.isEmpty else {
            siloFailure(on: vc, title: "Couldn't Sign In", message: "Enter your Silo web address, username, and password.")
            return
        }
        let password = draft.password
        draft.password = ""
        let flow = siloFlowID
        siloBusy = true
        draft.status = .checking
        let page = vc as? SettingsPageViewController
        page?.reloadRows()
        Task { @MainActor in
            do {
                let profiles = try await SiloSession.signIn(serverURL: url, username: username, password: password)
                guard flow == siloFlowID, siloDraft === draft else { return }
                siloProfileList = profiles
                siloLoadedProfiles = true
                siloBusy = false
                draft.status = .idle
                page?.reloadRows()
                page?.onPush?(.siloProfiles)
            } catch {
                guard flow == siloFlowID, !(error is CancellationError) else { return }
                siloBusy = false
                draft.status = .idle
                siloFailure(on: vc, title: "Couldn't Sign In", error: error)
            }
        }
    }

    private static func startSiloDeviceSignIn(_ draft: AddSourceDraft, on vc: UIViewController) {
        guard !siloBusy else { return }
        var address = draft.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.contains("://") { address = "http://" + address }
        guard let url = URL(string: address), let host = url.host, !host.isEmpty else {
            siloFailure(on: vc, title: "Couldn't Start Phone Sign In", message: "Enter your Silo web address first.")
            return
        }
        draft.password = ""
        let flow = siloFlowID
        let signIn = SiloDeviceSignInViewController(serverURL: url)
        signIn.onApproved = { profiles in
            guard flow == siloFlowID, siloDraft === draft else {
                SiloSession.cancelPendingSignIn()
                return
            }
            siloProfileList = profiles
            siloLoadedProfiles = true
            (vc as? SettingsPageViewController)?.onPush?(.siloProfiles)
        }
        vc.present(signIn, animated: true)
    }

    private static func loadSiloProfiles(on vc: UIViewController, push: Bool) {
        guard !siloBusy else { return }
        let flow = siloFlowID
        siloBusy = true
        let page = vc as? SettingsPageViewController
        page?.reloadRows()
        Task { @MainActor in
            do {
                let profiles = try await SiloSession.profiles()
                guard flow == siloFlowID else { return }
                siloProfileList = profiles
                siloLoadedProfiles = true
                siloBusy = false
                page?.reloadRows()
                if push { page?.onPush?(.siloProfiles) }
            } catch {
                guard flow == siloFlowID, !(error is CancellationError) else { return }
                siloBusy = false
                siloFailure(on: vc, title: "Couldn't Load Profiles", error: error)
            }
        }
    }

    private static func selectSiloProfile(_ profile: SiloProfile, pin: String?, on vc: UIViewController) {
        guard !siloBusy else { return }
        let flow = siloFlowID
        siloBusy = true
        siloPendingProfile = profile
        let page = vc as? SettingsPageViewController
        page?.reloadRows()
        Task { @MainActor in
            do {
                try await SiloSession.selectProfile(profile, pin: pin)
                guard flow == siloFlowID else { return }
                siloBusy = false
                siloPIN = ""
                siloPendingProfile = nil
                if page?.page == .siloProfilePIN { page?.onPopTwo?() }
                else { page?.onPop?() }
            } catch {
                guard flow == siloFlowID, !(error is CancellationError) else { return }
                siloBusy = false
                siloFailure(on: vc, title: "Couldn't Select Profile", error: error)
            }
        }
    }

    static func siloFailureCopy(for error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription { return message }
        if case MediaProviderError.unreachable = error { return "Couldn't reach Silo. Check the web address and your network connection." }
        return "Silo could not complete this request. Try again."
    }

    private static func siloFailure(on vc: UIViewController, title: String, error: Error) {
        siloFailure(on: vc, title: title, message: siloFailureCopy(for: error))
    }

    private static func siloFailure(on vc: UIViewController, title: String, message: String) {
        let page = vc as? SettingsPageViewController
        fail(siloDraft, page: page, title: title, message: message)
    }
}
