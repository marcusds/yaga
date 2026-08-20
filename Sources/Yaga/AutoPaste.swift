import AppKit
import ApplicationServices

/// Pastes the copied GIF into whatever field the user was last typing in.
///
/// macOS gives no supported way to write an image straight into another app's
/// text field — the Accessibility API can set a string value, but nothing that
/// carries GIF data. So this does what a person would do: put the GIF on the
/// pasteboard, hand focus back to the app the user came from, and synthesise
/// ⌘V. That keystroke needs the Accessibility permission; without it the copy
/// still happens and the user pastes by hand.
@MainActor
enum AutoPaste {
    /// Whether we are allowed to post synthetic events yet.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks for the permission, showing the system prompt that deep-links to
    /// System Settings. Returns whether it was already granted.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Reactivates `app` and sends ⌘V once it is actually frontmost. Posting
    /// the keystroke too early delivers it to whatever still owns the focus,
    /// which at that moment is usually us.
    static func paste(into app: NSRunningApplication?) async -> Bool {
        guard isTrusted else { return false }

        if let app, !app.isActive {
            app.activate()
            await waitForActivation(of: app)
        }
        // Even once the app reports itself active, its key window needs a beat
        // to take first responder status.
        try? await Task.sleep(nanoseconds: 60_000_000)
        return postCommandV()
    }

    private static func waitForActivation(of app: NSRunningApplication) async {
        for _ in 0..<20 {
            if app.isActive { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private static let vKeyCode: CGKeyCode = 9

    private static func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return false }

        // Clear any modifiers the user is physically holding — a lingering
        // Option or Shift would turn this into a different command.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
