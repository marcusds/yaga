import AppKit
import SwiftUI

@MainActor
final class GifSearchModel: ObservableObject {
    @Published var query = ""
    @Published var shelf: Shelf = .recent
    @Published var results: [GifItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var searchTask: Task<Void, Never>?
    private var loadedTrendingFor: ProviderKind?

    /// What the grid should currently show.
    func visibleItems(library: Library) -> [GifItem] {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return results }
        switch shelf {
        case .recent: return library.recent
        case .frequent: return library.frequent
        case .favourites: return library.favourites
        case .trending: return results
        }
    }

    func queryChanged() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        errorMessage = nil

        guard !trimmed.isEmpty else {
            results = []
            isLoading = false
            if shelf == .trending { loadTrending(force: true) }
            return
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await run { try await Settings.shared.currentProvider.search(trimmed, limit: 50) }
        }
    }

    func shelfChanged() {
        if shelf == .trending { loadTrending(force: false) }
    }

    func loadTrending(force: Bool) {
        let provider = Settings.shared.provider
        guard force || loadedTrendingFor != provider || results.isEmpty else { return }
        loadedTrendingFor = provider
        searchTask?.cancel()
        searchTask = Task {
            await run { try await Settings.shared.currentProvider.trending(limit: 50) }
        }
    }

    /// Called when the popover opens, so stale results don't linger.
    func refreshOnOpen() {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            queryChanged()
        } else if shelf == .trending {
            loadTrending(force: false)
        }
    }

    func providerChanged() {
        loadedTrendingFor = nil
        results = []
        errorMessage = nil
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            if shelf == .trending { loadTrending(force: true) }
        } else {
            queryChanged()
        }
    }

    private func run(_ work: @escaping () async throws -> [GifItem]) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let items = try await work()
            guard !Task.isCancelled else { return }
            results = items
            errorMessage = items.isEmpty ? "No GIFs found." : nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: Settings
    @StateObject private var model = GifSearchModel()
    @StateObject private var nav = KeyNav.shared
    @StateObject private var updates = UpdateChecker.shared
    @FocusState private var searchFocused: Bool
    @State private var toast: String?
    @State private var showingSettings = false
    /// Set when the panel was summoned by the paste shortcut.
    @State private var pasteMode = false
    /// Magnification at the last column change, so one long pinch can step
    /// through several sizes.
    @State private var pinchAnchor: CGFloat = 1

    private static let gridSpacing: CGFloat = 8
    private static let gridPadding: CGFloat = 10
    private static let panelWidth: CGFloat = 420

    /// Width of one cell at the current column count.
    private var cellWidth: CGFloat {
        let columns = CGFloat(settings.gridColumns)
        let available = Self.panelWidth - Self.gridPadding * 2 - Self.gridSpacing * (columns - 1)
        return max(available / columns, 60)
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Self.gridSpacing),
            count: settings.gridColumns
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if showingSettings {
                settingsHeader
                Divider()
                SettingsView()
            } else {
                header
                Divider()
                content
            }
            Divider()
            footer
        }
        .frame(width: 420, height: 520)
        .onAppear {
            searchFocused = true
            model.refreshOnOpen()
            nav.onActivate = { index in
                let items = displayItems
                guard items.indices.contains(index) else { return }
                copy(items[index])
            }
            nav.onShelfStep = { delta in
                let all = Shelf.allCases
                guard let current = all.firstIndex(of: model.shelf) else { return }
                let next = min(max(current + delta, 0), all.count - 1)
                guard next != current else { return }
                model.shelf = all[next]
                model.shelfChanged()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidOpen)) { note in
            pasteMode = note.userInfo?["paste"] as? Bool ?? false
            nav.reset()
            guard !showingSettings else { return }
            searchFocused = true
            model.refreshOnOpen()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSettingsPage)) { _ in
            withAnimation(.easeInOut(duration: 0.12)) { showingSettings.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissSettingsPage)) { _ in
            withAnimation(.easeInOut(duration: 0.12)) { showingSettings = false }
        }
        .onChange(of: showingSettings) {
            // While settings are open the popover must not close behind the
            // user's back — they may well be off in a browser copying a key.
            AppController.shared.isShowingSettings = showingSettings
            if !showingSettings { searchFocused = true }
        }
        .onChange(of: settings.provider) { model.providerChanged() }
        .onChange(of: model.query) { nav.queryDidChange() }
        .onChange(of: model.shelf) { nav.clampSelection() }
        .overlay(alignment: .bottom) { toastView }
    }

    private var settingsHeader: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button("Done") {
                withAnimation(.easeInOut(duration: 0.12)) { showingSettings = false }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(settings.provider.searchPlaceholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit { model.queryChanged() }
                    .onChange(of: model.query) { model.queryChanged() }
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        model.queryChanged()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Picker("", selection: $model.shelf) {
                    ForEach(Shelf.allCases) { shelf in
                        Label(shelf.label, systemImage: shelf.symbol).tag(shelf)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: model.shelf) { model.shelfChanged() }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(nav.zone == .shelf ? Color.accentColor : .clear, lineWidth: 2)
                        .padding(-2)
                )
            }
        }
        .padding(10)
    }

    // MARK: - Grid

    @ViewBuilder
    private var content: some View {
        let items = displayItems
        let _ = syncNav(count: items.count)
        ZStack {
            if items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                GifCell(
                                    item: item,
                                    width: cellWidth,
                                    isSelected: nav.zone == .grid && nav.selection == index,
                                    badge: index < 9 && nav.zone != .grid ? index + 1 : nil,
                                    onCopy: { copy($0) }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(Self.gridPadding)
                    }
                    .simultaneousGesture(pinchToZoom)
                    .onChange(of: nav.selection) {
                        guard nav.zone == .grid, items.indices.contains(nav.selection) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(items[nav.selection].id, anchor: .center)
                        }
                    }
                }
            }
            if model.isLoading && items.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The favourites you use most, pinned to the top of the Recent shelf so
    /// the same GIFs sit under 1/2/3 every time the panel opens. Only Recent:
    /// the other shelves each have a job, and prepending favourites to them
    /// would answer a question the user did not ask.
    private var pinnedFavourites: [GifItem] {
        guard model.query.trimmingCharacters(in: .whitespaces).isEmpty,
              model.shelf == .recent
        else { return [] }
        return library.topFavourites(limit: settings.gridColumns)
    }

    /// What the grid actually renders: the pinned row, then the shelf with any
    /// duplicates of it removed.
    private var displayItems: [GifItem] {
        let pinned = pinnedFavourites
        guard !pinned.isEmpty else { return model.visibleItems(library: library) }
        let pinnedIDs = Set(pinned.map(\.id))
        return pinned + model.visibleItems(library: library).filter { !pinnedIDs.contains($0.id) }
    }

    /// Keeps the keyboard model's picture of the grid current. Called from the
    /// view body so it cannot drift out of step with what is on screen.
    private func syncNav(count: Int) {
        nav.itemCount = count
        nav.columns = settings.gridColumns
        nav.hasShelfBar = model.query.trimmingCharacters(in: .whitespaces).isEmpty
        nav.queryIsEmpty = nav.hasShelfBar
    }

    /// Pinching in shows fewer, larger GIFs; pinching out shows more.
    private var pinchToZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let ratio = value.magnification / pinchAnchor
                if ratio > 1.25 {
                    pinchAnchor = value.magnification
                    withAnimation(.easeOut(duration: 0.12)) { settings.zoom(by: 1) }
                } else if ratio < 0.8 {
                    pinchAnchor = value.magnification
                    withAnimation(.easeOut(duration: 0.12)) { settings.zoom(by: -1) }
                }
            }
            .onEnded { _ in pinchAnchor = 1 }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.errorMessage == nil ? emptySymbol : "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(model.errorMessage ?? emptyText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if case .some(let message) = model.errorMessage, message.contains("API key") {
                Button("Open Settings…") {
                    withAnimation(.easeInOut(duration: 0.12)) { showingSettings = true }
                }
            }
        }
        .padding(30)
    }

    private var emptySymbol: String {
        model.query.isEmpty ? model.shelf.symbol : "magnifyingglass"
    }

    private var emptyText: String {
        guard model.query.trimmingCharacters(in: .whitespaces).isEmpty else { return "No GIFs found." }
        switch model.shelf {
        case .recent: return "GIFs you use will show up here."
        case .frequent: return "Your most-used GIFs will collect here."
        case .favourites: return "Right-click any GIF to favourite it."
        case .trending: return "Loading trending GIFs…"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(pasteMode ? "↵ or 1–9 to insert · drag to insert"
                                : "↵ or 1–9 to copy · drag to insert")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Both providers' terms ask for visible attribution.
                Text(settings.provider.attribution)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { showingSettings.toggle() }
            } label: {
                Image(systemName: showingSettings ? "square.grid.2x2" : "gearshape")
                    .overlay(alignment: .topTrailing) {
                        // The only hint an update exists without opening Settings.
                        if updates.updateAvailable && !showingSettings {
                            Circle()
                                .fill(.tint)
                                .frame(width: 6, height: 6)
                                .offset(x: 3, y: -2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(updateHelp)
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit Yaga (⌘Q)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var updateHelp: String {
        if showingSettings { return "Back to GIFs (⌘,)" }
        if updates.updateAvailable, let latest = updates.latestVersion {
            return "Yaga \(latest) is available — Settings (⌘,)"
        }
        return "Settings (⌘,)"
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .padding(.bottom, 46)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    // MARK: - Actions

    private func copy(_ item: GifItem) {
        library.recordUse(item)
        reportShare(item)
        Task {
            do {
                let file = try await GifCache.shared.fileOnDisk(for: item)
                let data = try await GifCache.shared.data(for: item.gifURL)
                Clipboard.copy(item: item, data: data, file: file, mode: settings.copyMode)

                if pasteMode {
                    guard AutoPaste.isTrusted else {
                        show(toast: "Needs Accessibility access — ⌘V to paste")
                        return
                    }
                    show(toast: "Pasting…")
                    if await AppController.shared.closeAndPaste() { return }
                    // Permission was revoked between the check and the paste.
                    show(toast: "GIF copied — ⌘V to paste")
                    return
                }

                show(toast: settings.copyMode == .gif ? "GIF copied — ⌘V to paste" : "Link copied")
                if settings.closeAfterCopy {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    AppController.shared.closePopover()
                }
            } catch {
                show(toast: "Couldn't copy that GIF")
            }
        }
    }

    /// KLIPY asks that picks be reported back so its ranking can learn.
    private func reportShare(_ item: GifItem) {
        guard item.id.hasPrefix("klipy:") else { return }
        KlipyProvider.registerShare(
            slug: String(item.id.dropFirst("klipy:".count)),
            key: settings.klipyKey,
            customerID: settings.customerID
        )
    }

    private func show(toast message: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeIn(duration: 0.2)) { toast = nil }
        }
    }
}

// MARK: - Cell

struct GifCell: View {
    let item: GifItem
    let width: CGFloat
    var isSelected = false
    /// The 1–9 key that picks this cell, shown until the arrow keys take over.
    var badge: Int?
    let onCopy: (GifItem) -> Void

    @EnvironmentObject private var library: Library
    @StateObject private var model = GifCellModel()
    @State private var hovering = false

    /// Follow the GIF's own proportions, but keep cells within a band of the
    /// column width so one very tall GIF cannot dominate the grid.
    private var height: CGFloat {
        min(max(width / item.aspect, width * 0.6), width * 1.4)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
            if let data = model.preview {
                AnimatedGif(data: data)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if model.failed {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
            if let badge {
                Text("\(badge)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.55), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(5)
            }
            if library.isFavourite(item) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                    .shadow(radius: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(5)
            }
        }
        .frame(height: height)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(hovering || isSelected ? Color.accentColor : Color.clear,
                              lineWidth: isSelected ? 3 : 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture { onCopy(item) }
        .onDrag {
            library.recordUse(item)
            return Clipboard.dragProvider(for: item, file: model.fullFile)
        }
        .help(item.title)
        .contextMenu {
            Button(library.isFavourite(item) ? "Remove from Favourites" : "Add to Favourites") {
                library.toggleFavourite(item)
            }
            Button("Copy Link") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString((item.sourceURL ?? item.gifURL).absoluteString, forType: .string)
            }
            if let source = item.sourceURL {
                Button("Open in Browser") { NSWorkspace.shared.open(source) }
            }
            Divider()
            Button("Remove from History") { library.forget(item) }
        }
        .task(id: item.id) { model.load(item) }
        .onDisappear { model.cancel() }
    }
}

extension Notification.Name {
    static let popoverDidOpen = Notification.Name("YagaPopoverDidOpen")
    static let toggleSettingsPage = Notification.Name("YagaToggleSettingsPage")
    static let dismissSettingsPage = Notification.Name("YagaDismissSettingsPage")
}
