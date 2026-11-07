//
//  EditFileTypeSheetView.swift
//  OneClick
//
//  Created by Claude on 2026/06/28.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 27, *)
struct EditFileTypeSheetView: View {
    let file: NewFile
    let appState: AppState

    var isAdding: Bool { file.ext.isEmpty && file.name.isEmpty }

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var ext: String
    @State private var icon: String
    @State private var openApp: URL?
    @State private var template: URL?

    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var showSelectApp = false
    @State private var showSelectTemplate = false

    let messager = Messager.shared

    private static let legacyIconSymbols: [String: String] = [
        "icon-file-json": "curlybraces",
        "icon-file-txt": "doc.text",
        "icon-file-md": "doc.richtext",
        "icon-file-docx": "doc.richtext.fill",
        "icon-file-pptx": "rectangle.on.rectangle.fill",
        "icon-file-xlsx": "tablecells",
        "document": "doc",
    ]

    private static let iconChoices = [
        (symbol: "doc", title: "Document Icon"),
        (symbol: "doc.text", title: "Text Icon"),
        (symbol: "doc.richtext", title: "Rich Text Icon"),
        (symbol: "curlybraces", title: "Data Icon"),
        (symbol: "chevron.left.forwardslash.chevron.right", title: "Code Icon"),
        (symbol: "tablecells", title: "Table Icon"),
        (symbol: "photo", title: "Image Icon"),
        (symbol: "doc.zipper", title: "Archive Icon"),
    ]

    let templatesDir: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("RClick/Templates")

    init(file: NewFile, appState: AppState) {
        self.file = file
        self.appState = appState
        _name = State(initialValue: file.name)
        _ext = State(initialValue: file.ext)
        _icon = State(initialValue: Self.legacyIconSymbols[file.icon] ?? file.icon)
        _openApp = State(initialValue: file.openApp)
        _template = State(initialValue: file.template)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(appLocalized: isAdding ? "Add File Type" : "Edit File Type")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Form {
                Section {
                    TextField(AppLocalization.localized("Display Name"), text: $name)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text(appLocalized: "Name")
                }

                Section {
                    TextField(AppLocalization.localized("File Extension"), text: $ext)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text(appLocalized: "File Extension")
                } footer: {
                    Text(appLocalized: "For example: txt, md, json")
                        .foregroundColor(.secondary)
                }

                Section {
                    HStack {
                        if let templateUrl = template {
                            Text(templateUrl.lastPathComponent)
                            Button {
                                template = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            showSelectTemplate = true
                        } label: {
                            Text(appLocalized: template == nil ? "Choose Template File" : "Change Template")
                        }
                        .fileImporter(
                            isPresented: $showSelectTemplate,
                            allowedContentTypes: [.content],
                            allowsMultipleSelection: false
                        ) { result in
                            switch result {
                            case .success(let files):
                                if let url = files.first {
                                    template = url
                                }
                            case .failure:
                                break
                            }
                        }
                    }
                } header: {
                    Text(appLocalized: "Template")
                } footer: {
                    if template == nil, FileCreationPolicy.builtInTemplate(for: ext) != nil {
                        Text(appLocalized: "A built-in blank document is used by default. Custom templates are optional.")
                    }
                }

                Section {
                    Picker(AppLocalization.localized("Fallback Icon"), selection: $icon) {
                        if !Self.iconChoices.contains(where: { $0.symbol == icon }) {
                            Text(appLocalized: "Current Icon").tag(icon)
                        }
                        ForEach(Self.iconChoices, id: \.symbol) { choice in
                            Label(AppLocalization.localized(choice.title), systemImage: choice.symbol)
                                .tag(choice.symbol)
                        }
                    }
                    LabeledContent(AppLocalization.localized("Menu Preview")) {
                        SettingsIcon(source: openApp.map { .application($0) } ?? .fileType(ext, fallback: icon))
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                    }
                } header: {
                    Text(appLocalized: "Icon")
                } footer: {
                    Text(appLocalized: "Uses the chosen app’s icon or the file type’s system icon automatically. The fallback icon is used when neither is available.")
                        .foregroundColor(.secondary)
                }

                Section {
                    HStack {
                        if let appUrl = openApp {
                            Image(nsImage: IconCache.shared.icon(for: appUrl))
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(appUrl.lastPathComponent)
                        }

                        Button {
                            showSelectApp = true
                        } label: {
                            Text(appLocalized: openApp == nil ? "Choose Default App" : "Change App")
                        }
                        .fileImporter(
                            isPresented: $showSelectApp,
                            allowedContentTypes: [.application],
                            allowsMultipleSelection: false
                        ) { result in
                            switch result {
                            case .success(let files):
                                if let url = files.first {
                                    openApp = url
                                }
                            case .failure:
                                break
                            }
                        }

                        if openApp != nil {
                            Button {
                                openApp = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text(appLocalized: "Open New Files With")
                } footer: {
                    Text(appLocalized: "New files open with the selected application. Without a selection, they are revealed in Finder.")
                }
            }
            .formStyle(.grouped)

            if isSaving { ProgressView().controlSize(.small).padding(.bottom, 8) }
            if let saveError { Text(saveError).foregroundStyle(.red).padding(.horizontal) }
            HStack {
                Button(AppLocalization.localized("Cancel")) {
                    dismiss()
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.escape)

                Button(AppLocalization.localized(isAdding ? "Add" : "Save")) {
                    saveTask = Task { await saveChanges() }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return)
                .disabled(name.isEmpty || ext.isEmpty)
            }
            .padding(.bottom, 20)
        }
        .frame(width: 440, height: 580)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .onDisappear { saveTask?.cancel() }
    }

    private func saveChanges() async {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let normalizedExtension = try FileCreationPolicy.normalizedExtension(ext)
            let savedTemplate: URL?
            if let template {
                guard let templatesDir else { throw CocoaError(.fileNoSuchFile) }
                savedTemplate = try await FileActionWorker.importTemplate(from: template, into: templatesDir, existing: file.template)
            } else {
                savedTemplate = nil
            }
            if Task.isCancelled {
                if let savedTemplate, savedTemplate != file.template {
                    _ = await FileActionWorker.remove([savedTemplate.deletingLastPathComponent().path])
                }
                return
            }
            var updated = isAdding
                ? NewFile(ext: ext, name: name, idx: appState.newFiles.count, icon: icon)
                : file
            updated.name = name
            updated.ext = normalizedExtension
            updated.icon = icon
            updated.openApp = openApp
            updated.template = savedTemplate
            if isAdding {
                appState.addNewFile(updated)
            } else if let index = appState.newFiles.firstIndex(where: { $0.id == file.id }) {
                appState.newFiles[index] = updated
                appState.sync()
            }
            if let error = appState.lastSaveError { saveError = error }
            else { dismiss() }
        } catch is CancellationError {
            // Closing the sheet cancels publishing; the worker cleans partial copies.
        } catch {
            saveError = error.localizedDescription
        }
    }
}
