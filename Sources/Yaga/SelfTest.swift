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

        print(failures.isEmpty ? "\nself-test passed" : "\nself-test FAILED: \(failures.count) check(s)")
        return failures.isEmpty
    }
}
