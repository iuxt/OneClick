import AppKit
import SwiftUI

/// Show the row immediately, then fill in its system icon without blocking layout.
struct SettingsIcon: View {
    enum Source: Hashable {
        case application(URL)
        case fileType(String, fallback: String)
    }

    let source: Source
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "doc").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .task(id: source) {
            image = nil
            let loaded: NSImage?
            switch source {
            case .application(let url): loaded = await IconCache.shared.loadIcon(for: url)
            case .fileType(let ext, let fallback):
                loaded = await FileTypeIconProvider.shared.loadIcon(for: ext, fallbackSymbol: fallback)
            }
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
