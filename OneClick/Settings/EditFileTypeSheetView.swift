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
        SettingsSheet(title: isAdding ? "Add File Type" : "Edit File Type") {
            SettingsEditor {
                SettingsSection {
                    SettingsRow {
                        SettingsTextField(title: "Display Name", text: $name)
                    }
                    SettingsRow {
                        SettingsTextField(title: "File Extension", text: $ext, prompt: Text(verbatim: "txt, md, json"))
                    }
                }

                SettingsSection(
                    "Template",
                    footer: template == nil && FileCreationPolicy.builtInTemplate(for: ext) != nil
                        ? "A built-in blank document is used by default. Custom templates are optional."
                        : nil
                ) {
                    SettingsRow {
                        if let template {
                            Text(template.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(template.path)
                        } else {
                            Text(appLocalized: "No Template Selected")
                        }
                        Spacer()
                        Button(AppLocalization.localized(template == nil ? "Choose Template File" : "Change Template")) {
                            showSelectTemplate = true
                        }
                        if template != nil {
                            SettingsIconButton(title: "Clear Selection", symbol: "xmark.circle") { template = nil }
                        }
                    }
                }

                SettingsSection(
                    "Open New Files With",
                    footer: "New files open with the selected application. Without a selection, they are revealed in Finder."
                ) {
                    SettingsRow {
                        if let openApp {
                            SettingsItemLabel(title: openApp.deletingPathExtension().lastPathComponent) {
                                SettingsIcon(source: .application(openApp))
                            }
                        } else {
                            Text(verbatim: "Finder")
                        }
                        Spacer()
                        Button(AppLocalization.localized(openApp == nil ? "Choose Default App" : "Change App")) {
                            showSelectApp = true
                        }
                        if openApp != nil {
                            SettingsIconButton(title: "Clear Selection", symbol: "xmark.circle") { openApp = nil }
                        }
                    }
                }

                SettingsSection(
                    "Icon",
                    footer: "Uses the chosen app’s icon or the file type’s system icon automatically. The fallback icon is used when neither is available."
                ) {
                    SettingsRow {
                        SettingsPicker("Fallback Icon", selection: $icon) {
                            if !Self.iconChoices.contains(where: { $0.symbol == icon }) {
                                Text(appLocalized: "Current Icon").tag(icon)
                            }
                            ForEach(Self.iconChoices, id: \.symbol) { choice in
                                Label(AppLocalization.localized(choice.title), systemImage: choice.symbol)
                                    .tag(choice.symbol)
                            }
                        }
                    }
                    SettingsRow {
                        LabeledContent(AppLocalization.localized("Menu Preview")) {
                            SettingsIcon(source: openApp.map { .application($0) } ?? .fileType(ext, fallback: icon))
                                .frame(width: 24, height: 24)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        } footer: {
            if isSaving { ProgressView().controlSize(.small) }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(AppLocalization.localized("Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(AppLocalization.localized(isAdding ? "Add" : "Save")) {
                saveTask = Task { await saveChanges() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ext.isEmpty)
        }
        .frame(width: 590, height: 580)
        .fileImporter(isPresented: $showSelectTemplate, allowedContentTypes: [.content]) { result in
            switch result {
            case .success(let url):
                template = url
                saveError = nil
            case .failure(let error): saveError = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showSelectApp, allowedContentTypes: [.application]) { result in
            switch result {
            case .success(let url):
                openApp = url
                saveError = nil
            case .failure(let error): saveError = error.localizedDescription
            }
        }
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
            let existing = appState.getFileType(rid: file.id)
            let previousTemplate = existing?.template ?? file.template
            let savedTemplate: URL?
            if let template {
                guard let templatesDir else { throw CocoaError(.fileNoSuchFile) }
                savedTemplate = try await FileActionWorker.importTemplate(from: template, into: templatesDir, existing: previousTemplate)
            } else {
                savedTemplate = nil
            }
            if Task.isCancelled {
                if let savedTemplate, savedTemplate != previousTemplate {
                    _ = await FileActionWorker.remove([savedTemplate.deletingLastPathComponent().path])
                }
                return
            }
            var updated = existing ?? file
            if existing == nil && isAdding { updated.idx = appState.newFiles.count }
            updated.name = name
            updated.ext = normalizedExtension
            updated.icon = icon
            updated.openApp = openApp
            updated.template = savedTemplate
            if let index = appState.newFiles.firstIndex(where: { $0.id == file.id }) {
                appState.newFiles[index] = updated
                appState.sync()
            } else if isAdding {
                appState.addNewFile(updated)
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
