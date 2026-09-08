import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var library: Library
    @State private var cacheSize: Int64 = 0
    @State private var cacheFiles = 0
    @State private var accessibilityTrusted = AutoPaste.isTrusted
    @StateObject private var updates = UpdateChecker.shared
    @StateObject private var hotkeys = HotkeyManager.shared
    @State private var hotkeyProblem: String?
    @State private var recording: Recording?

    var body: some View {
        Form {
            Section("GIF Source") {
                SecureField("GIPHY API key", text: $settings.giphyKey)
                HStack {
                    Spacer()
                    Link("Get a free \(Giphy.label) key", destination: Giphy.keyURL)
                        .font(.caption)
                }
                Picker("Content filter", selection: $settings.contentFilter) {
                    ForEach(ContentFilter.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Behaviour") {
                shortcutRow(
                    "Shortcut",
                    // The open shortcut cannot be cleared, so a nil write is
                    // dropped rather than represented.
                    hotkey: Binding(
                        get: { settings.hotkey },
                        set: { if let new = $0 { settings.hotkey = new } }
                    ),
                    presets: Hotkey.presets,
                    conflictsWith: settings.pasteHotkey,
                    allowsClearing: false
                )
                Picker("Clicking a GIF copies", selection: $settings.copyMode) {
                    ForEach(CopyMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Close window after copying", isOn: $settings.closeAfterCopy)
                if LaunchAtLogin.isSupported {
                    Toggle("Open Yaga at login", isOn: $settings.launchAtLogin)
                    if let problem = settings.launchAtLoginProblem {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(problem)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open…") { LaunchAtLogin.openLoginItemsSettings() }
                                .controlSize(.small)
                        }
                    }
                }
                shortcutRow(
                    "Insert shortcut",
                    hotkey: $settings.pasteHotkey,
                    presets: Hotkey.pastePresets,
                    conflictsWith: settings.hotkey,
                    allowsClearing: true
                )
                .onChange(of: settings.pasteHotkey) {
                    // Asking here surfaces the system prompt as the user opts
                    // in, rather than mid-paste later on.
                    if settings.pasteHotkey != nil { accessibilityTrusted = AutoPaste.requestTrust() }
                }
                shortcutWarning
                Text("Opens the panel in insert mode: your pick is pasted straight into the field you were typing in. The menu bar icon and \(settings.hotkey.displayName) always just copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.pasteHotkey != nil && !accessibilityTrusted {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Yaga needs Accessibility access to press ⌘V for you.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open…") { AutoPaste.openPrivacySettings() }
                            .controlSize(.small)
                    }
                }
            }

            Section("Updates") {
                Toggle("Check weekly for updates", isOn: $settings.checkForUpdates)
                LabeledContent("Version") {
                    HStack(spacing: 8) {
                        Text(updates.currentVersion)
                        if updates.isChecking {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Check Now") { Task { await updates.check() } }
                                .controlSize(.small)
                        }
                    }
                }
                if updates.updateAvailable, let latest = updates.latestVersion {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.tint)
                        Text("\(latest) is available.")
                            .font(.caption)
                        Spacer()
                        Button("Download…") { NSWorkspace.shared.open(updates.releaseURL) }
                            .controlSize(.small)
                    }
                } else {
                    Text(updateStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Stats") {
                let stats = library.stats
                LabeledContent("GIFs picked", value: stats.picks.formatted())
                LabeledContent("In your history", value: stats.tracked.formatted())
                LabeledContent("Favourites", value: stats.favourites.formatted())
                if let title = stats.busiestTitle {
                    LabeledContent("Most used") {
                        // A GIPHY title can be a sentence, so it gets the room
                        // rather than pushing the count off the row.
                        Text("\(title) · \(stats.busiestUses.formatted())×")
                            .multilineTextAlignment(.trailing)
                    }
                }
                if let last = stats.lastPick {
                    LabeledContent("Last picked", value: last.formatted(.relative(presentation: .named)))
                }
                LabeledContent("Cached on disk") {
                    Text("\(cacheFiles.formatted()) GIFs · \(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))")
                }
                if stats.picks == 0 {
                    Text("Pick a GIF and this fills in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Storage") {
                Picker("Keep at most", selection: $settings.cacheLimitMB) {
                    Text("250 MB").tag(250)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                }
                Picker("Copy GIFs up to", selection: $settings.maxCopyMB) {
                    Text("2 MB").tag(2)
                    Text("5 MB").tag(5)
                    Text("10 MB").tag(10)
                    Text("25 MB").tag(25)
                    Text("50 MB").tag(50)
                }
                Text("Chat apps show a GIF at its own size, so a bigger limit means a bigger GIF in Slack — and a longer wait when you pick one. Yaga copies the largest version that fits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Expire unused after", selection: $settings.cacheMaxAgeDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Never").tag(0)
                }
                Text("Favourites are kept forever. GIFs used \(Library.habitThreshold)+ times are kept while you have used them in the last 6 months.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Empty Cache") {
                        Task {
                            await GifCache.shared.clear()
                            await refreshCacheUsage()
                        }
                    }
                    Button("Clear History") { library.clearHistory() }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $recording) { target in
            ShortcutRecorderSheet(
                hotkey: target.hotkey,
                conflictsWith: target.conflictsWith,
                onFinish: { recording = nil }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await refreshCacheUsage() }
        // The permission is granted in System Settings, with no notification
        // back to us, so watch for it while this page is open.
        .task {
            while !Task.isCancelled {
                accessibilityTrusted = AutoPaste.isTrusted
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func refreshCacheUsage() async {
        let usage = await GifCache.shared.usage()
        cacheFiles = usage.files
        cacheSize = usage.bytes
    }

    private var updateStatus: String {
        if let error = updates.lastError { return "Could not check: \(error)" }
        guard let checked = updates.lastChecked else { return "Not checked yet." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Up to date. Checked \(formatter.localizedString(for: checked, relativeTo: Date()))."
    }

    /// One popup button, so the row lays out exactly like the Picker rows
    /// around it. Recording moves into a sheet, which also gives the state an
    /// obvious way out.
    @ViewBuilder
    private func shortcutRow(
        _ label: String,
        hotkey: Binding<Hotkey?>,
        presets: [(name: String, hotkey: Hotkey)],
        conflictsWith: Hotkey?,
        allowsClearing: Bool
    ) -> some View {
        LabeledContent(label) {
            Menu(hotkey.wrappedValue?.displayName ?? "Off") {
                ForEach(presets, id: \.name) { preset in
                    Button(preset.name) {
                        guard preset.hotkey.problem(against: conflictsWith) == nil else {
                            hotkeyProblem = Hotkey.Problem.sameAsOther.message
                            return
                        }
                        hotkeyProblem = nil
                        hotkey.wrappedValue = preset.hotkey
                    }
                }
                Divider()
                Button("Record Shortcut…") { recording = Recording(hotkey: hotkey, conflictsWith: conflictsWith) }
                if allowsClearing {
                    Button("Off") {
                        hotkeyProblem = nil
                        hotkey.wrappedValue = nil
                    }
                }
            }
            .fixedSize()
        }
    }

    /// The sheet's subject. Held as one value so presentation and the binding
    /// it writes back to cannot drift apart.
    struct Recording: Identifiable {
        let id = UUID()
        let hotkey: Binding<Hotkey?>
        let conflictsWith: Hotkey?
    }

    /// Shown under both shortcut rows: either what was rejected while
    /// recording, or a combination the system would not hand over.
    @ViewBuilder
    private var shortcutWarning: some View {
        if let hotkeyProblem {
            warningRow(hotkeyProblem)
        } else if let taken = hotkeys.unavailable.first {
            warningRow("\(taken.displayName) is already used by another app, so it will not open Yaga.")
        }
    }

    private func warningRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
