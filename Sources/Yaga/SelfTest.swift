import AppKit
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

        print(failures.isEmpty ? "\nself-test passed" : "\nself-test FAILED: \(failures.count) check(s)")
        return failures.isEmpty
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

        store.save("def456", for: "klipyKey")
        check("keys do not clobber each other",
              store.load("giphyKey") == "abc123" && store.load("klipyKey") == "def456")

        store.save("", for: "giphyKey")
        check("clearing a key removes it",
              store.load("giphyKey") == nil && store.load("klipyKey") == "def456")

        let file = scratch.appendingPathComponent("keys.json")
        let mode = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int
        check("key file is owner-only after rewrites", mode == 0o600)

        let dirMode = (try? FileManager.default.attributesOfItem(atPath: scratch.path))?[.posixPermissions] as? Int
        check("key directory is owner-only", dirMode == 0o700)
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
