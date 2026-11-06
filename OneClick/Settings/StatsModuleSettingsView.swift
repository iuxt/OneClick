import AppKit
import Kit
import SwiftUI

/// Embeds the same settings instance owned by the running Stats module. Its
/// internal scroll views handle long module, widget, popup and notification tabs.
struct StatsModuleSettingsView: NSViewRepresentable {
    let module: Module
    let isActive: Bool
    let showsPreview: Bool

    func makeNSView(context: Context) -> StatsSettingsContainer {
        StatsSettingsContainer()
    }

    func updateNSView(_ view: StatsSettingsContainer, context: Context) {
        view.configure(module: module, isActive: isActive, showsPreview: showsPreview)
    }

    static func dismantleNSView(_ view: StatsSettingsContainer, coordinator: ()) {
        view.detach()
    }
}

@MainActor
final class StatsSettingsContainer: NSView {
    private var module: Module?
    private var isActive = false
    private var visibleModuleName: String?

    func configure(module: Module, isActive: Bool, showsPreview: Bool) {
        if self.module !== module {
            subviews.forEach { $0.removeFromSuperview() }
            self.module = module
            if let settings = module.window {
                settings.translatesAutoresizingMaskIntoConstraints = false
                addSubview(settings)
                NSLayoutConstraint.activate([
                    settings.leadingAnchor.constraint(equalTo: leadingAnchor),
                    settings.trailingAnchor.constraint(equalTo: trailingAnchor),
                    settings.topAnchor.constraint(equalTo: topAnchor),
                    settings.bottomAnchor.constraint(equalTo: bottomAnchor)
                ])
            }
        }
        self.isActive = isActive
        module.window?.setPreviewVisible(showsPreview)
        updateReaderVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification,
                         NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
        }
        updateReaderVisibility()
    }

    @objc private func windowChanged(_ notification: Notification) {
        updateReaderVisibility(closing: notification.name == NSWindow.willCloseNotification)
    }

    private func updateReaderVisibility(closing: Bool = false) {
        let visible = isActive && !closing && window?.isVisible == true
            && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
        let name = visible ? module?.name : nil
        guard name != visibleModuleName else { return }
        visibleModuleName = name
        var info: [String: Any] = ["state": name != nil]
        if let name { info["module"] = name }
        NotificationCenter.default.post(name: .openWindow, object: self, userInfo: info)
    }

    func detach() {
        isActive = false
        updateReaderVisibility()
        NotificationCenter.default.removeObserver(self)
        subviews.forEach { $0.removeFromSuperview() }
        module = nil
    }

    override func mouseDown(with event: NSEvent) {
        NotificationCenter.default.post(name: .clickInSettings, object: nil)
        super.mouseDown(with: event)
    }
}
