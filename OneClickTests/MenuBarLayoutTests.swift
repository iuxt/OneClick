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

}
