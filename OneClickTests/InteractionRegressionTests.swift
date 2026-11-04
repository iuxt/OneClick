import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import OneClick

@MainActor
struct InteractionRegressionTests {
    @Test func emptySpaceActionsUseTheClickedFolderInsteadOfStaleSelection() {
        let folder = URL(fileURLWithPath: "/tmp/folder%20name")
        let selected = URL(fileURLWithPath: "/tmp/another/file.txt")
        #expect(FinderActionTargets.resolve(trigger: .contextualContainer, selected: [selected], container: folder) == [folder.path])
        #expect(FinderActionTargets.resolve(trigger: .contextualContainer, selected: [], container: folder) == [folder.path])
        #expect(FinderActionTargets.resolve(trigger: .contextualItems, selected: [selected], container: folder) == [selected.path])
        #expect(FinderActionTargets.resolve(trigger: .contextualItems, selected: [], container: folder).isEmpty)
    }

    @Test func launchOptionsKeepArgumentsEnvironmentAndRetryConfiguration() throws {
        let name = "oneclick-launch-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("--global; value with spaces", forKey: Key.globalApplicationArgumentsString)
        defaults.set("GLOBAL=one\nOVERRIDE=global", forKey: Key.globalApplicationEnvironmentString)
        var app = OpenWithApp(appURL: URL(fileURLWithPath: "/Applications/Example.app"))
        app.arguments = ["--flag", "literal;$HOME"]
        app.environment = ["OVERRIDE": "app=value", "EMPTY": ""]
        app.opensNewInstance = true
        let options = AppLaunchOptions(app: app, defaults: defaults)
        for config in [options.configuration(), options.configuration()] {
            #expect(config.arguments == ["--global", "value with spaces", "--flag", "literal;$HOME"])
            #expect(config.environment == ["GLOBAL": "one", "OVERRIDE": "app=value", "EMPTY": ""])
            #expect(config.createsNewApplicationInstance)
        }
        app.inheritFromGlobalArguments = false
        app.inheritFromGlobalEnvironment = false
        let explicit = AppLaunchOptions(app: app, defaults: defaults).configuration()
        #expect(explicit.arguments == app.arguments)
        #expect(explicit.environment == app.environment)
    }

    @Test func renameRequiresFinderTheExactSelectionAndNoActiveEditor() {
        let expected = URL(fileURLWithPath: "/tmp/Untitled.txt")
        func allowed(_ selected: [URL], role: String = kAXOutlineRole,
                     app: String = "com.apple.finder", modifiers: NSEvent.ModifierFlags = []) -> Bool {
            FinderRenameService.canRename(expected: expected, selected: selected, focusedRole: role,
                                          frontmostBundleID: app, modifiers: modifiers)
        }
        #expect(allowed([expected]))
        #expect(!allowed([expected], app: "com.apple.TextEdit"))
        #expect(!allowed([expected], role: kAXTextFieldRole))
        #expect(!allowed([expected], role: kAXTextAreaRole))
        #expect(!allowed([expected], modifiers: .command))
        #expect(!allowed([]))
        #expect(!allowed([expected, expected]))
        #expect(!allowed([URL(fileURLWithPath: "/tmp/another.txt")]))
    }

    @Test func creatingFromTemplatesAvoidsOverwritingExistingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-create-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let template = root.appendingPathComponent("template.txt")
        try Data("template".utf8).write(to: template)
        let results = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await FileActionWorker.create(in: root, extension: ".txt", template: template, baseName: "Untitled")
                }
            }
            var files: [URL] = []
            for try await file in group { files.append(file) }
            return files
        }
        #expect(Set(results).count == 4)
        for result in results { #expect(try Data(contentsOf: result) == Data("template".utf8)) }
        await #expect(throws: CocoaError.self) {
            try await FileActionWorker.create(in: root, extension: "/../../escape", template: nil, baseName: "Untitled")
        }
    }

    @Test func checksumGroupsKeepRowIdentityAndReflectResultsAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-checksum-ui-\(UUID())")
        try Data("abc".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ChecksumViewModel(inputs: [ChecksumInput(url: root), ChecksumInput(url: root, error: "denied")])
        let first = try #require(model.fileGroups.first?.rows.first)
        #expect(!model.hasResults)
        model.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isRunning)
        #expect(model.fileGroups.first?.rows.first === first)
        #expect(first.digest == "900150983cd24fb0d6963f7d28e17f72")
        #expect(model.hasResults)
        #expect(model.progress == 1)
        #expect(model.copyText.components(separatedBy: "\n").count == 3)
        model.cancel()
        #expect(first.digest != nil)
        let cancelled = ChecksumViewModel(inputs: [ChecksumInput(url: root)])
        cancelled.cancel()
        #expect(cancelled.rows.allSatisfy { $0.error == AppLocalization.localized("Cancelled") })
    }
}
