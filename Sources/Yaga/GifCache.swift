import AppKit
import CryptoKit

/// Two-tier GIF store: an in-memory cache in front of a content-addressed
/// directory of GIF bytes on disk.
///
/// Files are named by a hash of their source URL, so a name is stable across
/// launches. Clipboard and drag-and-drop need a *human-readable* filename, so
/// `fileOnDisk(for:)` hard-links the blob under a friendly name — a link, not a
/// copy, so the bytes exist exactly once.
///
/// Old GIFs are reaped by `trim(protecting:)`, which drops anything past its
/// age limit and then evicts least-recently-used blobs until the directory fits
/// its size ceiling. GIFs the user favourited or reaches for often are passed
/// in as protected and are never reaped.
actor GifCache {
    static let shared = GifCache()

    struct Policy {
        /// Ceiling for the whole blob directory.
        var maxBytes: Int64
        /// Age after which an unprotected GIF is dropped. Zero disables it.
        var maxAge: TimeInterval

        static var current: Policy {
            Policy(
                maxBytes: Int64(Settings.shared.cacheLimitMB) * 1_048_576,
                maxAge: TimeInterval(Settings.shared.cacheMaxAgeDays) * 86_400
            )
        }
    }

    private let blobs: URL
    /// Friendly-named hard links into `blobs`. Derived, so wiped on launch and on quit.
    private let links: URL

    private var inFlight: [URL: Task<Data, Error>] = [:]
    private let memory = NSCache<NSURL, NSData>()

    init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yaga", isDirectory: true)
        blobs = root.appendingPathComponent("blobs", isDirectory: true)
        links = root.appendingPathComponent("named", isDirectory: true)

        let manager = FileManager.default
        try? manager.removeItem(at: links)
        for path in [blobs, links] {
            try? manager.createDirectory(at: path, withIntermediateDirectories: true)
        }
        memory.totalCostLimit = 256 * 1024 * 1024

        // Drop the pre-hash `.cache` files left by older builds.
        let stale = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in stale where file.pathExtension == "cache" { try? manager.removeItem(at: file) }
        let staleGifs = root.appendingPathComponent("gifs", isDirectory: true)
        if manager.fileExists(atPath: staleGifs.path) { try? manager.removeItem(at: staleGifs) }
    }

    // MARK: - Reading

    func data(for url: URL) async throws -> Data {
        if let cached = memory.object(forKey: url as NSURL) { return cached as Data }

        let file = Self.blobURL(for: url, blobs: blobs)
        if let onDisk = try? Data(contentsOf: file) {
            memory.setObject(onDisk as NSData, forKey: url as NSURL, cost: onDisk.count)
            touch(file)
            return onDisk
        }

        if let existing = inFlight[url] { return try await existing.value }

        let task = Task<Data, Error> {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }

        let data = try await task.value
        memory.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        try? data.write(to: file, options: .atomic)
        return data
    }

    /// Returns a GIF on disk under a readable filename, for the clipboard and
    /// for drag-and-drop. The file is a hard link to the cached blob.
    func fileOnDisk(for item: GifItem) async throws -> URL {
        _ = try await data(for: item.gifURL)

        let blob = Self.blobURL(for: item.gifURL, blobs: blobs)
        let link = Self.linkURL(for: item, in: links)
        let manager = FileManager.default
        // Relink unconditionally: an evicted-and-refetched blob is a new inode.
        try? manager.removeItem(at: link)
        do {
            try manager.linkItem(at: blob, to: link)
        } catch {
            try manager.copyItem(at: blob, to: link)
        }
        touch(blob)
        return link
    }

    /// The synchronous peek `.onDrag` needs, since that closure cannot await.
    nonisolated func cachedFileIfPresent(for item: GifItem) -> URL? {
        let link = Self.linkURL(for: item, in: links)
        return FileManager.default.fileExists(atPath: link.path) ? link : nil
    }

    // MARK: - Reaping

    /// Expires old GIFs, then evicts least-recently-used ones until the cache
    /// is under its size ceiling. Blobs behind `protecting` are exempt from both.
    @discardableResult
    func trim(protecting protected: Set<URL>, policy: Policy = .current) -> Int64 {
        let manager = FileManager.default
        let protectedKeys = Set(protected.map(Self.key))

        struct Entry {
            let url: URL
            let size: Int64
            let used: Date
            let isProtected: Bool
        }

        let contents = (try? manager.contentsOfDirectory(
            at: blobs,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []

        var entries: [Entry] = contents.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            else { return nil }
            let name = file.deletingPathExtension().lastPathComponent
            return Entry(
                url: file,
                size: Int64(values.fileSize ?? 0),
                used: values.contentModificationDate ?? .distantPast,
                isProtected: protectedKeys.contains(name)
            )
        }

        var doomed: [Entry] = []

        // 1. Age out anything untouched for too long.
        if policy.maxAge > 0 {
            let cutoff = Date().addingTimeInterval(-policy.maxAge)
            let expired = entries.filter { !$0.isProtected && $0.used < cutoff }
            doomed += expired
            let dropped = Set(expired.map(\.url))
            entries.removeAll { dropped.contains($0.url) }
        }

        // 2. Evict least-recently-used until the ceiling is met.
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries.filter({ !$0.isProtected }).sorted(by: { $0.used < $1.used }) {
            guard total > policy.maxBytes else { break }
            doomed.append(entry)
            total -= entry.size
        }

        for entry in doomed { try? manager.removeItem(at: entry.url) }
        let reclaimed = doomed.reduce(Int64(0)) { $0 + $1.size }

        // 3. Friendly-named links whose blob is gone now have a link count of 1.
        let named = (try? manager.contentsOfDirectory(
            at: links, includingPropertiesForKeys: [.linkCountKey]
        )) ?? []
        for link in named {
            let count = (try? link.resourceValues(forKeys: [.linkCountKey]))?.linkCount ?? 0
            if count <= 1 { try? manager.removeItem(at: link) }
        }

        return reclaimed
    }

    func clear() {
        memory.removeAllObjects()
        let manager = FileManager.default
        for path in [blobs, links] {
            try? manager.removeItem(at: path)
            try? manager.createDirectory(at: path, withIntermediateDirectories: true)
        }
    }

    /// Called on quit. The named links are derived from `blobs`, so dropping
    /// them costs nothing and leaves no loose filenames behind.
    nonisolated func clearNamedLinks() {
        try? FileManager.default.removeItem(at: links)
    }

    /// Bytes held on disk. Hard links in `named/` share inodes with `blobs/`,
    /// so counting the blobs alone is the true figure.
    func diskSize() -> Int64 { usage().bytes }

    /// What is on disk, in one pass: the same walk the size needs already has
    /// the file count in hand.
    func usage() -> (files: Int, bytes: Int64) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: blobs, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(Int64(0)) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (files.count, bytes)
    }

    // MARK: - Naming

    /// Content-addressed by source URL. `String.hashValue` is seeded per
    /// process, so it cannot be used here — the name must survive a relaunch.
    nonisolated static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(20).description
    }

    private nonisolated static func blobURL(for url: URL, blobs: URL) -> URL {
        blobs.appendingPathComponent(key(for: url) + ".gif")
    }

    private nonisolated static func linkURL(for item: GifItem, in links: URL) -> URL {
        let name = slug(item.title) + "-" + key(for: item.gifURL).prefix(8) + ".gif"
        return links.appendingPathComponent(name)
    }

    private func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    private static func slug(_ title: String) -> String {
        let allowed = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(allowed).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "gif" : String(joined.prefix(40))
    }
}
