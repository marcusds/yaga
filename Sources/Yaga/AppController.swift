import AppKit
import SwiftUI

/// Owns the menu bar item, the popover, and the settings window.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static let shared = AppController()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    /// Closes the popover when the user moves to another app. A transient
    /// popover would close mid-drag, so dismissal is managed here instead.
    private var resignObserver: Any?
    private var keyMonitor: Any?
    private var reaperTimer: Timer?
    /// Set by the settings page. While it is up, an outside click must not
    /// dismiss the popover — the user is often in another app copying a key.
    var isShowingSettings = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        setUpStatusItem()
        setUpPopover()

        HotkeyManager.shared.onTrigger = { [weak self] in self?.togglePopover() }
        HotkeyManager.shared.start()
        installKeyHandling()
        startCacheReaper()
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
            Task { @MainActor in AppController.shared.reapCacheIfDue() }
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

    func togglePopover() {
        popover.isShown ? closePopover() : showPopover()
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            // Survive an app switch, so a trip to the browser for an API key
            // does not take the settings page with it.
            window.hidesOnDeactivate = false
            window.makeKey()
        }
        NotificationCenter.default.post(name: .popoverDidOpen, object: nil)
        startWatchingForDeactivation()
    }

    func closePopover() {
        isShowingSettings = false
        NotificationCenter.default.post(name: .dismissSettingsPage, object: nil)
        popover.performClose(nil)
        stopWatchingForDeactivation()
        // Hand focus back to whatever app the user was typing in.
        NSApp.hide(nil)
    }

    /// Dismiss on app deactivation rather than by watching for stray clicks.
    /// A global click monitor also fires for clicks AppKit routes outside the
    /// normal dispatch path — segmented controls and menu tracking among them —
    /// which dismissed the panel while the user was still using it. Losing
    /// active status cannot happen from a click inside our own window.
    private func startWatchingForDeactivation() {
        stopWatchingForDeactivation()
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let controller = AppController.shared
                // Settings stay put: the user may be off copying an API key.
                guard controller.popover.isShown, !controller.isShowingSettings else { return }
                controller.closePopover()
            }
        }
    }

    private func stopWatchingForDeactivation() {
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GifCache.shared.clearSessionFiles()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPopover()
        return true
    }
}
