import AppKit
import SwiftUI
import Testing
@testable import OneClick

@MainActor
struct ArchiveWindowLayoutTests {
    @Test func closingConfigurationWindowPreservesItsFrame() async throws {
        let previous = Set(NSApp.windows.map(\.windowNumber))
        let presenter = ArchiveWindowPresenter()
        presenter.show(requests: [.init(operation: .compress, urls: [URL(fileURLWithPath: "/tmp/example.txt")])])
        let window = try #require(NSApp.windows.first { !previous.contains($0.windowNumber) && $0.isVisible })
        defer { window.orderOut(nil) }
        try await settle(window)
        let frame = window.frame

        window.performClose(nil)
        try await settle(window)

        #expect(!window.isVisible)
        #expect(window.frame == frame)
        withExtendedLifetime(presenter) {}
    }

    @Test func customWindowCannotBeManuallyResized() async throws {
        let previous = Set(NSApp.windows.map(\.windowNumber))
        let presenter = ArchiveWindowPresenter()
        presenter.show(requests: [.init(operation: .compress, urls: [URL(fileURLWithPath: "/tmp/example.txt")])])
        let window = try #require(NSApp.windows.first { !previous.contains($0.windowNumber) && $0.isVisible })
        defer { window.performClose(nil) }
        try await settle(window)
        #expect(!window.styleMask.contains(.resizable))
        #expect(abs(window.contentLayoutRect.width - 440) <= 1)
        #expect(window.contentLayoutRect.height > 350)
        #expect(window.frame.height <= (window.screen?.visibleFrame.height ?? 10000) + 1)
        let closeButton = try #require(window.standardWindowButton(.closeButton))
        let picker = try #require(window.titlebarAccessoryViewControllers.first?.view)
        let buttonCenter = closeButton.convert(NSPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY), to: nil)
        let pickerCenter = picker.convert(NSPoint(x: picker.bounds.midX, y: picker.bounds.midY), to: nil)
        #expect(abs(buttonCenter.y - pickerCenter.y) <= 1)
        #expect(pickerCenter.x > window.contentLayoutRect.midX)
        withExtendedLifetime(presenter) {}
    }

    @Test func formatAndValidationChangesResizeContentWithinScreenLimit() async throws {
        let model = ArchiveViewModel(requests: [.init(operation: .compress, urls: [URL(fileURLWithPath: "/tmp/example.txt")])])
        defer { model.cancel() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        var heights: [CGFloat] = []
        for format in [ArchiveCompressionFormat.zip, .sevenZip, .dmg] {
            var form = ArchiveFormState()
            form.format = format
            let root = ArchiveView(model: model, maximumContentHeight: 700, contentHeightChanged: { height in
                window.setContentSize(NSSize(width: 440, height: ceil(height)))
            }, close: {}, minimumContentWidth: 440, form: form)
            host.rootView = AnyView(root.id(UUID()))
            try await settle(window)
            heights.append(window.contentLayoutRect.height)
            #expect(window.contentLayoutRect.height >= 350)
            #expect(window.contentLayoutRect.height <= 701)
        }
        #expect(heights[1] > heights[0])
        var expanded = ArchiveFormState()
        expanded.format = .sevenZip
        expanded.volumeSizeText = "invalid volume"
        expanded.encrypted = true
        expanded.password = "password"
        expanded.confirmation = "different"
        host.rootView = AnyView(ArchiveView(model: model, maximumContentHeight: 450, contentHeightChanged: { height in
            window.setContentSize(NSSize(width: 440, height: ceil(height)))
        }, close: {}, minimumContentWidth: 440, form: expanded).id(UUID()))
        try await settle(window)
        #expect(window.contentLayoutRect.height <= 451)
        #expect(window.contentLayoutRect.height >= 449)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<12 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
