import SwiftUI
import UniformTypeIdentifiers

@available(macOS 27, *)
struct AddApplicationSheetView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var applications: [InstalledApplication] = []
    @State private var isLoading = true
    @State private var search = ""
    @State private var selection: URL?
    @State private var browsing = false
    @State private var showingPresets = false
    @State private var pickerError: String?

    private var addedPaths: Set<String> {
        Set(appState.apps.map { $0.url.standardizedFileURL.path })
    }

    private var filteredApplications: [InstalledApplication] {
        applications.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
    }

    private var canAddSelection: Bool {
        guard let selection else { return false }
        return filteredApplications.contains { $0.url == selection } && !addedPaths.contains(selection.path)
    }

    var body: some View {
        SettingsSheet(title: "Add App") {
            VStack(spacing: 0) {
                Picker(AppLocalization.localized("App Source"), selection: $showingPresets) {
                    Text(appLocalized: "Installed Apps").tag(false)
                    Text(appLocalized: "Presets").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

                if showingPresets {
                    PresetAppsList(appState: appState)
                } else {
                    installedApps
                }
            }
        } footer: {
            if !showingPresets { Button(AppLocalization.localized("Browse…")) { browsing = true } }
            Spacer()
            if showingPresets {
                Button(AppLocalization.localized("Done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(AppLocalization.localized("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppLocalization.localized("Add")) {
                    if let selection { add(selection) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAddSelection)
            }
        }
        .frame(width: 560, height: 505)
        .task {
            let loaded = await InstalledApplication.discover()
            guard !Task.isCancelled else { return }
            applications = loaded
            isLoading = false
        }
        .fileImporter(isPresented: $browsing, allowedContentTypes: [.application]) { result in
            switch result {
            case .success(let url): add(url)
            case .failure(let error): pickerError = error.localizedDescription
            }
        }
        .fileDialogDefaultDirectory(URL(fileURLWithPath: "/Applications", isDirectory: true))
        .fileDialogCustomizationID("OneClick.AddApplication")
    }

    private var installedApps: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(AppLocalization.localized("Search Apps"), text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 24)
            .padding(.bottom, 10)

            List(selection: $selection) {
                ForEach(filteredApplications) { application in
                    HStack {
                        SettingsItemLabel(title: application.name) {
                            SettingsIcon(source: .application(application.url))
                        }
                        Spacer()
                        if addedPaths.contains(application.url.path) {
                            Text(appLocalized: "Added").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(application.url)
                }
            }
            .listStyle(.inset)
            .overlay {
                if isLoading {
                    ProgressView()
                } else if filteredApplications.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }

            if let pickerError {
                Label(pickerError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(12)
            }
        }
    }

    private func add(_ url: URL) {
        guard !addedPaths.contains(url.standardizedFileURL.path) else {
            pickerError = AppLocalization.localized("This app has already been added.")
            return
        }
        appState.addApp(item: OpenWithApp(appURL: url))
        dismiss()
    }
}

private struct PresetAppsList: View {
    @ObservedObject var appState: AppState

    var body: some View {
        List(sortedPresets, id: \.preset.bundleID) { entry in
            presetRow(entry.preset, installedURL: entry.installedURL, alreadyAdded: entry.added)
        }
        .listStyle(.inset)
    }

    /// 预设行数据：预装状态 + 是否已添加（随 appState.apps 变化重新计算）
    private struct PresetEntry {
        let preset: AppPreset
        let installedURL: URL?
        let added: Bool
    }

    private var sortedPresets: [PresetEntry] {
        let entries = AppPresets.all.map { preset -> PresetEntry in
            let installedURL = AppPresets.installedURL(for: preset)
            let added = installedURL.map { url in
                appState.apps.contains { $0.url.standardizedFileURL == url.standardizedFileURL }
            } ?? false
            return PresetEntry(preset: preset, installedURL: installedURL, added: added)
        }
        // 0=可添加（已安装未添加） 1=已添加 2=未安装；稳定排序保持组内原顺序
        return entries.enumerated().sorted { a, b in
            let pa = Self.priority(a.element)
            let pb = Self.priority(b.element)
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
    }

    private static func priority(_ entry: PresetEntry) -> Int {
        switch (entry.installedURL, entry.added) {
        case (.some, false): return 0
        case (.some, true): return 1
        case (.none, _): return 2
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: AppPreset, installedURL: URL?, alreadyAdded: Bool) -> some View {
        HStack(spacing: 12) {
            SettingsItemLabel(title: AppLocalization.localized(preset.nameKey)) {
                if let installedURL {
                    SettingsIcon(source: .application(installedURL))
                } else {
                    Image(systemName: preset.symbol).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let installedURL, !alreadyAdded {
                Button(AppLocalization.localized("Add")) {
                    appState.addApp(item: OpenWithApp(appURL: installedURL))
                }
                .accessibilityLabel(AppLocalization.localized("Add") + " · " + AppLocalization.localized(preset.nameKey))
            } else {
                Text(appLocalized: alreadyAdded ? "Added" : "Not Installed")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
