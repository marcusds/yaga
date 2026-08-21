import Foundation

/// Provider API keys, kept in a file we own rather than the Keychain.
///
/// The Keychain binds an item's ACL to the code signature that created it. For
/// ad-hoc signed builds — which is what CI ships — that is the hash of the
/// exact binary, so every release looks like a different app and prompts for
/// the login password again. These are rate-limited search keys, not
/// credentials worth that friction, so they live in a 0600 file instead.
struct KeyStore {
    static let shared = KeyStore(directory: KeyStore.defaultDirectory)

    let directory: URL

    private var file: URL { directory.appendingPathComponent("keys.json") }

    static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yaga", isDirectory: true)
    }

    func load(_ account: String) -> String? {
        guard let data = try? Data(contentsOf: file),
              let keys = try? JSONDecoder().decode([String: String].self, from: data),
              let value = keys[account],
              !value.isEmpty
        else { return nil }
        return value
    }

    func save(_ value: String, for account: String) {
        var keys = (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        if value.isEmpty {
            keys.removeValue(forKey: account)
        } else {
            keys[account] = value
        }

        let manager = FileManager.default
        try? manager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(keys) else { return }
        try? data.write(to: file, options: .atomic)
        // An atomic write swaps in a fresh file, so the mode has to be
        // reapplied every time rather than set once at creation.
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
