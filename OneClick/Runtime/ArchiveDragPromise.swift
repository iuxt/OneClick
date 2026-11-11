import AppKit
import UniformTypeIdentifiers

/// A promise keeps the drag immediate; extraction begins only after the drop.
@MainActor
final class ArchiveDragPromise: NSObject, NSFilePromiseProviderDelegate {
    private let entry: ArchiveEntry
    private weak var model: ArchiveBrowserModel?

    init(entry: ArchiveEntry, model: ArchiveBrowserModel) {
        self.entry = entry
        self.model = model
        super.init()
    }

    func provider() -> NSFilePromiseProvider {
        let provider = NSFilePromiseProvider(fileType: (entry.isDirectory ? UTType.folder : .data).identifier, delegate: self)
        // NSFilePromiseProvider has a weak delegate. Keep it alive for the drop
        // without retaining the window or storing its password in the promise.
        provider.userInfo = self
        return provider
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        entry.name
    }

    // AppKit may call on a background queue. The completion is invoked exactly
    // once after the asynchronous extraction, including failure or cancellation.
    nonisolated private struct Completion: @unchecked Sendable {
        let call: (Error?) -> Void
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                        completionHandler: @escaping ((any Error)?) -> Void) {
        let completion = Completion(call: completionHandler)
        Task { @MainActor in
            guard let model else { completion.call(CancellationError()); return }
            do {
                try await model.extractDraggedEntry(entry, to: url)
                completion.call(nil)
            } catch { completion.call(error) }
        }
    }
}
