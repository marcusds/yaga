import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Naming

extension Hotkey {
    /// Symbols in the order Apple writes them, which is not the order the bits
    /// happen to sit in.
    static func modifierSymbols(_ modifiers: UInt32) -> String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out
    }

    /// Keys whose glyph does not come from the keyboard layout: either they
    /// produce no character at all, or the character they produce is invisible.
    static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←",
        kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_ANSI_KeypadEnter: "⌤", kVK_Help: "?⃝",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The character this key produces on the *current* layout — a Dvorak or
    /// AZERTY user should see the key they actually pressed, not the QWERTY
    /// letter that shares its code.
    static func keyLabel(_ keyCode: UInt32) -> String {
        if let special = specialKeyNames[Int(keyCode)] { return special }
        if let translated = translate(keyCode), !translated.isEmpty {
            return translated.uppercased()
        }
        return "Key \(keyCode)"
    }

    private static func translate(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layout = unsafeBitCast(data, to: CFData.self) as Data

        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)

        let status = layout.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

// MARK: - Validation

extension Hotkey {
    enum Problem: Equatable {
        case needsModifier
        case sameAsOther

        var message: String {
            switch self {
            case .needsModifier:
                return "Add ⌘, ⌥ or ⌃ — a shortcut without one would fire while you type."
            case .sameAsOther:
                return "That is already the other Yaga shortcut."
            }
        }
    }

    /// Shift alone does not count: ⇧A is a capital A, so claiming it globally
    /// would eat ordinary typing in every app.
    var hasRequiredModifier: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    func problem(against other: Hotkey?) -> Problem? {
        if !hasRequiredModifier { return .needsModifier }
        if let other, other == self { return .sameAsOther }
        return nil
    }

    /// Carbon keeps its own modifier bits, unrelated to AppKit's.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var out: UInt32 = 0
        if flags.contains(.command) { out |= UInt32(cmdKey) }
        if flags.contains(.option) { out |= UInt32(optionKey) }
        if flags.contains(.control) { out |= UInt32(controlKey) }
        if flags.contains(.shift) { out |= UInt32(shiftKey) }
        return out
    }
}

// MARK: - Sheet

/// Recording in a sheet rather than inline: the Settings rows stay ordinary
/// popup buttons, and Cancel is right there instead of being a keystroke the
/// user has to know about.
struct ShortcutRecorderSheet: View {
    @Binding var hotkey: Hotkey?
    var conflictsWith: Hotkey?
    var onFinish: () -> Void

    @State private var problem: String?

    var body: some View {
        VStack(spacing: 14) {
            Text("Press the shortcut you want")
                .font(.headline)

            HotkeyRecorder(
                hotkey: Binding(
                    get: { hotkey },
                    set: { value in
                        hotkey = value
                        onFinish()
                    }
                ),
                conflictsWith: conflictsWith,
                onProblem: { problem = $0.message }
            )
            .frame(width: 190, height: 34)

            Group {
                if let problem {
                    Text(problem)
                        .foregroundStyle(.orange)
                } else {
                    Text("Include ⌘, ⌥ or ⌃.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .multilineTextAlignment(.center)
            .frame(height: 30)

            Button("Cancel", role: .cancel) { onFinish() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(width: 300)
    }
}

// MARK: - Recorder

/// A field that shows a shortcut and, once clicked, adopts the next
/// combination pressed. `nil` means the shortcut is switched off, which only
/// the insert shortcut allows.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var hotkey: Hotkey?
    var conflictsWith: Hotkey?
    var onProblem: (Hotkey.Problem) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = { candidate in
            if let problem = candidate.problem(against: conflictsWith) {
                onProblem(problem)
                return false
            }
            hotkey = candidate
            return true
        }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.hotkey = hotkey
    }

    final class RecorderView: NSView {
        var hotkey: Hotkey? { didSet { needsDisplay = true } }
        /// Returns whether the capture was accepted; a rejected one keeps
        /// recording so the user can simply try again.
        var onCapture: ((Hotkey) -> Bool)?

        /// A click anywhere else in the window is a way out of recording. The
        /// responder chain alone would not give us one: nothing else in
        /// Settings takes first responder, so we would never be asked to
        /// resign it.
        private var clickMonitor: Any?

        private var isRecording = false {
            didSet {
                guard isRecording != oldValue else { return }
                needsDisplay = true
                isRecording ? startWatchingForClicks() : stopWatchingForClicks()
            }
        }

        deinit {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        }

        private func startWatchingForClicks() {
            stopWatchingForClicks()
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(point) { self.isRecording = false }
                return event
            }
        }

        private func stopWatchingForClicks() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }

        // Escape arrives as an action on the responder chain rather than as a
        // plain keyDown, so handling it in `capture` alone was not enough.
        override func cancelOperation(_ sender: Any?) {
            isRecording = false
        }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 22) }
        override var isFlipped: Bool { true }

        /// The recorder owns the sheet, so there is nothing else to click
        /// first: arm it as soon as it appears.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                isRecording = false
                return
            }
            window?.makeFirstResponder(self)
            isRecording = true
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            isRecording.toggle()
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return true
        }

        // ⌘-combinations reach the main menu as key equivalents before they
        // ever arrive as keyDown, so recording them means intercepting here.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return false }
            return capture(event)
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording, capture(event) else {
                super.keyDown(with: event)
                return
            }
        }

        private func capture(_ event: NSEvent) -> Bool {
            if event.keyCode == UInt16(kVK_Escape) {
                isRecording = false
                return true
            }
            let candidate = Hotkey(
                keyCode: UInt32(event.keyCode),
                modifiers: Hotkey.carbonModifiers(from: event.modifierFlags)
            )
            if onCapture?(candidate) == true { isRecording = false }
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlColor).setFill()
            rounded.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            rounded.lineWidth = isRecording ? 2 : 1
            rounded.stroke()

            let text: String
            if isRecording {
                text = "Press keys…"
            } else if let hotkey {
                text = hotkey.displayName
            } else {
                text = "Off"
            }
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: (isRecording || hotkey == nil) ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: style,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let origin = NSPoint(x: 0, y: (bounds.height - size.height) / 2)
            (text as NSString).draw(in: NSRect(origin: origin, size: NSSize(width: bounds.width, height: size.height)),
                                    withAttributes: attributes)
        }
    }
}
