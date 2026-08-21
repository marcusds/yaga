import AppKit
import SwiftUI

/// Owns the menu bar item, the popover, and the settings window.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static let shared = AppController()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    /// Closes the popover on a click outside it. A transient popover would
    /// close mid-drag, so dismissal is managed here instead.
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var reaperTimer: Timer?
    /// Set by the settings page. While it is up, an outside click must not
    /// dismiss the popover — the user is often in another app copying a key.
    var isShowingSettings = false
    /// The app that was frontmost when the panel opened. Auto-paste hands
    /// focus back here before pressing ⌘V.
    private(set) var previousApp: NSRunningApplication?
    /// True when the panel was opened by the paste shortcut. Clicking the menu
    /// bar icon always opens in plain copy mode.
    private(set) var isPasteMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        setUpStatusItem()
        setUpPopover()

        HotkeyManager.shared.onTrigger = { [weak self] paste in self?.togglePopover(paste: paste) }
        HotkeyManager.shared.start()
        installKeyHandling()
        startCacheReaper()
        UpdateChecker.shared.checkIfDue()
    }

    /// An LSUIElement app shows no menu bar, but AppKit still routes command-key
    /// equivalents through the main menu — without an Edit menu, ⌘V does
    /// nothing in a text field. This menu exists purely for its shortcuts.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettingsMenuItem), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Yaga", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Yaga", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // Never rendered, so these exist only to bind ⌘+ / ⌘= / ⌘- .
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        for key in ["+", "="] {
            viewMenu.addItem(withTitle: "Larger GIFs", action: #selector(zoomIn), keyEquivalent: key).target = self
        }
        viewMenu.addItem(withTitle: "Smaller GIFs", action: #selector(zoomOut), keyEquivalent: "-").target = self
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    @objc private func zoomIn() { Settings.shared.zoom(by: 1) }
    @objc private func zoomOut() { Settings.shared.zoom(by: -1) }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Yaga")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Yaga — \(Settings.shared.hotkey.displayName)"
        }
    }

    private func setUpPopover() {
        let root = ContentView()
            .environmentObject(Library.shared)
            .environmentObject(Settings.shared)

        popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: 420, height: 520)
        popover.contentViewController = NSHostingController(rootView: root)
    }

    /// Expires and trims cached GIFs once a day. The timer ticks hourly but the
    /// work is gated on a persisted timestamp, so neither a machine that sleeps
    /// through the daily tick nor an app relaunched ten times in a morning
    /// changes how often the reaper actually runs.
    private func startCacheReaper() {
        reapCacheIfDue()
        reaperTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in
                AppController.shared.reapCacheIfDue()
                UpdateChecker.shared.checkIfDue()
            }
        }
    }

    private static let reapInterval: TimeInterval = 86_400

    func reapCacheIfDue(force: Bool = false) {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: "lastReapAt") as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) >= Self.reapInterval else { return }
        defaults.set(Date(), forKey: "lastReapAt")

        let protected = Library.shared.protectedMediaURLs
        Task.detached(priority: .background) {
            await GifCache.shared.trim(protecting: protected)
        }
    }

    /// An accessory app has no menu bar, so Escape / ⌘, / ⌘Q are wired up by hand.
    private func installKeyHandling() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Arrow keys, Return/Space and the 1–9 picks belong to the panel
            // before the search field sees them.
            if self.popover.isShown, !self.isShowingSettings, KeyNav.shared.handle(event) {
                return nil
            }

            let command = event.modifierFlags.contains(.command)
            switch (event.keyCode, command, event.charactersIgnoringModifiers) {
            case (53, _, _) where self.isShowingSettings:
                NotificationCenter.default.post(name: .dismissSettingsPage, object: nil)
                self.isShowingSettings = false
                return nil
            case (53, _, _) where self.popover.isShown:
                self.closePopover()
                return nil
            case (_, true, "q"):
                NSApp.terminate(nil)
                return nil
            case (_, true, ","):
                self.showSettings()
                return nil
            case (_, true, "w") where self.popover.isShown:
                self.closePopover()
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - Menu bar interaction

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Yaga (\(Settings.shared.hotkey.displayName))",
                     action: #selector(togglePopoverMenuItem), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettingsMenuItem), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Yaga", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePopoverMenuItem() { togglePopover() }
    @objc private func showSettingsMenuItem() { showSettings() }

    /// Settings live inside the popover, so this opens the panel if needed and
    /// flips it to the settings page.
    func showSettings() {
        if popover.isShown {
            NotificationCenter.default.post(name: .toggleSettingsPage, object: nil)
        } else {
            showPopover()
            NotificationCenter.default.post(name: .toggleSettingsPage, object: nil)
        }
    }

    func togglePopover(paste: Bool = false) {
        if popover.isShown {
            // Already up in the other mode: switch rather than close, so a
            // stray shortcut does not just dismiss the panel.
            if paste != isPasteMode {
                isPasteMode = paste
                NotificationCenter.default.post(
                    name: .popoverDidOpen, object: nil, userInfo: ["paste": paste]
                )
            } else {
                closePopover()
            }
        } else {
            showPopover(paste: paste)
        }
    }

    func showPopover(paste: Bool = false) {
        guard let button = statusItem.button else { return }
        isPasteMode = paste
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            // Survive an app switch, so a trip to the browser for an API key
            // does not take the settings page with it.
            window.hidesOnDeactivate = false
            window.makeKey()
        }
        NotificationCenter.default.post(name: .popoverDidOpen, object: nil, userInfo: ["paste": paste])
        startWatchingForOutsideClicks()
    }

    func closePopover() {
        isShowingSettings = false
        isPasteMode = false
        NotificationCenter.default.post(name: .dismissSettingsPage, object: nil)
        popover.performClose(nil)
        stopWatchingForOutsideClicks()
        // Hand focus back to whatever app the user was typing in.
        NSApp.hide(nil)
    }

    /// Closes the panel and pastes into the field the user came from.
    /// Returns false if the Accessibility permission is missing, in which case
    /// the GIF is still on the pasteboard for a manual ⌘V.
    func closeAndPaste() async -> Bool {
        let target = previousApp
        closePopover()
        return await AutoPaste.paste(into: target)
    }

    private func stopWatchingForOutsideClicks() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Dismiss on a click anywhere outside the panel, the way a menu does.
    ///
    /// Two things make this safe where an earlier outside-click monitor was
    /// not. A *global* monitor only sees events delivered to other
    /// applications, so clicks inside our own panel never reach it; and the
    /// panel's own frame is checked anyway, for the clicks AppKit routes
    /// outside the normal dispatch path -- segmented controls and menu
    /// tracking among them -- which is what dismissed the panel mid-use
    /// before.
    ///
    /// Only mouse-down is watched. Dragging a GIF out presses inside the panel
    /// and releases elsewhere, and closing on that release is exactly what
    /// made a transient popover unusable.
    private func startWatchingForOutsideClicks() {
        stopWatchingForOutsideClicks()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { _ in
            Task { @MainActor in
                AppController.shared.handleOutsideClick(at: NSEvent.mouseLocation)
            }
        }
    }

    private func handleOutsideClick(at point: NSPoint) {
        guard popover.isShown else { return }

        // Our own icon toggles the panel; closing here would race that.
        if let button = statusItem.button, let window = button.window,
           window.convertToScreen(button.frame).contains(point) { return }

        if let panel = popover.contentViewController?.view.window,
           panel.frame.contains(point) { return }

        guard Self.outsideClickCloses(
            isShowingSettings: isShowingSettings,
            needsAPIKey: Settings.shared.giphyKey.isEmpty,
            isInMenuBar: Self.isInMenuBar(point)
        ) else { return }

        closePopover()
    }

    /// Settings normally closes on an outside click like everything else. The
    /// exception is first-run setup: with no key entered yet the user is off
    /// in a browser fetching one, and closing the page would take away the
    /// field they are about to paste into. Reaching for the menu bar is
    /// unambiguous either way.
    nonisolated static func outsideClickCloses(
        isShowingSettings: Bool,
        needsAPIKey: Bool,
        isInMenuBar: Bool
    ) -> Bool {
        guard isShowingSettings, needsAPIKey, !isInMenuBar else { return true }
        return false
    }

    /// True when a screen point falls in the menu bar strip.
    static func isInMenuBar(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        else { return false }
        return menuBarContains(point, frame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    /// The strip's height is measured from the screen rather than assumed: a
    /// notch makes it taller than the usual 24 points. A secondary display
    /// with no menu bar reports no difference at all, so fall back to the
    /// status bar's own thickness rather than treating the whole screen as
    /// menu bar.
    nonisolated static func menuBarContains(_ point: NSPoint, frame: NSRect, visibleFrame: NSRect) -> Bool {
        let measured = frame.maxY - visibleFrame.maxY
        let height = measured > 0 ? measured : NSStatusBar.system.thickness
        return point.y >= frame.maxY - height
    }

    func applicationWillTerminate(_ notification: Notification) {
        GifCache.shared.clearNamedLinks()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPopover()
        return true
    }
}
