import SwiftUI

@available(macOS 27, *)
struct IconStyleSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                Picker(selection: $appState.appIconStyle) {
                    Text(AppLocalization.localized("No Icons")).tag(RCAppIconStyle.none.rawValue)
                    Text(AppLocalization.localized("Simple Icons")).tag(RCAppIconStyle.simple.rawValue)
                    Text(AppLocalization.localized("Original Icons")).tag(RCAppIconStyle.original.rawValue)
                } label: {
                    Text(AppLocalization.localized("Icon Style"))
                }
                .pickerStyle(.segmented)
                .onChange(of: appState.appIconStyle) {
                    NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
                }
            } header: {
                Text(AppLocalization.localized("Icon Style"))
            } footer: {
                Text(appLocalized: "Applies to app icons in the Open With menu: none / simple (monochrome) / original")
                    .foregroundColor(.secondary)
            }

        }
        .formStyle(.grouped)
    }
}
