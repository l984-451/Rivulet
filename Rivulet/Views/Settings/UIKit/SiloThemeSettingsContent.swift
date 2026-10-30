import UIKit

extension SettingsContent {
    /// Local audio preference rows appear only after an authorized capability refresh.
    static func siloThemeMusicRows(provider: SiloProvider) -> [SettingsRowItem] {
        let controller = SiloThemeMusicController.shared
        guard controller.offersSettings(for: provider) else { return [] }
        return [
            SettingsRowItem(id: "siloThemeMusicEnabled", title: "Theme Music", kind: .toggle(
                get: { controller.setting.enabled },
                set: { value in controller.setEnabled(value, provider: provider) }
            )),
            SettingsRowItem(id: "siloThemeMusicLoop", title: "Loop Theme Music", kind: .toggle(
                get: { controller.setting.loop },
                set: { value in controller.setLoop(value, provider: provider) }
            ))
        ]
    }
}
