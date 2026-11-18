import AppKit
import SwiftUI
import Testing
@testable import OneClick

@MainActor
struct MenuBarLayoutTests {
    @Test func mainIconHasAnExplicitMenuBarSize() {
        let view = NSHostingView(rootView: OneClickMenuBarLabel())
        #expect(view.fittingSize == NSSize(width: 22, height: 22))
    }

    @Test func menuBarAssetHasNativeStatusBarSize() throws {
        let image = try #require(NSImage(named: "MenuBar"))
        #expect(image.size == NSSize(width: 22, height: 22))
        #expect(image.isTemplate)
    }
}
