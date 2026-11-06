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
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(appLocalized: "Working on files…")
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            ))
            window.isReleasedWhenClosed = false
            window.title = AppLocalization.localized("Working on files…")
            window.styleMask = [.titled]
            window.applyOneClickChrome()
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
