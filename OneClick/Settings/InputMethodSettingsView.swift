import AppKit
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 27, *)
struct InputMethodSettingsView: View {
    @ObservedObject private var service = InputMethodService.shared
    @State private var addingApp = false
    @State private var selectedSource = ""

    var body: some View {
        Form {
            Section {
                Toggle(AppLocalization.localized("Automatically switch input methods"), isOn: Binding(
                    get: { service.configuration.enabled },
                    set: { value in service.update { $0.enabled = value } }
                ))
                LabeledContent(AppLocalization.localized("Current Input Method")) {
                    Text(service.sources.first { $0.id == service.currentSourceID }?.name ?? "—")
                        .foregroundStyle(.secondary)
                }
                LabeledContent(AppLocalization.localized("Active Application"), value: service.activeAppName)
            } footer: {
                Text(appLocalized: "Switch input methods when you activate an application. Manual changes remain available until the next app switch.")
            }
            Section {
                Picker(AppLocalization.localized("Default Input Method"), selection: Binding(
                    get: { service.configuration.defaultSourceID },
                    set: { value in service.update { $0.defaultSourceID = value } }
                )) {
                    Text(appLocalized: "Keep Current Input Method").tag("")
                    sourceOptions(including: service.configuration.defaultSourceID)
                }
                Toggle(AppLocalization.localized("Remember input method for each application"), isOn: Binding(
                    get: { service.configuration.remember },
                    set: { value in service.update { $0.remember = value } }
                ))
            } footer: {
                Text(appLocalized: "Application rules take priority, followed by remembered input methods and the default. Secure password fields are respected.")
            }
            Section {
                ForEach(service.configuration.rules) { rule in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.name).fontWeight(.medium)
                            Text(rule.bundleID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker(AppLocalization.localized("Input Method"), selection: Binding(
                            get: { service.configuration.rules.first { $0.id == rule.id }?.sourceID ?? rule.sourceID },
                            set: { value in service.update { config in
                                if let index = config.rules.firstIndex(where: { $0.id == rule.id }) { config.rules[index].sourceID = value }
                            } }
                        )) { sourceOptions(including: rule.sourceID) }
                            .labelsHidden().frame(maxWidth: 220)
                        Button(role: .destructive) {
                            service.update { $0.rules.removeAll { $0.id == rule.id } }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help(AppLocalization.localized("Remove Rule"))
                    }
                }
                if service.configuration.rules.isEmpty {
                    Text(appLocalized: "Add an application and choose its preferred input method.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Picker(AppLocalization.localized("Input Method"), selection: $selectedSource) {
                        ForEach(service.sources) { source in Text(source.name).tag(source.id) }
                    }
                    Button(AppLocalization.localized("Add Application…"), systemImage: "plus") { addingApp = true }
                        .disabled(selectedSource.isEmpty)
                }
            } header: { Text(appLocalized: "Application Rules") }
            if let error = service.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            Section {
                HStack {
                    Button(AppLocalization.localized("Refresh Input Methods")) { service.refresh() }
                    Spacer()
                    Link("LockIME · GPL-3.0", destination: URL(string: "https://github.com/oomol-lab/LockIME")!)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            service.refresh()
            selectedSource = service.currentSourceID ?? service.sources.first?.id ?? ""
        }
        .fileImporter(isPresented: $addingApp, allowedContentTypes: [.application]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                service.setRule(appURL: url, sourceID: selectedSource)
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
