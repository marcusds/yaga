import Foundation
import Carbon.HIToolbox

enum ContentFilter: String, CaseIterable, Identifiable, Codable {
    case high, medium, low, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .high: return "Strict (G)"
        case .medium: return "Moderate (PG)"
        case .low: return "Relaxed (PG-13)"
        case .off: return "Off (R)"
        }
    }
    /// KLIPY uses these names verbatim.
    var klipyValue: String { rawValue }

    var giphyValue: String {
        switch self {
        case .high: return "g"
        case .medium: return "pg"
        case .low: return "pg-13"
        case .off: return "r"
        }
    }
}

enum CopyMode: String, CaseIterable, Identifiable, Codable {
    case gif, link
    var id: String { rawValue }
    var label: String { self == .gif ? "The GIF itself" : "A link to the GIF" }
}

/// A global shortcut, stored as a Carbon key code plus Carbon modifier mask.
struct Hotkey: Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = Hotkey(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | optionKey))

    /// Presets offered in Settings, so we don't need a full shortcut recorder.
    static let presets: [(name: String, hotkey: Hotkey)] = [
        ("⌥⌘G", Hotkey(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | optionKey))),
        ("⌃⌥G", Hotkey(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(controlKey | optionKey))),
        ("⇧⌘G", Hotkey(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey))),
        ("⌥⌘Space", Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey))),
        ("⌃⌥Space", Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))),
        ("⌃⌥⌘F", Hotkey(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | optionKey | cmdKey))),
    ]

    var displayName: String {
        Hotkey.presets.first { $0.hotkey == self }?.name ?? "Custom"
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private init() {}

    /// Reads an API key from the Keychain, migrating it out of the preferences
    /// plist on first run of a build that has Keychain storage.
    private static func loadKey(_ account: String) -> String {
        if let stored = Keychain.load(account) { return stored }
        let defaults = UserDefaults.standard
        if let legacy = defaults.string(forKey: account), !legacy.isEmpty {
            Keychain.save(legacy, for: account)
            defaults.removeObject(forKey: account)
            return legacy
        }
        return ""
    }

    @Published var provider: ProviderKind = ProviderKind(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .giphy {
        didSet { defaults.set(provider.rawValue, forKey: "provider") }
    }

    @Published var giphyKey: String = Settings.loadKey("giphyKey") {
        didSet { Keychain.save(giphyKey, for: "giphyKey") }
    }

    @Published var klipyKey: String = Settings.loadKey("klipyKey") {
        didSet { Keychain.save(klipyKey, for: "klipyKey") }
    }

    /// A stable anonymous id. KLIPY uses it for per-user recents and share
    /// signals; it is a random UUID and never leaves this machine otherwise.
    lazy var customerID: String = {
        if let existing = defaults.string(forKey: "customerID") { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: "customerID")
        return fresh
    }()

    @Published var contentFilter: ContentFilter = ContentFilter(rawValue: UserDefaults.standard.string(forKey: "contentFilter") ?? "") ?? .medium {
        didSet { defaults.set(contentFilter.rawValue, forKey: "contentFilter") }
    }

    @Published var copyMode: CopyMode = CopyMode(rawValue: UserDefaults.standard.string(forKey: "copyMode") ?? "") ?? .gif {
        didSet { defaults.set(copyMode.rawValue, forKey: "copyMode") }
    }

    /// Close the popover as soon as a GIF is copied, returning focus to the app you were in.
    @Published var closeAfterCopy: Bool = UserDefaults.standard.object(forKey: "closeAfterCopy") as? Bool ?? true {
        didSet { defaults.set(closeAfterCopy, forKey: "closeAfterCopy") }
    }

    /// Columns in the GIF grid. Pinch-to-zoom and ⌘+/⌘- drive this.
    @Published var gridColumns: Int = UserDefaults.standard.object(forKey: "gridColumns") as? Int ?? 3 {
        didSet {
            let clamped = min(max(gridColumns, Settings.minColumns), Settings.maxColumns)
            if clamped != gridColumns { gridColumns = clamped; return }
            defaults.set(gridColumns, forKey: "gridColumns")
        }
    }

    static let minColumns = 1
    static let maxColumns = 5

    func zoom(by step: Int) {
        gridColumns = min(max(gridColumns - step, Settings.minColumns), Settings.maxColumns)
    }

    /// Ceiling for cached GIF bytes on disk, in megabytes.
    @Published var cacheLimitMB: Int = UserDefaults.standard.object(forKey: "cacheLimitMB") as? Int ?? 500 {
        didSet { defaults.set(cacheLimitMB, forKey: "cacheLimitMB") }
    }

    /// Days an unused GIF survives in the cache. Zero disables expiry.
    @Published var cacheMaxAgeDays: Int = UserDefaults.standard.object(forKey: "cacheMaxAgeDays") as? Int ?? 30 {
        didSet { defaults.set(cacheMaxAgeDays, forKey: "cacheMaxAgeDays") }
    }

    @Published var hotkey: Hotkey = {
        let codes = UserDefaults.standard.object(forKey: "hotkey") as? [Int]
        guard let codes, codes.count == 2 else { return .default }
        return Hotkey(keyCode: UInt32(codes[0]), modifiers: UInt32(codes[1]))
    }() {
        didSet {
            defaults.set([Int(hotkey.keyCode), Int(hotkey.modifiers)], forKey: "hotkey")
            HotkeyManager.shared.reregister()
        }
    }

    var currentKey: String {
        switch provider {
        case .giphy: return giphyKey
        case .klipy: return klipyKey
        }
    }

    var currentProvider: GifProvider {
        Providers.make(provider, key: currentKey)
    }
}
