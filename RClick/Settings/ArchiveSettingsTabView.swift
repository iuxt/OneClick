import SwiftUI

struct ArchiveSettingsTabView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("archiveCompressionFormat", store: .group) private var format: ArchiveCompressionFormat = .zip
    @AppStorage("archiveCompressionLevel", store: .group) private var level: ArchiveCompressionLevel = .normal

    var body: some View {
        Form {
            Section {
                Toggle(AppLocalization.localized("Collapse compression and extraction menu"), isOn: $appState.foldArchivesMenu)
                    .onChange(of: appState.foldArchivesMenu) {
                        NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
                    }
            }
            Section {
                Picker(AppLocalization.localized("Archive Format"), selection: $format) {
                    ForEach(ArchiveCompressionFormat.allCases, id: \.self) { format in
                        Text(verbatim: format.rawValue).tag(format)
                    }
                }
                Picker(AppLocalization.localized("Compression Level"), selection: $level) {
                    ForEach(ArchiveCompressionLevel.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                }
            } header: {
                Text(appLocalized: "Default Compression Options")
            } footer: {
                Text(appLocalized: "Compress… opens a window to adjust these options and set an optional password.")
            }
            Section {
                ActionSettingsList(archives: true)
            } header: {
                Text(appLocalized: "Context Menu")
            } footer: {
                HStack {
                    Spacer()
                    Button(AppLocalization.localized("Restore Defaults")) {
                        format = .zip
                        level = .normal
                        appState.foldArchivesMenu = false
                        appState.resetActionItems(archives: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
