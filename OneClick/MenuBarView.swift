//
//  MenuBarView.swift
//  OneClick
//
//  Created by 李旭 on 2024/4/4.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Open settings window

/// Brings the settings window forward. OneClick is an LSUIElement app, so it
/// must activate itself explicitly after opening the window.
@MainActor
func showSettingsWindow(openWindow: OpenWindowAction) {
    openWindow(id: Constants.settingsWindowID)

    if let existingWindow = NSApplication.shared.windows.first(where: {
        $0.identifier?.rawValue == Constants.settingsWindowID
    }) {
        existingWindow.makeKeyAndOrderFront(nil)
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
}

/// Owned by the settings Scene, so hiding the menu bar icon or closing the last
/// window never removes the receiver for a manual launch/reopen request.
@MainActor
final class SettingsWindowRequests: ObservableObject {
    @Published private(set) var generation = 0
    private var subscription: AnyCancellable?

    init(center: NotificationCenter = .default) {
        subscription = center.publisher(for: .openSettingsRequested)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.generation += 1
                }
            }
    }
}

struct OneClickMenuBarLabel: View {
    var body: some View {
        Image("MenuBar")
            .resizable()
            .scaledToFit()
            .frame(width: 22, height: 22)
            .accessibilityLabel("OneClick")
    }
}

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow

    private let messager = Messager.shared

    var body: some View {
        footer
            .frame(width: 240)
            .background(.regularMaterial)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: actionSettings) {
                Label(AppLocalization.localized("Settings"), systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: [.command])

            Spacer()

            Button(action: actionQuit) {
                Label(AppLocalization.localized("Quit"), systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .buttonStyle(.borderless)
        .padding(12)
    }

    @MainActor
    private func actionSettings() {
        showSettingsWindow(openWindow: openWindow)
    }

    @MainActor
    private func actionQuit() {
        messager.sendQuitNotification()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            NSApplication.shared.terminate(self)
        }
    }
}

#Preview {
    MenuBarView()
}
