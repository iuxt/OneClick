import AppKit
import SwiftUI

@available(macOS 27, *)
struct AppIconStyleSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Section {
            Picker(selection: $appState.appIconStyle) {
                Text(AppLocalization.localized("No Icons")).tag(RCAppIconStyle.none.rawValue)
                Text(AppLocalization.localized("Simple Icons")).tag(RCAppIconStyle.simple.rawValue)
                Text(AppLocalization.localized("Original Icons")).tag(RCAppIconStyle.original.rawValue)
            } label: {
                Text(AppLocalization.localized("Icon Style"))
            }
            .pickerStyle(.menu)
            .onChange(of: appState.appIconStyle) {
                NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(appLocalized: "Menu Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(previewApps) { app in
                    HStack(spacing: 8) {
                        if appState.appIconStyle != RCAppIconStyle.none.rawValue {
                            if appState.appIconStyle == RCAppIconStyle.simple.rawValue,
                               let icon = AppPresets.simpleIcon(forAppPath: app.url.path) {
                                Image(nsImage: icon).resizable().scaledToFit()
                                    .frame(width: 18, height: 18)
                                    .accessibilityHidden(true)
                            } else {
                                SettingsIcon(source: .application(app.url))
                                    .frame(width: 18, height: 18)
                                    .accessibilityHidden(true)
                            }
                        }
                        Text(app.name).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(appLocalized: "Icon Style")
        } footer: {
            Text(appLocalized: "Applies to app icons in the Open With menu. Simple icons use the original icon when no matching symbol is available.")
        }
    }

    private var previewApps: [OpenWithApp] {
        if appState.apps.isEmpty {
            return [OpenWithApp(appURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))]
        }
        return Array(appState.apps.prefix(3))
    }
}
