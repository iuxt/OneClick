import SwiftUI

@available(macOS 27, *)
struct ToolboxHomeView: View {
    let navigate: (Tabs) -> Void
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var inputMethods = InputMethodService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 16) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OneClick")
                            .font(.title.weight(.semibold))
                        Text(appLocalized: "Everyday Mac Toolkit")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 12) {
                    Text(appLocalized: "Your Tools")
                        .font(.headline)
                    VStack(spacing: 0) {
                        toolRow(.actions, title: "Right-click Tools",
                                description: "Create files, open apps and run useful actions directly in Finder.",
                                detail: String(format: AppLocalization.localized("%lld actions configured"), appState.actions.count))
                        Divider().padding(.leading, 60)
                        toolRow(.archives, title: "Archive Tools",
                                description: "Compress, extract and explore archives. Preview just the files you need.",
                                detail: "ZIP · 7Z · RAR · TAR")
                        Divider().padding(.leading, 60)
                        toolRow(.inputMethods, title: "Input Method Switching",
                                description: "The right input method, ready when you switch applications.",
                                detail: AppLocalization.localized(inputMethods.configuration.enabled ? "Automatic Switching On" : "Automatic Switching Off"))
                    }
                    // Content stays on a quiet surface; glass belongs to navigation
                    // and actions so text remains readable in either appearance.
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
                }

                Label(AppLocalization.localized("Always close at hand in your menu bar."), systemImage: "menubar.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func toolRow(_ tab: Tabs, title: String, description: String, detail: String) -> some View {
        Button { navigate(tab) } label: {
            HStack(spacing: 16) {
                Image(systemName: tab.icon)
                    .font(.system(size: 22, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(appLocalized: title).font(.headline)
                    Text(appLocalized: description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ToolNavigationButtonStyle())
    }
}

@available(macOS 27, *)
private struct ToolNavigationButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.08 : isHovered ? 0.04 : 0),
                        in: RoundedRectangle(cornerRadius: 10))
            .onHover { isHovered = $0 }
    }
}
