import SwiftUI

struct ArchiveSettingsTabView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("archiveCompressionFormat", store: .group) private var format: ArchiveCompressionFormat = .zip
    @AppStorage("archiveCompressionLevel", store: .group) private var level: ArchiveCompressionLevel = .normal
    @AppStorage("archiveCompressionThreads", store: .group) private var threadCount = 0
    @AppStorage("archiveExcludeFiles", store: .group) private var excludeFiles = false
    @AppStorage("archiveExclusionList", store: .group) private var exclusionList = ArchiveCompressionSettings.defaultExclusionList

    var body: some View {
        Form {
            Section {
                ArchiveLaunchControls()
            } header: {
                Text(appLocalized: "Archive Tools")
            }
            Section {
                ArchiveAssociationView()
            } header: {
                Text(appLocalized: "File Associations")
            }
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
                Picker(AppLocalization.localized("Compression CPU Threads"), selection: $threadCount) {
                    Text(appLocalized: "Automatic").tag(0)
                    ForEach(1...ArchiveCompressionSettings.maximumThreadCount, id: \.self) { count in
                        Text(verbatim: String(count)).tag(count)
                    }
                }
            } footer: {
                Text(appLocalized: "Limits compression threads for ZIP and 7Z. Automatic uses the available logical CPU count. TAR.GZ uses one thread.")
            }
            Section {
                Toggle(AppLocalization.localized("Exclude matching files"), isOn: $excludeFiles)
                VStack(alignment: .leading, spacing: 8) {
                    Text(appLocalized: "Exclusion List")
                    TextEditor(text: $exclusionList)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 88)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        .accessibilityLabel(AppLocalization.localized("Exclusion List"))
                }
                .disabled(!excludeFiles)
            } header: {
                Text(appLocalized: "Exclude Files")
            } footer: {
                Text(appLocalized: "Enter one file or folder name pattern per line, for example .DS_Store, node_modules or *.tmp. Matches are excluded at every folder level during compression.")
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
                        threadCount = 0
                        excludeFiles = false
                        exclusionList = ArchiveCompressionSettings.defaultExclusionList
                        appState.foldArchivesMenu = false
                        appState.resetActionItems(archives: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            threadCount = min(max(0, threadCount), ArchiveCompressionSettings.maximumThreadCount)
        }
    }
}
