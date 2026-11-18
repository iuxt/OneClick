import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum InputMethodSettingsSection {
    case preferences, applicationRules
}

@available(macOS 27, *)
struct InputMethodSettingsView: View {
    var section: InputMethodSettingsSection = .preferences
    @Environment(\.isSettingsPageActive) private var isActive
    @ObservedObject private var service = InputMethodService.shared
    @State private var addingApp = false

    var body: some View {
        Group {
            switch section {
            case .preferences: preferences
            case .applicationRules: applicationRules
            }
            if let error = service.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack {
                Button(AppLocalization.localized("Refresh Input Methods")) { service.refresh() }
                Spacer()
                Link("LockIME · GPL-3.0", destination: URL(string: "https://github.com/oomol-lab/LockIME")!)
                    .font(.caption)
            }
        }
        .onChange(of: isActive) {
            if !isActive { addingApp = false }
        }
        .sheet(isPresented: $addingApp) { AddInputMethodRuleSheet(service: service) }
    }

    private var preferences: some View {
        Group {
            SettingsSection(footer: "Switch input methods when you activate an application. Manual changes remain available until the next app switch.") {
                SettingsRow {
                    SettingsSwitch("Automatically switch input methods", isOn: Binding(
                        get: { service.configuration.enabled },
                        set: { value in service.update { $0.enabled = value } }
                    ))
                }
                SettingsRow {
                    LabeledContent(AppLocalization.localized("Current Input Method")) {
                        Text(service.sources.first { $0.id == service.currentSourceID }?.name ?? "—")
                    }
                }
                SettingsRow {
                    LabeledContent(AppLocalization.localized("Active Application"), value: service.activeAppName)
                }
            }
            SettingsSection(
                "Default Behavior",
                footer: "Application rules take priority, followed by remembered input methods and the default. Secure password fields are respected."
            ) {
                SettingsRow {
                    SettingsPicker("Default Input Method", selection: Binding(
                        get: { service.configuration.defaultSourceID },
                        set: { value in service.update { $0.defaultSourceID = value } }
                    )) {
                        Text(appLocalized: "Keep Current Input Method").tag("")
                        sourceOptions(including: service.configuration.defaultSourceID)
                    }
                }
                SettingsRow {
                    SettingsSwitch("Remember input method for each application", isOn: Binding(
                        get: { service.configuration.remember },
                        set: { value in service.update { $0.remember = value } }
                    ))
                }
            }
        }
    }

    private var applicationRules: some View {
        SettingsCollection(
            title: "Assigned Input Methods",
            items: service.configuration.rules,
            emptyTitle: "No Application Rules",
            emptyIcon: "app.badge"
        ) {
            Button(AppLocalization.localized("Add Application…"), systemImage: "plus") { addingApp = true }
                .buttonStyle(.borderedProminent)
                .disabled(service.sources.isEmpty)
        } row: { rule, _ in
            InputMethodRuleRow(rule: rule, sources: service.sources, selection: Binding(
                get: { service.configuration.rules.first { $0.id == rule.id }?.sourceID ?? rule.sourceID },
                set: { value in service.update { config in
                    if let index = config.rules.firstIndex(where: { $0.id == rule.id }) {
                        config.rules[index].sourceID = value
                    }
                } }
            )) {
                service.update { $0.rules.removeAll { $0.id == rule.id } }
            }
        }
    }

    @ViewBuilder private func sourceOptions(including id: String) -> some View {
        if !id.isEmpty && !service.sources.contains(where: { $0.id == id }) {
            Text(AppLocalization.localized("Unavailable") + " · " + id).tag(id)
        }
        ForEach(service.sources) { source in Text(source.name).tag(source.id) }
    }
}

@available(macOS 27, *)
private struct InputMethodRuleRow: View {
    let rule: InputMethodRule
    let sources: [InputMethodSource]
    @Binding var selection: String
    let remove: () -> Void
    @State private var applicationURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            SettingsItemLabel(title: rule.name, detail: rule.bundleID) {
                if let applicationURL {
                    SettingsIcon(source: .application(applicationURL))
                } else {
                    Image(systemName: "app.dashed").foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Picker(AppLocalization.localized("Input Method"), selection: $selection) {
                if !sources.contains(where: { $0.id == selection }) {
                    Text(AppLocalization.localized("Unavailable") + " · " + selection).tag(selection)
                }
                ForEach(sources) { source in Text(source.name).tag(source.id) }
            }
            .labelsHidden()
            .frame(width: 190, alignment: .trailing)
            .help(sources.first { $0.id == selection }?.name ?? AppLocalization.localized("Unavailable") + " · " + selection)
            .accessibilityLabel(rule.name + " · " + AppLocalization.localized("Input Method"))

            SettingsIconButton(title: "Remove Rule", symbol: "trash", subject: rule.name, action: remove)
        }
        .task(id: rule.bundleID) {
            // Resolve the installed app after layout; icon loading uses SettingsIcon's cache.
            await Task.yield()
            guard !Task.isCancelled else { return }
            applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleID)
        }
    }
}

@available(macOS 27, *)
private struct AddInputMethodRuleSheet: View {
    @ObservedObject var service: InputMethodService
    @Environment(\.dismiss) private var dismiss
    @State private var applicationURL: URL?
    @State private var selectedSource = ""
    @State private var browsing = false
    @State private var error: String?

    private var canAdd: Bool {
        applicationURL != nil && service.sources.contains { $0.id == selectedSource }
    }

    var body: some View {
        SettingsSheet(title: "Add Application Rule") {
            SettingsEditor {
                SettingsSection {
                    SettingsRow {
                        if let applicationURL {
                            SettingsItemLabel(
                                title: FileManager.default.displayName(atPath: applicationURL.path),
                                detail: Bundle(url: applicationURL)?.bundleIdentifier
                            ) {
                                SettingsIcon(source: .application(applicationURL))
                            }
                        } else {
                            Text(appLocalized: "Application")
                        }
                        Spacer(minLength: 8)
                        Button(AppLocalization.localized("Choose Application…")) { browsing = true }
                    }
                    SettingsRow {
                        SettingsPicker("Input Method", selection: $selectedSource) {
                            if service.sources.isEmpty { Text(appLocalized: "Unavailable").tag("") }
                            ForEach(service.sources) { source in Text(source.name).tag(source.id) }
                        }
                        .disabled(service.sources.isEmpty)
                    }
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
        } footer: {
            Spacer()
            Button(AppLocalization.localized("Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(AppLocalization.localized("Add")) {
                guard canAdd, let applicationURL else { return }
                service.setRule(appURL: applicationURL, sourceID: selectedSource)
                if let serviceError = service.error { error = serviceError }
                else { dismiss() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canAdd)
        }
        .frame(width: 540, height: 280)
        .onAppear {
            selectedSource = service.sources.first { $0.id == service.currentSourceID }?.id
                ?? service.sources.first?.id ?? ""
        }
        .fileImporter(isPresented: $browsing, allowedContentTypes: [.application]) { result in
            switch result {
            case .success(let url):
                guard Bundle(url: url)?.bundleIdentifier != nil else {
                    error = AppLocalization.localized("Choose a valid application.")
                    return
                }
                applicationURL = url
                error = nil
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
        .fileDialogDefaultDirectory(URL(fileURLWithPath: "/Applications", isDirectory: true))
        .fileDialogCustomizationID("OneClick.InputMethodRule")
    }
}
