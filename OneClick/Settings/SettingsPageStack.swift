import SwiftUI

extension EnvironmentValues {
    @Entry var isSettingsPageActive = true
}

/// Keep visited Forms alive so navigation does not recreate their controls,
/// reload icons or discard scroll positions. Unvisited pages cost nothing.
@available(macOS 27, *)
struct SettingsPageStack<Content: View>: View {
    let selection: Tabs
    @ViewBuilder var content: (Tabs) -> Content
    @State private var visited: Set<Tabs> = []

    var body: some View {
        ZStack {
            ForEach(Tabs.allCases) { tab in
                if tab == selection || visited.contains(tab) {
                    content(tab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.isSettingsPageActive, tab == selection)
                        .opacity(tab == selection ? 1 : 0)
                        .disabled(tab != selection)
                        .allowsHitTesting(tab == selection)
                        .accessibilityHidden(tab != selection)
                        .zIndex(tab == selection ? 1 : 0)
                }
            }
        }
        .onChange(of: selection, initial: true) { visited.insert(selection) }
    }
}
