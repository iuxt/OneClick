import AppKit
import SwiftUI

/// Short actions finish without a window flashing; long disk work remains visible.
@MainActor
final class FileActionActivity {
    private var window: NSWindow?
    private var pending: Task<Void, Never>?

    init() {
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            let window = NSWindow(contentViewController: NSHostingController(rootView:
                HStack(spacing: 16) {
                    ProgressView().controlSize(.small)
                    Text(appLocalized: "Working on files…")
                }.padding(24)
            ))
            window.isReleasedWhenClosed = false
            window.title = "OneClick"
            window.styleMask = [.titled]
            window.center()
            window.orderFront(nil)
            self.window = window
        }
    }

    func finish() {
        pending?.cancel()
        pending = nil
        window?.close()
        window = nil
    }
}
