import AppKit
import SwiftUI
import Testing
@testable import Kit
@testable import OneClick

@MainActor
struct MenuBarLayoutTests {
    @Test func mainIconHasAnExplicitMenuBarSize() {
        let view = NSHostingView(rootView: OneClickMenuBarLabel())
        #expect(view.fittingSize == NSSize(width: 18, height: 18))
    }

    @Test(arguments: [22.0, 24.0, 37.0])
    func statusContentKeepsItsDrawingSizeAndCentersInTallerBars(height: Double) {
        let widget = WidgetWrapper(.mini, title: "Layout", frame: NSRect(x: 0, y: 2, width: 31.5, height: 18))
        let host = StatusItemContentView(content: widget)
        host.frame.size.height = height
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()

        #expect(host.bounds.contains(widget.frame))
        #expect(widget.frame.width == 31.5)
        #expect(widget.frame.height == 18)
        #expect(widget.frame.midY == host.bounds.midY)
        #expect(widget.frame.minX >= 6)
        #expect(host.bounds.maxX - widget.frame.maxX >= 6)
        #expect(Kit.Constants.Widget.height == 22)
    }

    @Test func combinedWidgetsReflowAfterAValueChangesWidth() async throws {
        let name = "Layout-\(UUID())"
        Store.shared.set(key: "\(name)_oneView", value: true)
        Store.shared.set(key: "\(name)_widget", value: "mini,speed")
        let bar = Kit.MenuBar(moduleName: name)
        let first = WidgetWrapper(.mini, title: name, frame: NSRect(x: 0, y: 2, width: 31, height: 18))
        let second = WidgetWrapper(.speed, title: name, frame: NSRect(x: 0, y: 2, width: 58, height: 18))
        let image = NSImage(size: NSSize(width: 1, height: 1))
        bar.append(SWidget(.mini, defaultWidget: .mini, module: name, item: first, image: image))
        bar.append(SWidget(.speed, defaultWidget: .mini, module: name, item: second, image: image))
        defer {
            bar.disable()
            Store.shared.remove("\(name)_oneView")
            Store.shared.remove("\(name)_widget")
        }

        bar.enable()
        for _ in 0..<50 {
            if bar.view.subviews.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(bar.view.subviews.count == 2)
        // Width changes come from drawing and must also move the next widget.
        first.setWidth(84.5)
        for _ in 0..<50 {
            if first.frame.width == 84.5 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let ordered = bar.view.subviews.sorted { $0.frame.minX < $1.frame.minX }
        let left = try #require(ordered.first)
        let right = try #require(ordered.last)
        #expect(left.frame.maxX + Kit.Constants.Widget.spacing <= right.frame.minX)
        #expect(bar.view.bounds.contains(left.frame))
        #expect(bar.view.bounds.contains(right.frame))
        let host = try #require(bar.view.superview as? StatusItemContentView)
        #expect(host.bounds.contains(bar.view.frame))
        #expect(host.bounds.maxX - bar.view.frame.maxX >= 6)
    }

    @Test func separateWidgetRetainsPaddingWhenResizedAndReenabled() async throws {
        let name = "Layout-\(UUID())"
        let item = WidgetWrapper(.mini, title: name, frame: NSRect(x: 0, y: 2, width: 31, height: 18))
        let widget = SWidget(.mini, defaultWidget: .mini, module: name, item: item, image: NSImage(size: NSSize(width: 1, height: 1)))
        defer { widget.setMenuBarItem(state: false) }
        for width in [31.0, 130.5] {
            widget.setMenuBarItem(state: true)
            for _ in 0..<50 {
                if item.superview != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            item.setWidth(width)
            for _ in 0..<50 {
                if item.frame.width == width { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let host = try #require(item.superview as? StatusItemContentView)
            #expect(host.superview is NSStatusBarButton)
            #expect(host.bounds.contains(item.frame))
            #expect(item.frame.minX >= 6)
            #expect(host.bounds.maxX - item.frame.maxX >= 6)
            #expect(item.frame.midY == host.bounds.midY)
            widget.setMenuBarItem(state: false)
            for _ in 0..<50 {
                if item.superview == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(item.superview == nil)
        }
    }

    @Test func longMonitorValuesGrowBeyondTheirOriginalFixedWidths() async throws {
        let mini = Mini(title: "Layout", config: nil, preview: true)
        mini.setValue(1)
        mini.setSuffix(" percent")
        let memory = MemoryWidget(title: "Layout", config: nil, preview: true)
        memory.setValue(("1024.00 GB", "9999.00 GB"), usedPercentage: 0.5)
        let speed = SpeedWidget(title: "Layout", config: nil, preview: true)
        speed.setValue(input: 999_999_999, output: 888_888_888)
        let widgets: [WidgetWrapper] = [mini, memory, speed]
        for widget in widgets {
            let bitmap = try #require(widget.bitmapImageRepForCachingDisplay(in: widget.bounds))
            widget.cacheDisplay(in: widget.bounds, to: bitmap)
        }
        try await Task.sleep(for: .milliseconds(20))
        let percentWidth = NSAttributedString(string: "100 percent", attributes: [.font: NSFont.systemFont(ofSize: 12)]).size().width
        let memoryWidth = NSAttributedString(string: "9999.00 GB", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .light)]).size().width
        let speedWidth = NSAttributedString(string: Units(bytes: 999_999_999).getReadableSpeed(), attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .light)]).size().width
        #expect(mini.frame.width >= percentWidth)
        #expect(memory.frame.width >= memoryWidth + 12) // F:/U: labels and gap
        #expect(speed.frame.width >= speedWidth + 7) // Direction icon
    }
}
