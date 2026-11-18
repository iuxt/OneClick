import SwiftUI

struct EditAppSheetView: View {
    let app: OpenWithApp
    let appState: AppState

    @Environment(\.dismiss) private var dismiss
    @State private var itemName: String
    @State private var arguments: [Argument]
    @State private var environment: [Variable]
    @State private var opensNewInstance: Bool
    @State private var opensContainingDir: Bool?
    @State private var saveError: String?

    private struct Argument: Identifiable {
        let id = UUID()
        var value = ""
    }

    private struct Variable: Identifiable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    init(app: OpenWithApp, appState: AppState) {
        self.app = app
        self.appState = appState
        _itemName = State(initialValue: app.itemName)
        _arguments = State(initialValue: app.arguments.map { Argument(value: $0) })
        _environment = State(initialValue: app.environment.keys.sorted().map {
            Variable(key: $0, value: app.environment[$0, default: ""])
        })
        _opensNewInstance = State(initialValue: app.opensNewInstance)
        _opensContainingDir = State(initialValue: app.opensContainingDir)
    }

    private var environmentKeys: [String] {
        environment.map { $0.key.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private var validEnvironment: Bool {
        environmentKeys.allSatisfy { !$0.isEmpty && !$0.contains("=") && !$0.contains(where: \.isNewline) }
            && Set(environmentKeys).count == environmentKeys.count
    }

    var body: some View {
        SettingsSheet(title: "Edit App Properties", subtitle: app.name) {
            SettingsEditor {
                SettingsSection {
                    SettingsRow {
                        SettingsTextField(title: "Display Name", text: $itemName, prompt: Text(app.name))
                    }
                    SettingsRow {
                        SettingsSwitch("Open in a new window", isOn: $opensNewInstance)
                    }
                    SettingsRow {
                        SettingsPicker("Open Containing Folder", selection: $opensContainingDir) {
                            Text(appLocalized: "Follow App Preset").tag(nil as Bool?)
                            Text(appLocalized: "On").tag(true as Bool?)
                            Text(appLocalized: "Off").tag(false as Bool?)
                        }
                    }
                }

                SettingsSection(title: "Run Arguments") {
                    Button(AppLocalization.localized("Add Argument"), systemImage: "plus") { arguments.append(Argument()) }
                } content: {
                    if arguments.isEmpty { SettingsEmptyState(title: "No Arguments", symbol: "terminal") }
                    ForEach($arguments) { $argument in
                        SettingsRow {
                            TextField(AppLocalization.localized("Argument"), text: $argument.value)
                                .textFieldStyle(.roundedBorder)
                            SettingsIconButton(title: "Remove Argument", symbol: "minus.circle") {
                                arguments.removeAll { $0.id == argument.id }
                            }
                        }
                    }
                }

                SettingsSection(
                    title: "Environment Variables",
                    footer: validEnvironment ? nil : "Enter a unique variable name for each row. Names cannot contain an equals sign."
                ) {
                    Button(AppLocalization.localized("Add Variable"), systemImage: "plus") { environment.append(Variable()) }
                } content: {
                    if environment.isEmpty { SettingsEmptyState(title: "No Environment Variables", symbol: "list.bullet") }
                    ForEach($environment) { $variable in
                        SettingsRow {
                            TextField(AppLocalization.localized("Variable Name"), text: $variable.key)
                                .textFieldStyle(.roundedBorder)
                            TextField(AppLocalization.localized("Value"), text: $variable.value)
                                .textFieldStyle(.roundedBorder)
                            SettingsIconButton(title: "Remove Variable", symbol: "minus.circle") {
                                environment.removeAll { $0.id == variable.id }
                            }
                        }
                    }
                }
            }
        } footer: {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(AppLocalization.localized("Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(AppLocalization.localized("Save"), action: saveChanges)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!validEnvironment)
        }
        .frame(width: 600, height: 535)
    }

    private func saveChanges() {
        guard validEnvironment else { return }
        appState.updateApp(
            id: app.id,
            itemName: itemName,
            arguments: arguments.map(\.value),
            environment: Dictionary(uniqueKeysWithValues: zip(environmentKeys, environment.map(\.value))),
            opensNewInstance: opensNewInstance,
            opensContainingDir: opensContainingDir
        )
        saveError = appState.lastSaveError
        if saveError == nil { dismiss() }
    }
}
