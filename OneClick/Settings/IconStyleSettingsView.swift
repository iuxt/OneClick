import AppKit
import SwiftUI

@available(macOS 27, *)
struct AppIconStyleSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsSection(
            "Context Menu",
            footer: "Applies to app icons in the Open With menu. Simple icons use the original icon when no matching symbol is available."
        ) {
            SettingsRow {
                SettingsSwitch("Collapse apps menu", isOn: $appState.foldAppsMenu)
                    .onChange(of: appState.foldAppsMenu) {
                        NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
                    }
            }
            SettingsRow {
                SettingsPicker("Icon Style", selection: $appState.appIconStyle) {
                    Text(appLocalized: "No Icons").tag(RCAppIconStyle.none.rawValue)
                    Text(appLocalized: "Simple Icons").tag(RCAppIconStyle.simple.rawValue)
                    Text(appLocalized: "Original Icons").tag(RCAppIconStyle.original.rawValue)
                }
                .onChange(of: appState.appIconStyle) {
                    NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
                }
            }
            SettingsRow {
                LabeledContent(AppLocalization.localized("Menu Preview")) {
                    VStack(alignment: .leading, spacing: 8) {
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
                }
            }
        }
    }

    private var previewApps: [OpenWithApp] {
        let visibleApps = appState.apps.filter(\.showInContextMenu)
        if visibleApps.isEmpty {
            return [OpenWithApp(appURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))]
        }
        return Array(visibleApps.prefix(3))
    }
}
