import SwiftUI

enum ArchiveSettingsSection {
    case compression, contextMenu, associations
}

struct ArchiveSettingsTabView: View {
    var section: ArchiveSettingsSection = .compression
    @Environment(\.isSettingsPageActive) private var isActive
    @EnvironmentObject private var appState: AppState
    @State private var confirmingReset = false
    @AppStorage("archiveCompressionFormat", store: .group) private var format: ArchiveCompressionFormat = .zip
    @AppStorage("archiveCompressionLevel", store: .group) private var level: ArchiveCompressionLevel = .normal
    @AppStorage("archiveCompressionThreads", store: .group) private var threadCount = 0
    @AppStorage("archiveExcludeFiles", store: .group) private var excludeFiles = false
    @AppStorage("archiveExclusionList", store: .group) private var exclusionList = ArchiveCompressionSettings.defaultExclusionList

    var body: some View {
        switch section {
        case .compression:
            compression
                .onChange(of: isActive, initial: true) {
                    guard isActive else { return }
                    let clamped = min(max(0, threadCount), ArchiveCompressionSettings.maximumThreadCount)
                    if clamped != threadCount { threadCount = clamped }
                }
        case .contextMenu:
            SettingsSection {
                SettingsRow {
                    SettingsSwitch("Collapse compression and extraction menu", isOn: $appState.foldArchivesMenu)
                        .onChange(of: appState.foldArchivesMenu) {
                            NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
                        }
                }
            }
            ActionSettingsList(archives: true) { EmptyView() }
        case .associations:
            ArchiveAssociationView()
        }
    }

    private var compression: some View {
        Group {
            SettingsSection(
                "Default Compression Options",
                footer: "Compress… opens a window to adjust these options and set an optional password."
            ) {
                SettingsRow {
                    SettingsPicker("Archive Format", selection: $format) {
                        ForEach(ArchiveCompressionFormat.allCases, id: \.self) { format in
                            Text(verbatim: format.rawValue).tag(format)
                        }
                    }
                }
                SettingsRow {
                    SettingsPicker("Compression Level", selection: $level) {
                        ForEach(ArchiveCompressionLevel.defaultCases, id: \.self) { level in
                            Text(level.title).tag(level)
                        }
                    }
                }
            }

            SettingsSection(footer: "Automatic uses up to four threads for parallel single-file ZIP compression and the available logical CPU count for other compression paths.") {
                SettingsRow {
                    SettingsPicker("Compression CPU Threads", selection: $threadCount) {
                        Text(appLocalized: "Automatic").tag(0)
                        ForEach(1...ArchiveCompressionSettings.maximumThreadCount, id: \.self) { count in
                            Text(verbatim: String(count)).tag(count)
                        }
                    }
                }
            }

            SettingsSection(
                "Exclude Files",
                footer: "Enter one file or folder name pattern per line, for example .DS_Store, node_modules or *.tmp. Matches are excluded at every folder level during compression."
            ) {
                SettingsRow {
                    SettingsSwitch("Exclude matching files", isOn: $excludeFiles)
                }
                SettingsRow {
                    TextEditor(text: $exclusionList)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 94)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(AppLocalization.localized("Exclusion List"))
                        .disabled(!excludeFiles)
                }
            }

            Button(AppLocalization.localized("Reset Archive Settings…")) { confirmingReset = true }
                .alert(Text(appLocalized: "Restore Archive Defaults?"), isPresented: $confirmingReset) {
                    Button(AppLocalization.localized("Cancel"), role: .cancel) {}
                    Button(AppLocalization.localized("Reset"), role: .destructive) {
                        format = .zip
                        level = .normal
                        threadCount = 0
                        excludeFiles = false
                        exclusionList = ArchiveCompressionSettings.defaultExclusionList
                        appState.foldArchivesMenu = false
                        appState.resetActionItems(archives: true)
                    }
                } message: {
                    Text(appLocalized: "Resets compression options, exclusion rules and archive menu settings. File associations are kept.")
                }
        }
    }
}
