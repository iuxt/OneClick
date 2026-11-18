import AppKit
import SwiftUI
import Testing
@testable import OneClick

@MainActor
struct MenuBarLayoutTests {
    @Test func mainIconHasAnExplicitMenuBarSize() {
        let view = NSHostingView(rootView: OneClickMenuBarLabel())
        #expect(view.fittingSize == NSSize(width: 20, height: 20))
    }

    @Test func menuBarAssetHasNativeStatusBarSize() throws {
        let image = try #require(NSImage(named: "MenuBar"))
        #expect(image.size == NSSize(width: 20, height: 20))
        #expect(image.isTemplate)
    }
}
