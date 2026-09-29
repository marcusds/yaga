import AppKit
import Foundation
import Security

/// Replaces the installed bundle with a downloaded release and relaunches.
///
/// The download is only trusted if it satisfies the running copy's own
/// designated requirement -- the same identifier, signed by the same
/// certificate. That keeps a tampered or foreign zip out, and it is also what
/// lets the Accessibility grant carry over: TCC keys it to that requirement.
@MainActor
enum UpdateInstaller {
    enum Failure: LocalizedError {
        case notBundled
        case noAsset
        case download(Int)
        case unzip
        case missingApp
        case untrusted
        case notNewer

        var errorDescription: String? {
            switch self {
            case .notBundled: return "This copy is not running from an app bundle."
            case .noAsset: return "The release has no app download."
            case .download(let code): return "The download failed (HTTP \(code))."
            case .unzip: return "The download could not be unpacked."
            case .missingApp: return "The download does not contain Yaga.app."
            case .untrusted: return "The download is not signed by the same developer as this copy."
            case .notNewer: return "The download is not newer than this copy."
            }
        }
    }

    /// Downloads, verifies and swaps in the release at `asset`. On return the
    /// new bundle is in place; the running process is still the old one.
    static func install(from asset: URL) async throws {
        let installed = Bundle.main.bundleURL
        guard installed.pathExtension == "app" else { throw Failure.notBundled }

        let files = FileManager.default
        // On the same volume as the installed copy, so the final swap is a
        // rename rather than a copy that could be interrupted halfway.
        let staging = try files.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: installed, create: true
        )
        defer { try? files.removeItem(at: staging) }

        var request = URLRequest(url: asset)
        request.setValue("Yaga/\(UpdateChecker.shared.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        let (download, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.download(http.statusCode)
        }
        let zip = staging.appendingPathComponent("update.zip")
        try files.moveItem(at: download, to: zip)

        let unpacked = staging.appendingPathComponent("unpacked")
        try await unzip(zip, into: unpacked)
        let app = unpacked.appendingPathComponent("Yaga.app")
        guard files.fileExists(atPath: app.path) else { throw Failure.missingApp }

        try verifySignature(of: app)
        let newVersion = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard UpdateChecker.isNewer(newVersion, than: UpdateChecker.shared.currentVersion) else {
            throw Failure.notNewer
        }

        _ = try files.replaceItemAt(installed, withItemAt: app, options: .usingNewMetadataOnly)
    }

    /// Quits, and opens the (now replaced) bundle once this process is gone.
    /// A second copy cannot start while the first still holds the hotkeys, so
    /// the relaunch waits on the PID rather than a fixed delay.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path is passed as $0 so no quoting of it is needed.
        task.arguments = [
            "-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundleURL.path,
        ]
        try? task.run()
        NSApp.terminate(nil)
    }

    private static func unzip(_ zip: URL, into directory: URL) async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", zip.path, directory.path]
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            task.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try task.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else { throw Failure.unzip }
    }

    /// Checks `app` against the running copy's designated requirement. An
    /// ad-hoc signed copy pins that requirement to its own hash, so it will
    /// never accept an update -- which is the safe way round.
    static func verifySignature(of app: URL) throws {
        var running: SecCode?
        var runningStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
              SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate
        else { throw Failure.untrusted }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess else {
            throw Failure.untrusted
        }
    }
}
