import AppKit
import UniformTypeIdentifiers

enum Clipboard {
    /// Puts a GIF on the general pasteboard in every flavour receiving apps
    /// tend to ask for: the raw GIF bytes, a file URL, and a plain-text link.
    static func copy(item: GifItem, data: Data, file: URL, mode: CopyMode) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let entry = NSPasteboardItem()
        switch mode {
        case .gif:
            entry.setData(data, forType: .init(UTType.gif.identifier))
            entry.setData(data, forType: .init("com.compuserve.gif"))
            entry.setString(file.absoluteString, forType: .fileURL)
            // Some editors only accept a text drop; a link is better than nothing.
            entry.setString((item.sourceURL ?? item.gifURL).absoluteString, forType: .string)
        case .link:
            let link = (item.sourceURL ?? item.gifURL).absoluteString
            entry.setString(link, forType: .string)
            entry.setString(link, forType: .URL)
        }
        pasteboard.writeObjects([entry])
    }

    /// The provider handed to SwiftUI's `.onDrag`, which must be built synchronously.
    static func dragProvider(for item: GifItem, file: URL?) -> NSItemProvider {
        if let file, let provider = NSItemProvider(contentsOf: file) {
            provider.suggestedName = file.lastPathComponent
            return provider
        }
        // Not downloaded yet — drop the link so the gesture still does something.
        return NSItemProvider(object: (item.sourceURL ?? item.gifURL).absoluteString as NSString)
    }
}
