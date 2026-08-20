import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var library: Library
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            Section("GIF Source") {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(ProviderKind.allCases) { Text($0.label).tag($0) }
                }
                SecureField("GIPHY API key", text: $settings.giphyKey)
                SecureField("KLIPY app key", text: $settings.klipyKey)
                HStack {
                    Spacer()
                    Link("Get a free \(settings.provider.label) key", destination: settings.provider.keyURL)
                        .font(.caption)
                }
                Picker("Content filter", selection: $settings.contentFilter) {
                    ForEach(ContentFilter.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Behaviour") {
                Picker("Shortcut", selection: hotkeyBinding) {
                    ForEach(Hotkey.presets, id: \.name) { Text($0.name).tag($0.hotkey) }
                }
                Picker("Clicking a GIF copies", selection: $settings.copyMode) {
                    ForEach(CopyMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Close window after copying", isOn: $settings.closeAfterCopy)
            }

            Section("Storage") {
                LabeledContent("Cached GIFs", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                Picker("Keep at most", selection: $settings.cacheLimitMB) {
                    Text("250 MB").tag(250)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                }
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
                            cacheSize = await GifCache.shared.diskSize()
                        }
                    }
                    Button("Clear History") { library.clearHistory() }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { cacheSize = await GifCache.shared.diskSize() }
    }

    private var hotkeyBinding: Binding<Hotkey> {
        Binding(get: { settings.hotkey }, set: { settings.hotkey = $0 })
    }
}
