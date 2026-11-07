import SwiftUI

enum ArchiveSettingsSection {
    case compression, contextMenu, associations
}

@available(macOS 27, *)
struct ArchiveSettingsTabView: View {
    var section: ArchiveSettingsSection = .compression
    @Environment(\.isSettingsPageActive) private var isActive
    @EnvironmentObject var appState: AppState
    @State private var confirmingReset = false
    @AppStorage("archiveCompressionFormat", store: .group) private var format: ArchiveCompressionFormat = .zip
    @AppStorage("archiveCompressionLevel", store: .group) private var level: ArchiveCompressionLevel = .normal
    @AppStorage("archiveCompressionThreads", store: .group) private var threadCount = 0
    @AppStorage("archiveExcludeFiles", store: .group) private var excludeFiles = false
    @AppStorage("archiveExclusionList", store: .group) private var exclusionList = ArchiveCompressionSettings.defaultExclusionList

    var body: some View {
        Form {
            if section == .associations {
                Section {
                    ArchiveAssociationView()
                } header: {
                    Text(appLocalized: "File Associations")
                }
            }
            if section == .contextMenu {
                Section {
                    Toggle(AppLocalization.localized("Collapse compression and extraction menu"), isOn: $appState.foldArchivesMenu)
                        .onChange(of: appState.foldArchivesMenu) {
                            NotificationCenter.default.post(name: .menuConfigShouldUpdate, object: nil)
                        }
                }
                Section {
                    ActionSettingsList(archives: true)
                } header: {
                    Text(appLocalized: "Context Menu")
                }
            }
            if section == .compression {
                Section {
                    Picker(AppLocalization.localized("Archive Format"), selection: $format) {
                        ForEach(ArchiveCompressionFormat.allCases, id: \.self) { format in
                            Text(verbatim: format.rawValue).tag(format)
                        }
                    }
                    Picker(AppLocalization.localized("Compression Level"), selection: $level) {
                        ForEach(ArchiveCompressionLevel.defaultCases, id: \.self) { level in
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
                    Text(appLocalized: "Limits compression threads for ZIP, 7Z and TAR.GZ. Automatic uses the available logical CPU count.")
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
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel(AppLocalization.localized("Exclusion List"))
                    }
                    .disabled(!excludeFiles)
                } header: {
                    Text(appLocalized: "Exclude Files")
                } footer: {
                    Text(appLocalized: "Enter one file or folder name pattern per line, for example .DS_Store, node_modules or *.tmp. Matches are excluded at every folder level during compression.")
                }
                Section {
                    HStack {
                        Spacer()
                        Button(AppLocalization.localized("Reset Archive Settings…")) {
                            confirmingReset = true
                        }
                    }
                } footer: {
                    Text(appLocalized: "Resets compression options, exclusion rules and archive menu settings. File associations are kept.")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            AppLocalization.localized("Restore Archive Defaults?"),
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.localized("Reset"), role: .destructive) {
                format = .zip
                level = .normal
                threadCount = 0
                excludeFiles = false
                exclusionList = ArchiveCompressionSettings.defaultExclusionList
                appState.foldArchivesMenu = false
                appState.resetActionItems(archives: true)
            }
            Button(AppLocalization.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(appLocalized: "Resets compression options, exclusion rules and archive menu settings. File associations are kept.")
        }
        .onChange(of: isActive, initial: true) {
            guard isActive else { return }
            threadCount = min(max(0, threadCount), ArchiveCompressionSettings.maximumThreadCount)
        }
    }
}
