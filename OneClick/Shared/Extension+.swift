//
//  Extension+.swift
//  OneClick
//
//  Created by 李旭 on 2024/8/9.
//

import AppKit
import Foundation
import SwiftUI

extension View {
    func onBackground(_ f: @escaping () -> Void) -> some View {
        self.onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification),
            perform: { _ in f() }
        )
    }

    func onForeground(_ f: @escaping () -> Void) -> some View {
        self.onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
            perform: { _ in f() }
        )
    }
}

extension NSWindow {
    /// Keep standard window behavior while removing the extra title-bar layer.
    func applyOneClickChrome() {
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
    }
}

struct OneClickProgressBar: View {
    let fraction: Double?
    let accessibilityLabel: String

    init(fraction: Double?, accessibilityLabel: String) {
        self.fraction = fraction
        self.accessibilityLabel = accessibilityLabel
    }

    private var normalizedFraction: Double {
        min(1, max(0, fraction ?? 0))
    }

    var body: some View {
        if fraction == nil {
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
                .accessibilityLabel(accessibilityLabel)
        } else {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(0.10))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.72), Color.accentColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * normalizedFraction)
                }
            }
            .frame(height: 8)
            .animation(.smooth(duration: 0.25), value: normalizedFraction)
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue("\(Int((normalizedFraction * 100).rounded(.down)))%")
        }
    }
}
