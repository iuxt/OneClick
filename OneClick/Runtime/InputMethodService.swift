import AppKit
import Carbon
import Combine
import Foundation

nonisolated struct InputMethodSource: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

nonisolated struct InputMethodRule: Codable, Identifiable, Equatable, Sendable {
    var id: String { bundleID }
    let bundleID: String
    var name: String
    var sourceID: String
}

nonisolated struct InputMethodConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var defaultSourceID = ""
    var remember = false
    var rules: [InputMethodRule] = []
    var rememberedSources: [String: String] = [:]

    func target(for bundleID: String) -> String? {
        if let rule = rules.first(where: { $0.bundleID == bundleID }) { return rule.sourceID }
        if remember, let source = rememberedSources[bundleID] { return source }
        return defaultSourceID.isEmpty ? nil : defaultSourceID
    }
}

@MainActor
protocol InputMethodProviding {
    func sources() -> [InputMethodSource]
    func currentID() -> String?
    func select(_ id: String) -> Bool
}

/// Adapted from LockIME's TISInputSourceProvider (GPL-3.0); see docs/input-methods.md.
@MainActor
struct SystemInputMethodProvider: InputMethodProviding {
    private func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private func flag(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }

    private func all() -> [TISInputSource] {
        TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    func sources() -> [InputMethodSource] {
        all().compactMap { source in
            guard string(source, kTISPropertyInputSourceCategory) == kTISCategoryKeyboardInputSource as String,
                  flag(source, kTISPropertyInputSourceIsEnabled), flag(source, kTISPropertyInputSourceIsSelectCapable),
                  let id = string(source, kTISPropertyInputSourceID) else { return nil }
            return InputMethodSource(id: id, name: string(source, kTISPropertyLocalizedName) ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return string(source, kTISPropertyInputSourceID)
    }

    func select(_ id: String) -> Bool {
        guard let source = all().first(where: { string($0, kTISPropertyInputSourceID) == id }),
              flag(source, kTISPropertyInputSourceIsEnabled), flag(source, kTISPropertyInputSourceIsSelectCapable) else { return false }
        guard TISSelectInputSource(source) == noErr else { return false }
        // LockIME's fallback: some CJK input methods acknowledge a background
        // switch without applying it. Nudge only a verified mismatch, without
        // reactivating the foreground app or disturbing its pointer environment.
        if currentID() != id,
           let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
           let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String],
           languages.contains(where: { ["zh", "ja", "ko", "vi"].contains(String($0.prefix(2))) }) {
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 3, height: 3),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            window.orderOut(nil)
        }
        return true
    }
}

@MainActor
final class InputMethodService: ObservableObject {
    static let shared = InputMethodService()
    static let storageKey = "inputMethodConfiguration"

    @Published private(set) var configuration: InputMethodConfiguration
    @Published private(set) var sources: [InputMethodSource] = []
    @Published private(set) var currentSourceID: String?
    @Published private(set) var activeAppName = ""
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let provider: any InputMethodProviding
    private var activeBundleID: String?
    private var activationTask: Task<Void, Never>?
    private var sourceTask: Task<Void, Never>?
    private var switchingTask: Task<Void, Never>?
    private var switching = false

    init(defaults: UserDefaults = .group, provider: any InputMethodProviding = SystemInputMethodProvider()) {
        self.defaults = defaults
        self.provider = provider
        if let data = defaults.data(forKey: Self.storageKey) {
            do { configuration = try JSONDecoder().decode(InputMethodConfiguration.self, from: data) }
            catch {
                configuration = InputMethodConfiguration()
                self.error = AppLocalization.localized("Input method settings could not be loaded.")
            }
        } else { configuration = InputMethodConfiguration() }
        refresh()
    }

    func start() {
        guard activationTask == nil else { return }
        activateCurrentApp()
        activationTask = Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didActivateApplicationNotification) {
                guard !Task.isCancelled else { break }
                self?.activateCurrentApp()
            }
        }
        sourceTask = Task { [weak self] in
            let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
            for await _ in DistributedNotificationCenter.default().notifications(named: name) {
                guard !Task.isCancelled else { break }
                self?.sourceChanged()
            }
        }
    }

    func stop() {
        activationTask?.cancel(); activationTask = nil
        sourceTask?.cancel(); sourceTask = nil
        switchingTask?.cancel(); switchingTask = nil
        switching = false
    }

    func reloadConfiguration() {
        if let data = defaults.data(forKey: Self.storageKey) {
            do { configuration = try JSONDecoder().decode(InputMethodConfiguration.self, from: data); error = nil }
            catch { self.error = error.localizedDescription; return }
        } else { configuration = InputMethodConfiguration(); error = nil }
        activateCurrentApp()
    }

    func refresh() {
        sources = provider.sources()
        currentSourceID = provider.currentID()
    }

    func update(_ change: (inout InputMethodConfiguration) -> Void) {
        var updated = configuration
        change(&updated)
        do {
            let data = try JSONEncoder().encode(updated)
            defaults.set(data, forKey: Self.storageKey)
            configuration = updated
            error = nil
            activateCurrentApp()
        } catch { self.error = error.localizedDescription }
    }

    func setRule(appURL: URL, sourceID: String) {
        guard let bundle = Bundle(url: appURL), let id = bundle.bundleIdentifier else {
            error = AppLocalization.localized("Choose a valid application.")
            return
        }
        let name = FileManager.default.displayName(atPath: appURL.path)
        update {
            $0.rules.removeAll { $0.bundleID == id }
            $0.rules.append(InputMethodRule(bundleID: id, name: name, sourceID: sourceID))
            $0.rules.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func sourceChanged() {
        refresh()
        guard configuration.enabled, configuration.remember, !switching, !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == activeBundleID,
              let id = activeBundleID, let source = currentSourceID,
              !configuration.rules.contains(where: { $0.bundleID == id }),
              configuration.rememberedSources[id] != source else { return }
        // Do not reapply a rule when the user manually changes the input source.
        var updated = configuration
        updated.rememberedSources[id] = source
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: Self.storageKey)
            configuration = updated
        }
    }

    private func activateCurrentApp() {
        let app = NSWorkspace.shared.frontmostApplication
        activeAppName = app?.localizedName ?? ""
        activate(bundleID: app?.bundleIdentifier)
    }

    /// Cancel stale app switches and let macOS finish restoring its own input source.
    func activate(bundleID: String?) {
        switchingTask?.cancel()
        switching = false
        activeBundleID = bundleID
        refresh()
        guard configuration.enabled, let bundleID,
              bundleID != Bundle.main.bundleIdentifier,
              let target = configuration.target(for: bundleID) else { return }
        switching = true
        switchingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self else { return }
            defer { self.switching = false }
            // A bounded read-back handles input methods that report success before switching.
            for _ in 0..<3 {
                guard !Task.isCancelled, self.activeBundleID == bundleID else { return }
                if IsSecureEventInputEnabled() { return }
                if self.provider.currentID() == target { self.refresh(); return }
                guard self.provider.select(target) else {
                    self.error = AppLocalization.localized("The selected input method is unavailable. Enable it in System Settings.")
                    return
                }
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            }
            self.refresh()
            if self.currentSourceID != target {
                self.error = AppLocalization.localized("The input method could not be switched. Try selecting it again.")
            }
        }
    }
}
