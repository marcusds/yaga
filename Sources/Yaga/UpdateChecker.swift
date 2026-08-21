import AppKit
import Foundation

/// Asks GitHub, at most once a week, whether a newer release exists.
///
/// There is no updater here and deliberately so: the app cannot replace its
/// own bundle without the App Management permission, so this only ever points
/// at the release page and lets the user decide.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let repository = "marcusds/yaga"
    private static let interval: TimeInterval = 7 * 86_400
    private static let lastCheckKey = "lastUpdateCheckAt"
    private static let lastSeenKey = "lastSeenRelease"

    /// The newest release tag GitHub has told us about, remembered across
    /// launches so the badge does not vanish until it is actually installed.
    @Published private(set) var latestVersion: String?
    @Published private(set) var isChecking = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastChecked: Date?

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private init() {
        let defaults = UserDefaults.standard
        latestVersion = defaults.string(forKey: Self.lastSeenKey)
        lastChecked = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    var updateAvailable: Bool {
        guard let latestVersion else { return false }
        return Self.isNewer(latestVersion, than: currentVersion)
    }

    var releaseURL: URL {
        URL(string: "https://github.com/\(Self.repository)/releases/latest")!
    }

    /// Runs at most weekly. The timestamp is written before the request so a
    /// failing network does not mean retrying on every launch.
    func checkIfDue(force: Bool = false) {
        guard force || Settings.shared.checkForUpdates else { return }
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) >= Self.interval else { return }

        Task { await check() }
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        let now = Date()
        UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
        lastChecked = now

        do {
            let tag = try await fetchLatestTag()
            latestVersion = tag
            UserDefaults.standard.set(tag, forKey: Self.lastSeenKey)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func fetchLatestTag() async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        // GitHub rejects requests without one.
        request.setValue("Yaga/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GifError.http(http.statusCode)
        }
        struct Release: Decodable { let tag_name: String }
        return try JSONDecoder().decode(Release.self, from: data).tag_name
    }

    /// Compares dotted version numbers a component at a time, so 0.10.0 beats
    /// 0.9.0 — which a string comparison would get backwards.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = components(of: candidate)
        let right = components(of: current)
        guard !left.isEmpty else { return false }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private nonisolated static func components(of version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
