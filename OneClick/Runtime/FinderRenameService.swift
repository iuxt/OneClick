import AppKit
import ApplicationServices

@MainActor
final class FinderRenameService {
    static let shared = FinderRenameService()
    private var pending: Task<Void, Never>?

    func renameWhenReady(_ url: URL) {
        pending?.cancel()
        pending = Task {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            // Never activate Finder after a delay: the user may have switched apps.
            guard AXIsProcessTrusted(),
                  let finder = NSWorkspace.shared.frontmostApplication,
                  finder.bundleIdentifier == "com.apple.finder" else { return }
            let context = await FinderSelectionReader.read(pid: finder.processIdentifier)
            guard !Task.isCancelled,
                  Self.canRename(expected: url, selected: context.urls, focusedRole: context.role,
                                 frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                 modifiers: NSEvent.modifierFlags) else { return }
            // Address Finder's PID explicitly. A last-moment app switch must never
            // deliver Return to another application's dialog or editor.
            let source = CGEventSource(stateID: .privateState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
            down?.flags = []; up?.flags = []
            down?.postToPid(finder.processIdentifier)
            up?.postToPid(finder.processIdentifier)
        }
    }

    static func canRename(expected: URL, selected: [URL], focusedRole: String?,
                          frontmostBundleID: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        focusedRole != nil && frontmostBundleID == "com.apple.finder" && selected.count == 1
            && selected.first?.standardizedFileURL == expected.standardizedFileURL
            && ![kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(focusedRole ?? "")
            && modifiers.intersection([.command, .control, .option, .shift]).isEmpty
    }

}

nonisolated private enum FinderSelectionReader {
    struct Context: Sendable { let urls: [URL]; let role: String? }

    @concurrent
    static func read(pid: pid_t) async -> Context {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.03)
        let deadline = ContinuousClock.now + .milliseconds(200)
        guard let focused = element(application, kAXFocusedUIElementAttribute) else { return Context(urls: [], role: nil) }
        let role = attribute(focused, kAXRoleAttribute) as? String
        let window = element(application, kAXFocusedWindowAttribute)
        let urls = selectedURLs(in: focused, deadline: deadline)
            ?? window.flatMap { selectedURLs(in: $0, deadline: deadline) } ?? []
        return Context(urls: urls, role: role)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, 32, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func fileURL(_ element: AXUIElement, deadline: ContinuousClock.Instant, depth: Int = 0) -> URL? {
        guard ContinuousClock.now < deadline else { return nil }
        if let url = attribute(element, kAXURLAttribute) as? URL, url.isFileURL { return url }
        guard depth < 3 else { return nil }
        return children(element).lazy.compactMap { fileURL($0, deadline: deadline, depth: depth + 1) }.first
    }

    private static func selectedURLs(in root: AXUIElement, deadline: ContinuousClock.Instant) -> [URL]? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty && visited < 128 && ContinuousClock.now < deadline {
            let item = queue.removeFirst()
            visited += 1
            for name in [kAXSelectedChildrenAttribute, kAXSelectedRowsAttribute] {
                if let selected = attribute(item, name) as? [AXUIElement], !selected.isEmpty {
                    // All selected items must resolve; never rename an ambiguous selection.
                    guard selected.count == 1, let first = selected.first,
                          let url = fileURL(first, deadline: deadline) else { return [] }
                    return [url]
                }
            }
            queue.append(contentsOf: children(item))
        }
        return nil
    }
}
