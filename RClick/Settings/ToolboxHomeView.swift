import AppKit
import SwiftUI

struct ToolboxHomeView: View {
    let navigate: (Tabs) -> Void
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var inputMethods = InputMethodService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Label(AppLocalization.localized("YOUR MAC, MORE CAPABLE"), systemImage: "sparkle")
                        .font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(.teal)
                    Text(appLocalized: "Small tools. Smoother days.")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text(appLocalized: "A home for the tools that make everyday work on your Mac easier.")
                        .font(.body).foregroundStyle(.secondary)
                }.padding(.top, 12)

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(appLocalized: "Your Tools").font(.title3.bold())
                        Spacer()
                        Text("03").font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    toolCard(.actions, title: "Right-click Tools",
                             description: "Create files, open apps and run useful actions directly in Finder.",
                             detail: String(format: AppLocalization.localized("%lld actions configured"), appState.actions.count))
                    toolCard(.archives, title: "Archive Tools",
                             description: "Compress, extract and explore archives. Preview just the files you need.",
                             detail: "ZIP · 7Z · RAR · TAR")
                    toolCard(.inputMethods, title: "Input Method Switching",
                             description: "The right input method, ready when you switch applications.",
                             detail: AppLocalization.localized(inputMethods.configuration.enabled ? "Automatic Switching On" : "Automatic Switching Off"))
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text(appLocalized: "Quick Start").font(.headline)
                    ArchiveLaunchControls()
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 16))

                HStack(spacing: 8) {
                    Image(systemName: "menubar.rectangle")
                    Text(appLocalized: "Always close at hand in your menu bar.")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .padding(32).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func toolCard(_ tab: Tabs, title: String, description: String, detail: String) -> some View {
        Button { navigate(tab) } label: {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: tab.icon).font(.system(size: 24, weight: .medium))
                    .foregroundStyle(tab.iconColor).frame(width: 58, height: 58)
                    .background(tab.iconColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 7) {
                    Text(appLocalized: title).font(.headline).foregroundStyle(.primary)
                    Text(appLocalized: description).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.caption.weight(.medium)).foregroundStyle(tab.iconColor)
                }
                Spacer(minLength: 12)
                Image(systemName: "arrow.up.right").font(.callout.weight(.medium)).foregroundStyle(.tertiary)
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }
}
