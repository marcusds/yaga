import Foundation

/// A single GIF as returned by a provider or stored in the local library.
struct GifItem: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    /// Small, animated preview used to fill the grid.
    let previewURL: URL
    /// Full-quality GIF used when copying or dragging out.
    let gifURL: URL
    let width: Int
    let height: Int
    /// Page on the provider's site, used for "copy link".
    let sourceURL: URL?

    var aspect: Double {
        guard width > 0, height > 0 else { return 1.0 }
        return Double(width) / Double(height)
    }
}

/// Usage metadata layered on top of a `GifItem`.
struct LibraryEntry: Codable, Hashable {
    var item: GifItem
    var useCount: Int
    var lastUsed: Date
    var isFavourite: Bool
}

enum Shelf: String, CaseIterable, Identifiable {
    case recent, frequent, favourites, trending
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recent: return "Recent"
        case .frequent: return "Frequent"
        case .favourites: return "Favourites"
        case .trending: return "Trending"
        }
    }
    var symbol: String {
        switch self {
        case .recent: return "clock"
        case .frequent: return "flame"
        case .favourites: return "star"
        case .trending: return "chart.line.uptrend.xyaxis"
        }
    }
}

/// A read-only summary of the library, for the Stats section in Settings.
struct LibraryStats: Equatable {
    /// GIFs the library remembers, favourites included.
    var tracked = 0
    var favourites = 0
    /// Every copy, insert and drag ever recorded — not the number of distinct
    /// GIFs, so it keeps counting past the point where history is pruned.
    var picks = 0
    var busiestTitle: String?
    var busiestUses = 0
    var lastPick: Date?
}

/// Persistent store of recents / frequents / favourites, saved as JSON in
/// ~/Library/Application Support/Yaga/library.json
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var entries: [String: LibraryEntry] = [:]

    private let url: URL
    private let maxRecents = 200

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yaga", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("library.json")
        load()
    }

    // MARK: - Shelves

    var recent: [GifItem] {
        entries.values
            .sorted { $0.lastUsed > $1.lastUsed }
            .prefix(60)
            .map(\.item)
    }

    var frequent: [GifItem] {
        entries.values
            .filter { $0.useCount > 1 }
            .sorted { ($0.useCount, $0.lastUsed) > ($1.useCount, $1.lastUsed) }
            .prefix(60)
            .map(\.item)
    }

    var favourites: [GifItem] {
        entries.values
            .filter(\.isFavourite)
            .sorted { $0.lastUsed > $1.lastUsed }
            .map(\.item)
    }

    /// The favourites you reach for most, for the pinned row at the top of the
    /// panel. Ties break on recency so the row is stable but not frozen.
    func topFavourites(limit: Int) -> [GifItem] {
        entries.values
            .filter(\.isFavourite)
            .sorted { ($0.useCount, $0.lastUsed) > ($1.useCount, $1.lastUsed) }
            .prefix(limit)
            .map(\.item)
    }

    /// Media the cache must not reap. Favourites are explicit intent and are
    /// kept indefinitely. A habit is only a habit while it lasts, so a
    /// often-used GIF keeps its protection only while it is still being used.
    var protectedMediaURLs: Set<URL> {
        let now = Date()
        var urls: Set<URL> = []
        for entry in entries.values where Library.isProtected(entry, now: now) {
            urls.insert(entry.item.previewURL)
            urls.insert(entry.item.gifURL)
        }
        return urls
    }

    nonisolated static func isProtected(_ entry: LibraryEntry, now: Date = Date()) -> Bool {
        if entry.isFavourite { return true }
        return entry.useCount >= habitThreshold && entry.lastUsed > now.addingTimeInterval(-habitWindow)
    }

    nonisolated static let habitThreshold = 3
    /// How long a frequently-used GIF stays protected after its last use.
    nonisolated static let habitWindow: TimeInterval = 180 * 86_400

    var stats: LibraryStats { Library.stats(for: entries) }

    /// Taken over a passed-in dictionary rather than `entries` so it can be
    /// exercised without the shared library on disk.
    nonisolated static func stats(for entries: [String: LibraryEntry]) -> LibraryStats {
        var stats = LibraryStats()
        stats.tracked = entries.count
        var busiestLastUsed = Date.distantPast
        for entry in entries.values {
            if entry.isFavourite { stats.favourites += 1 }
            stats.picks += entry.useCount
            // A favourite that has never been picked is not the busiest GIF,
            // however recently it was starred.
            guard entry.useCount > 0 else { continue }
            // Ties go to the more recent GIF, matching the Frequent shelf.
            if (entry.useCount, entry.lastUsed) > (stats.busiestUses, busiestLastUsed) {
                stats.busiestTitle = entry.item.title
                stats.busiestUses = entry.useCount
                busiestLastUsed = entry.lastUsed
            }
            if entry.lastUsed > stats.lastPick ?? .distantPast {
                stats.lastPick = entry.lastUsed
            }
        }
        return stats
    }

    func isFavourite(_ item: GifItem) -> Bool {
        entries[item.id]?.isFavourite ?? false
    }

    // MARK: - Mutations

    func recordUse(_ item: GifItem) {
        if var existing = entries[item.id] {
            existing.item = item
            existing.useCount += 1
            existing.lastUsed = Date()
            entries[item.id] = existing
        } else {
            entries[item.id] = LibraryEntry(item: item, useCount: 1, lastUsed: Date(), isFavourite: false)
        }
        prune()
        save()
    }

    func toggleFavourite(_ item: GifItem) {
        if var existing = entries[item.id] {
            existing.isFavourite.toggle()
            entries[item.id] = existing
        } else {
            entries[item.id] = LibraryEntry(item: item, useCount: 0, lastUsed: Date(), isFavourite: true)
        }
        save()
    }

    func forget(_ item: GifItem) {
        entries.removeValue(forKey: item.id)
        save()
    }

    func clearHistory() {
        entries = entries.filter(\.value.isFavourite)
        save()
    }

    /// Drop the oldest non-favourite entries once the history grows too large.
    private func prune() {
        guard entries.count > maxRecents else { return }
        let droppable = entries.values
            .filter { !$0.isFavourite }
            .sorted { $0.lastUsed < $1.lastUsed }
        for entry in droppable.prefix(entries.count - maxRecents) {
            entries.removeValue(forKey: entry.item.id)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: LibraryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
