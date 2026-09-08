import Foundation
import ServiceManagement

/// The "open at login" checkbox, backed by `SMAppService`.
///
/// The registration is the app bundle itself, so this only works on a real
/// `Yaga.app`: run from `swift run` there is no bundle to register and every
/// call reports unsupported rather than pretending to have worked.
enum LaunchAtLogin {
    /// False when there is nothing registrable — an unbundled binary, or a
    /// bundle macOS has not indexed. The toggle is hidden in that case, since
    /// flipping it could never stick.
    static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// macOS lets the user override the registration in System Settings, and
    /// the app cannot re-enable itself once they have. Surfacing that as its
    /// own state keeps the toggle from silently snapping back with no reason
    /// given.
    static var needsApproval: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .requiresApproval
    }

    /// Returns nil on success, or a message to show the user.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        guard isSupported else { return "Only available in the installed Yaga.app." }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            if needsApproval {
                return "Login items for Yaga are turned off in System Settings."
            }
            return error.localizedDescription
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
