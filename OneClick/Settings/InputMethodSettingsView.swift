import AppKit
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 27, *)
struct InputMethodSettingsView: View {
    @Environment(\.isSettingsPageActive) private var isActive
    @ObservedObject private var service = InputMethodService.shared
    @State private var addingApp = false

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
            applicationRules
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
        .onChange(of: isActive) {
            if !isActive { addingApp = false }
        }
        .sheet(isPresented: $addingApp) {
            AddInputMethodRuleSheet(service: service)
        }
    }

    private var applicationRules: some View {
        Section {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(appLocalized: "Application Rules")
                        .font(.headline)
                    Text(verbatim: "\(service.configuration.rules.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    Spacer(minLength: 12)
                    Button(AppLocalization.localized("Add Application…"), systemImage: "plus") {
                        addingApp = true
                    }
                    .disabled(service.sources.isEmpty)
                }
                .padding(.bottom, 14)

                Divider()

                if service.configuration.rules.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "app.badge")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.tint)
                            .frame(width: 58, height: 58)
                            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityHidden(true)
                        Text(appLocalized: "No Application Rules")
                            .font(.headline)
                        Text(appLocalized: "Add an application and choose its preferred input method.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    ForEach(service.configuration.rules) { rule in
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
                        if rule.id != service.configuration.rules.last?.id {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Label(AppLocalization.localized("Switch to an application to use its assigned input method."), systemImage: "info.circle")
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
            Group {
                if let applicationURL {
                    SettingsIcon(source: .application(applicationURL))
                } else {
                    Image(systemName: "app.dashed")
                        .resizable().scaledToFit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(rule.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(rule.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(rule.bundleID)

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

            Button(role: .destructive, action: remove) {
                Image(systemName: "trash")
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(AppLocalization.localized("Remove Rule"))
            .accessibilityLabel(AppLocalization.localized("Remove Rule") + " · " + rule.name)
        }
        .padding(.vertical, 14)
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
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(appLocalized: "Add Application Rule")
                    .font(.title2.bold())
                Text(appLocalized: "Add an application and choose its preferred input method.")
                    .foregroundStyle(.secondary)
            }

            Button { browsing = true } label: {
                HStack(spacing: 12) {
                    Group {
                        if let applicationURL {
                            SettingsIcon(source: .application(applicationURL))
                        } else {
                            Image(systemName: "plus.app")
                                .resizable().scaledToFit().foregroundStyle(.tint)
                                .padding(5)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        if let applicationURL {
                            Text(FileManager.default.displayName(atPath: applicationURL.path))
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(Bundle(url: applicationURL)?.bundleIdentifier ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        } else {
                            Text(appLocalized: "Choose Application…")
                                .fontWeight(.medium)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .help(AppLocalization.localized("Choose Application…"))

            Picker(AppLocalization.localized("Input Method"), selection: $selectedSource) {
                if service.sources.isEmpty {
                    Text(appLocalized: "Unavailable").tag("")
                }
                ForEach(service.sources) { source in Text(source.name).tag(source.id) }
            }
            .disabled(service.sources.isEmpty)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }

            Divider()
            HStack {
                Spacer()
                Button(AppLocalization.localized("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppLocalization.localized("Add")) {
                    guard canAdd, let applicationURL else { return }
                    let scoped = applicationURL.startAccessingSecurityScopedResource()
                    defer { if scoped { applicationURL.stopAccessingSecurityScopedResource() } }
                    service.setRule(appURL: applicationURL, sourceID: selectedSource)
                    if let serviceError = service.error { error = serviceError }
                    else { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            selectedSource = service.sources.first { $0.id == service.currentSourceID }?.id
                ?? service.sources.first?.id ?? ""
        }
        .fileImporter(isPresented: $browsing, allowedContentTypes: [.application]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
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
