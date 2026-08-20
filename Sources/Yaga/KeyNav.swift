import AppKit
import SwiftUI

/// Keyboard navigation for the panel.
///
/// The search field keeps first responder status the whole time the panel is
/// open — letters always reach it, wherever the selection sits. This object
/// intercepts only the navigation keys, before AppKit hands them to the field,
/// so there is no focus to juggle and no beep when a key means nothing here.
@MainActor
final class KeyNav: ObservableObject {
    static let shared = KeyNav()

    enum Zone { case search, shelf, grid }

    @Published private(set) var zone: Zone = .search
    @Published private(set) var selection = 0

    /// Refreshed by the view on every render.
    var itemCount = 0
    var columns = 3
    /// The shelf tabs are hidden while a search is running.
    var hasShelfBar = true
    var queryIsEmpty = true

    var onActivate: ((Int) -> Void)?
    var onShelfStep: ((Int) -> Void)?

    private init() {}

    func reset() {
        zone = .search
        selection = 0
    }

    /// Typing pulls focus back to the field: results are about to change, so a
    /// selection into the old ones is meaningless.
    func queryDidChange() {
        zone = .search
        selection = 0
    }

    func clampSelection() {
        if selection >= itemCount { selection = max(itemCount - 1, 0) }
        if itemCount == 0, zone == .grid { zone = .search }
    }

    // MARK: - Key handling

    private enum Code {
        static let ret: UInt16 = 36
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let escape: UInt16 = 53
        static let keypadEnter: UInt16 = 76
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    /// Returns true when the key was consumed and must not reach the field.
    func handle(_ event: NSEvent) -> Bool {
        // Anything with Command belongs to the menu shortcuts.
        guard !event.modifierFlags.contains(.command) else { return false }

        if let digit = digitIndex(for: event) {
            // In the search field a digit types normally once there is text to
            // add to — it only picks a GIF as the opening keystroke.
            guard zone != .search || queryIsEmpty else { return false }
            guard digit < itemCount else { return true }
            onActivate?(digit)
            return true
        }

        switch event.keyCode {
        case Code.down: return moveDown()
        case Code.up: return moveUp()
        case Code.left: return step(-1)
        case Code.right: return step(1)
        case Code.tab: return moveDown()
        case Code.ret, Code.keypadEnter, Code.space: return activate(isSpace: event.keyCode == Code.space)
        case Code.escape: return backOut()
        default: return false
        }
    }

    private func digitIndex(for event: NSEvent) -> Int? {
        guard let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let value = Int(characters),
              (1...9).contains(value)
        else { return nil }
        return value - 1
    }

    private func moveDown() -> Bool {
        switch zone {
        case .search:
            if hasShelfBar {
                zone = .shelf
            } else if itemCount > 0 {
                zone = .grid
                selection = 0
            }
            return true
        case .shelf:
            guard itemCount > 0 else { return true }
            zone = .grid
            selection = 0
            return true
        case .grid:
            let next = selection + columns
            // Short final row: fall to its last cell rather than nowhere.
            if next < itemCount {
                selection = next
            } else if selection < itemCount - 1, next >= itemCount {
                selection = itemCount - 1
            }
            return true
        }
    }

    private func moveUp() -> Bool {
        switch zone {
        case .search:
            return false
        case .shelf:
            zone = .search
            return true
        case .grid:
            if selection >= columns {
                selection -= columns
            } else {
                zone = hasShelfBar ? .shelf : .search
            }
            return true
        }
    }

    private func step(_ delta: Int) -> Bool {
        switch zone {
        case .search:
            // Leave the text cursor alone.
            return false
        case .shelf:
            onShelfStep?(delta)
            return true
        case .grid:
            let next = selection + delta
            if (0..<itemCount).contains(next) { selection = next }
            return true
        }
    }

    private func activate(isSpace: Bool) -> Bool {
        switch zone {
        case .grid:
            onActivate?(selection)
            return true
        case .shelf:
            // Space would otherwise type into the hidden-but-focused field.
            return isSpace
        case .search:
            return false
        }
    }

    /// Escape walks back up the panel before it closes it.
    private func backOut() -> Bool {
        switch zone {
        case .grid:
            zone = hasShelfBar ? .shelf : .search
            return true
        case .shelf:
            zone = .search
            return true
        case .search:
            return false
        }
    }
}
