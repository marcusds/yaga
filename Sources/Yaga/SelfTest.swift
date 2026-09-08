import AppKit
import Carbon.HIToolbox
import Foundation

/// `Yaga --self-test` exercises the cache end to end: naming stability,
/// hard linking, LRU eviction, age expiry, and protection of favourites.
/// The reaper is easy to get silently wrong, so it is worth being able to run.
enum SelfTest {
    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ label: String, _ condition: Bool) {
            print("\(condition ? "  ok  " : "  FAIL") \(label)")
            if !condition { failures.append(label) }
        }

        let cache = GifCache.shared
        await cache.clear()

        // Blob names must be derived from the URL, not from a per-process hash.
        let sample = URL(string: "https://example.com/a.gif")!
        let key = GifCache.key(for: sample)
        check("key is a stable 20-char digest", key.count == 20 && key == GifCache.key(for: sample))
        check("key differs per URL", key != GifCache.key(for: URL(string: "https://example.com/b.gif")!))

        // Three ~1 MB GIFs served from local files.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yaga-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var items: [GifItem] = []
        for index in 0..<3 {
            let file = scratch.appendingPathComponent("source\(index).gif")
            try? Data(repeating: UInt8(index + 1), count: 1_048_576).write(to: file)
            items.append(GifItem(
                id: "test:\(index)", title: "Test GIF \(index)",
                previewURL: file, gifURL: file, width: 100, height: 100, sourceURL: nil
            ))
        }

        var links: [URL] = []
        for item in items {
            guard let link = try? await cache.fileOnDisk(for: item) else {
                check("cached \(item.id)", false)
                continue
            }
            links.append(link)
            // Two seconds apart so eviction order is unambiguous.
            try? await Task.sleep(nanoseconds: 1_100_000_000)
        }

        check("all three cached", links.count == 3)
        check("readable filename", links.first?.lastPathComponent.hasPrefix("test-gif-0-") == true)
        let linkCount = (try? links.first?.resourceValues(forKeys: [.linkCountKey]))??.linkCount ?? 0
        check("file is a hard link, not a copy", linkCount == 2)

        let size = await cache.diskSize()
        check("disk holds one copy per GIF (~3 MB), got \(size / 1024) KB",
              size > 3_000_000 && size < 3_400_000)

        // Evict to a 2.3 MB ceiling — room for the 1 MB protected blob plus one
        // more — while protecting the oldest entry. Exactly one GIF should go,
        // and it must be the least recently used of the unprotected pair.
        let protected: Set<URL> = [items[0].gifURL]
        let reclaimed = await cache.trim(
            protecting: protected,
            policy: .init(maxBytes: 2_300_000, maxAge: 0)
        )
        check("evicted exactly one GIF, got \(reclaimed / 1024) KB",
              reclaimed > 1_000_000 && reclaimed < 1_100_000)
        check("protected favourite survived eviction", cache.cachedFileIfPresent(for: items[0]) != nil)
        check("least-recently-used was evicted", cache.cachedFileIfPresent(for: items[1]) == nil)
        check("newest unprotected kept under ceiling", cache.cachedFileIfPresent(for: items[2]) != nil)

        // Age expiry. items[0] is protected and stale; items[2] is unprotected
        // and about to age past the limit.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let aged = await cache.trim(protecting: protected, policy: .init(maxBytes: .max, maxAge: 1))
        check("age expiry reclaimed one GIF, got \(aged / 1024) KB",
              aged > 1_000_000 && aged < 1_100_000)
        check("protected favourite survived expiry despite being stale",
              cache.cachedFileIfPresent(for: items[0]) != nil)
        check("stale unprotected entry expired", cache.cachedFileIfPresent(for: items[2]) == nil)

        await cache.clear()
        check("clear empties the cache", await cache.diskSize() == 0)

        // Which GIFs the reaper must spare.
        let now = Date()
        let old = now.addingTimeInterval(-Library.habitWindow - 86_400)
        func entry(uses: Int, favourite: Bool, used: Date) -> LibraryEntry {
            LibraryEntry(item: items[0], useCount: uses, lastUsed: used, isFavourite: favourite)
        }
        check("favourite is protected even when ancient",
              Library.isProtected(entry(uses: 0, favourite: true, used: old), now: now))
        check("often-used and recent is protected",
              Library.isProtected(entry(uses: 3, favourite: false, used: now), now: now))
        check("often-used but stale is not protected",
              !Library.isProtected(entry(uses: 99, favourite: false, used: old), now: now))
        check("recent but rarely used is not protected",
              !Library.isProtected(entry(uses: 2, favourite: false, used: now), now: now))

        checkKeyStore(check)
        checkVersionCompare(check)
        await checkMenuBarGeometry(check)
        await checkKeyboardNav(check)
        await checkHotkeyNaming(check)
        checkOutsideClick(check)
        await checkSearchReset(check)
        checkRenditionChoice(check)
        checkLaunchAtLogin(check)
        checkScrollZoom(check)

        print(failures.isEmpty ? "\nself-test passed" : "\nself-test FAILED: \(failures.count) check(s)")
        return failures.isEmpty
    }

    /// A mouse has no pinch gesture, so ⌘-scroll drives the same zoom. The
    /// two input kinds arrive on wildly different scales -- a wheel notch is
    /// whole lines, a trackpad is pixels many times a second -- and spending
    /// every delta would rocket through the column range on the first flick.
    private static func checkScrollZoom(_ check: (String, Bool) -> Void) {
        var zoom = ScrollZoom()
        check("a wheel notch up is one step out", zoom.steps(for: 1, precise: false) == 1)
        check("a wheel notch down is one step back", zoom.steps(for: -1, precise: false) == -1)
        check("three notches at once spend all three", zoom.steps(for: 3, precise: false) == 3)

        zoom.reset()
        check("a few trackpad pixels are not yet a column", zoom.steps(for: 8, precise: true) == 0)
        check("the remainder is banked, not dropped", zoom.steps(for: 8, precise: true) == 1)
        check("a fast trackpad flick spends several", zoom.steps(for: 48, precise: true) == 3)

        zoom.reset()
        _ = zoom.steps(for: 12, precise: true)
        zoom.reset()
        check("closing the panel drops a part-spent scroll",
              zoom.steps(for: 8, precise: true) == 0)

        var reversing = ScrollZoom()
        _ = reversing.steps(for: 8, precise: true)
        check("reversing mid-scroll cancels rather than steps",
              reversing.steps(for: -8, precise: true) == 0)
    }

    /// The login item registers the app bundle, so there is nothing to
    /// register when Yaga runs as a bare binary -- as it does right here.
    /// Reporting that instead of throwing is what keeps the toggle hidden
    /// rather than broken.
    private static func checkLaunchAtLogin(_ check: (String, Bool) -> Void) {
        check("an unbundled binary has no login item to offer", !LaunchAtLogin.isSupported)
        check("enabling it there fails with a reason, not a crash",
              LaunchAtLogin.setEnabled(true) != nil)
        check("and nothing is left registered", !LaunchAtLogin.isEnabled)
    }

    /// How big a copied GIF looks in Slack is decided here: it renders an
    /// upload at the rendition's own pixel width, so picking `fixed_width`
    /// (always 200px) is what made pasted GIFs tiny.
    private static func checkRenditionChoice(_ check: (String, Bool) -> Void) {
        func rendition(_ width: Int, _ bytes: Int) -> [String: Any] {
            ["url": "https://example.com/\(width)-\(bytes).gif",
             "width": String(width), "height": String(width), "size": String(bytes)]
        }
        func parse(_ images: [String: Any]) -> GifItem? {
            Giphy.parse(["id": "abc", "title": "GIF", "images": images])
        }
        // The ceiling is a user setting; pin it so this does not depend on
        // whatever is in defaults on this machine.
        let ceiling = Settings.shared.maxCopyMB
        Settings.shared.maxCopyMB = 10
        defer { Settings.shared.maxCopyMB = ceiling }

        let mixed = parse([
            "original": rendition(480, 2_000_000),
            "downsized_medium": rendition(320, 900_000),
            "fixed_width": rendition(200, 300_000),
        ])
        check("the widest affordable rendition is copied",
              mixed?.gifURL.absoluteString.contains("480-") == true)
        check("the grid still previews the cheap rendition",
              mixed?.previewURL.absoluteString.contains("200-") == true)

        let heavy = parse([
            "original": rendition(1000, 40_000_000),
            "downsized_medium": rendition(400, 9_000_000),
            "fixed_width": rendition(200, 300_000),
        ])
        check("a rendition over the byte ceiling is passed over",
              heavy?.gifURL.absoluteString.contains("400-") == true)

        let allHeavy = parse(["original": rendition(1000, 40_000_000),
                              "downsized": rendition(600, 20_000_000)])
        check("when every rendition is huge the smallest is still copied",
              allHeavy?.gifURL.absoluteString.contains("600-") == true)

        let sizeless = parse(["original": ["url": "https://example.com/o.gif",
                                           "width": "500", "height": "500"]])
        check("a rendition with no size is trusted rather than dropped",
              sizeless?.gifURL.absoluteString.hasSuffix("/o.gif") == true)

        check("a payload with no usable rendition is skipped",
              parse(["fixed_height": ["nonsense": true]]) == nil)
    }

    /// A pick ends the search, but the field is only cleared on the next open
    /// -- clearing it any earlier would show through the closing animation.
    @MainActor
    private static func checkSearchReset(_ check: (String, Bool) -> Void) {
        let model = GifSearchModel()
        model.query = "cats"
        model.refreshOnOpen()
        check("an unpicked search survives a reopen", model.query == "cats")

        model.pickDidDismissPanel()
        check("the field still shows the query while the panel closes", model.query == "cats")
        model.refreshOnOpen()
        check("a pick clears the search by the next open", model.query.isEmpty)

        model.query = "dogs"
        model.refreshOnOpen()
        check("only the pick that set it clears once", model.query == "dogs")
    }

    /// The panel closes on any click outside it, and the menu bar is the one
    /// region that closes it even while settings are open -- so misjudging
    /// where that strip ends would either miss clicks or swallow the screen.
    @MainActor
    private static func checkMenuBarGeometry(_ check: (String, Bool) -> Void) {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        // A notched display: the menu bar is far taller than the usual 24.
        let notched = NSRect(x: 0, y: 0, width: 1512, height: 982 - 37)
        let plain = NSRect(x: 0, y: 0, width: 1512, height: 982 - 25)

        func inBar(_ y: CGFloat, _ visible: NSRect) -> Bool {
            AppController.menuBarContains(NSPoint(x: 700, y: y), frame: screen, visibleFrame: visible)
        }

        check("a click in the menu bar counts", inBar(975, plain))
        check("a click just below it does not", !inBar(950, plain))
        check("the notch's taller bar is measured, not assumed", inBar(950, notched))
        check("the content area is never the menu bar", !inBar(500, plain) && !inBar(500, notched))

        // A secondary display reports no menu bar at all; treating the whole
        // screen as the strip would close the panel on any click.
        check("a screen with no menu bar falls back to the status bar height",
              inBar(981, screen) && !inBar(900, screen))
    }

    /// Version numbers are compared component-wise; a string comparison gets
    /// 0.10.0 versus 0.9.0 backwards, and that is exactly when it would matter.
    private static func checkVersionCompare(_ check: (String, Bool) -> Void) {
        let newer = UpdateChecker.isNewer
        check("a later patch is newer", newer("0.3.1", "0.3.0"))
        check("a later minor is newer", newer("0.4.0", "0.3.9"))
        check("double digits beat single", newer("0.10.0", "0.9.0"))
        check("the same version is not newer", !newer("0.3.0", "0.3.0"))
        check("an older version is not newer", !newer("0.2.9", "0.3.0"))
        check("a v prefix is ignored", newer("v0.4.0", "0.3.0") && !newer("v0.3.0", "0.3.0"))
        check("missing components count as zero", newer("0.4", "0.3.9") && !newer("0.3", "0.3.0"))
        check("garbage is never newer", !newer("", "0.3.0") && !newer("banana", "0.3.0"))
    }

    /// API keys sit in a plain file now, so the file mode is the only thing
    /// keeping them off other users on the machine.
    private static func checkKeyStore(_ check: (String, Bool) -> Void) {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yaga-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = KeyStore(directory: scratch)

        check("missing key reads as nil", store.load("giphyKey") == nil)
        store.save("abc123", for: "giphyKey")
        check("key round-trips", store.load("giphyKey") == "abc123")

        store.save("def456", for: "otherKey")
        check("keys do not clobber each other",
              store.load("giphyKey") == "abc123" && store.load("otherKey") == "def456")

        store.save("", for: "giphyKey")
        check("clearing a key removes it",
              store.load("giphyKey") == nil && store.load("otherKey") == "def456")

        let file = scratch.appendingPathComponent("keys.json")
        let mode = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int
        check("key file is owner-only after rewrites", mode == 0o600)

        let dirMode = (try? FileManager.default.attributesOfItem(atPath: scratch.path))?[.posixPermissions] as? Int
        check("key directory is owner-only", dirMode == 0o700)
    }

    /// The settings page is the one thing that can outlive an outside click,
    /// and only while there is no API key to lose the field for.
    private static func checkOutsideClick(_ check: (String, Bool) -> Void) {
        func closes(settings: Bool, needsKey: Bool, menuBar: Bool) -> Bool {
            AppController.outsideClickCloses(
                isShowingSettings: settings, needsAPIKey: needsKey, isInMenuBar: menuBar
            )
        }
        check("the grid closes on any outside click", closes(settings: false, needsKey: true, menuBar: false))
        check("settings stays up during first-run setup", !closes(settings: true, needsKey: true, menuBar: false))
        check("the menu bar closes settings even then", closes(settings: true, needsKey: true, menuBar: true))
        check("settings closes once a key is entered", closes(settings: true, needsKey: false, menuBar: false))
    }

    /// Recorded shortcuts can be anything, so both the name we show and the
    /// rules that reject a combination need to hold for arbitrary input.
    @MainActor
    private static func checkHotkeyNaming(_ check: (String, Bool) -> Void) {
        let optionCommandG = Hotkey(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | optionKey))
        check("modifiers read in Apple's order", optionCommandG.displayName == "⌥⌘G")

        let all = Hotkey(keyCode: UInt32(kVK_Space),
                         modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        check("every modifier is shown, control first", all.displayName == "⌃⌥⇧⌘Space")

        let arrow = Hotkey(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(cmdKey))
        check("keys without a glyph get a symbol", arrow.displayName == "⌘←")

        // Presets are what the menu offers, so a name we cannot render would
        // show up there first.
        for preset in Hotkey.presets + Hotkey.pastePresets {
            check("preset \(preset.name) renders as itself", preset.hotkey.displayName == preset.name)
        }

        let shiftOnly = Hotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey))
        check("shift alone is refused", shiftOnly.problem(against: nil) == .needsModifier)
        check("bare key is refused", Hotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: 0)
            .problem(against: nil) == .needsModifier)
        check("option alone is enough", Hotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
            .problem(against: nil) == nil)
        check("the other shortcut is refused", optionCommandG.problem(against: optionCommandG) == .sameAsOther)
        check("a free combination is accepted", optionCommandG.problem(against: .pasteDefault) == nil)

        let flags: NSEvent.ModifierFlags = [.command, .shift]
        check("AppKit flags map to Carbon bits",
              Hotkey.carbonModifiers(from: flags) == UInt32(cmdKey | shiftKey))
        check("unrelated flags are dropped",
              Hotkey.carbonModifiers(from: [.command, .capsLock, .function]) == UInt32(cmdKey))
    }

    /// Grid arithmetic is easy to get subtly wrong at the edges — the last row
    /// is usually short, and the digit keys must not steal typing.
    @MainActor
    private static func checkKeyboardNav(_ check: (String, Bool) -> Void) {
        let nav = KeyNav.shared
        var activated: [Int] = []
        var shelfSteps = 0
        nav.onActivate = { activated.append($0) }
        nav.onShelfStep = { shelfSteps += $0 }

        // 7 items in a 3-wide grid: rows of 3, 3, then 1.
        func fresh(query empty: Bool = true, count: Int = 7) {
            nav.reset()
            nav.itemCount = count
            nav.columns = 3
            nav.hasShelfBar = empty
            nav.queryIsEmpty = empty
            activated = []
            shelfSteps = 0
        }

        func press(_ code: UInt16) {
            _ = nav.handle(key(code, characters: ""))
        }
        func type(_ character: String) -> Bool {
            nav.handle(key(0, characters: character))
        }

        fresh()
        press(125) // down
        check("down from search lands on the shelf tabs", nav.zone == .shelf)
        press(124) // right
        check("right steps the shelf", shelfSteps == 1)
        press(125)
        check("down from the shelf enters the grid", nav.zone == .grid && nav.selection == 0)
        press(124)
        press(125)
        check("down moves a whole row", nav.selection == 4)
        press(125)
        check("down from a short last row lands on its final cell", nav.selection == 6)
        press(125)
        check("down at the end stays put", nav.selection == 6)
        press(126) // up
        check("up moves a whole row back", nav.selection == 3)
        press(123) // left
        check("left steps one cell", nav.selection == 2)
        press(36) // return
        check("return activates the selection", activated == [2])
        press(53) // escape
        check("escape backs out to the shelf", nav.zone == .shelf)
        press(53)
        check("escape again returns to search", nav.zone == .search)
        check("escape in search is left to close the panel", !nav.handle(key(53, characters: "")))

        fresh()
        check("a digit in an empty search box picks a GIF", type("3") && activated == [2])
        fresh(query: false)
        check("a digit is typed once the search box has text", !type("3") && activated.isEmpty)
        fresh(count: 2)
        check("a digit past the last GIF does nothing", type("5") && activated.isEmpty)

        fresh()
        check("letters always reach the search field", !type("a"))

        nav.reset()
        nav.onActivate = nil
        nav.onShelfStep = nil
    }

    private static func key(_ code: UInt16, characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        )!
    }
}
