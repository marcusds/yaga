import AppKit
import SwiftUI

/// Animated GIF rendering. NSImageView plays GIFs natively, which SwiftUI's
/// `Image` does not, so the grid cells wrap one.
struct AnimatedGif: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> VisibleOnlyImageView {
        let view = VisibleOnlyImageView()
        view.imageScaling = .scaleAxesIndependently
        view.canDrawSubviewsIntoLayer = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = NSImage(data: data)
        return view
    }

    func updateNSView(_ view: VisibleOnlyImageView, context: Context) {
        if context.coordinator.data != data {
            context.coordinator.data = data
            view.image = NSImage(data: data)
            view.updateAnimation()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(data: data) }

    final class Coordinator {
        var data: Data
        init(data: Data) { self.data = data }
    }
}

/// An image view that animates only while its window is on screen. The
/// popover's views outlive the popover, and a closed panel full of GIFs would
/// otherwise keep decoding frames and waking the CPU in the background.
final class VisibleOnlyImageView: NSImageView {
    private var occlusionObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAnimation() }
            }
        }
        updateAnimation()
    }

    func updateAnimation() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        if animates != visible { animates = visible }
    }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }
}

/// Loads a GIF's preview bytes, shows a shimmering placeholder until they land,
/// and pre-fetches the full-size GIF so drag-out works immediately.
@MainActor
final class GifCellModel: ObservableObject {
    @Published var preview: Data?
    @Published var fullFile: URL?
    @Published var failed = false

    private var loadTask: Task<Void, Never>?

    func load(_ item: GifItem) {
        guard preview == nil, loadTask == nil else { return }
        fullFile = GifCache.shared.cachedFileIfPresent(for: item)
        loadTask = Task {
            do {
                let data = try await GifCache.shared.data(for: item.previewURL)
                self.preview = data
            } catch {
                self.failed = true
            }
            // Warm the full-size GIF in the background for copy / drag.
            if self.fullFile == nil {
                self.fullFile = try? await GifCache.shared.fileOnDisk(for: item)
            }
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }
}
