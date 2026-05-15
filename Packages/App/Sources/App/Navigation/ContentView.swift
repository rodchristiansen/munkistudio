import SwiftUI
import Core
import AppKit

/// Root view. Shows the repo picker until one is opened, then a
/// three-column `NavigationSplitView` whose middle / detail columns
/// switch on the selected ``SidebarSection``.
struct ContentView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        Group {
            if store.repository == nil {
                RepositoryPickerView()
            } else {
                RepositoryWorkspace()
            }
        }
        .navigationTitle(store.repository?.displayName ?? "MunkiStudio")
        .task { await autoOpenIfAvailable() }
    }

    /// Re-open the last repo automatically. Fires at most once per
    /// launch because `store.repository` is non-nil after the first
    /// successful open.
    private func autoOpenIfAvailable() async {
        guard store.repository == nil,
              let recent = store.recentRepositories.first,
              FileManager.default.fileExists(atPath: recent.path) else { return }
        await store.open(rootURL: recent)
    }
}

/// Full workspace. The Git section is a single full-width view; the
/// other sections use the standard sidebar / list / detail split.
struct RepositoryWorkspace: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        @Bindable var bindableStore = store
        Group {
            if store.selectedSection.prefersFullWidth {
                NavigationSplitView {
                    SidebarView(selection: $bindableStore.selectedSection)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
                } detail: {
                    FullWidthColumn(section: store.selectedSection)
                }
            } else {
                NavigationSplitView {
                    SidebarView(selection: $bindableStore.selectedSection)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
                } content: {
                    ContentColumn(section: store.selectedSection)
                        .navigationSplitViewColumnWidth(min: 300, ideal: 420, max: .infinity)
                } detail: {
                    DetailColumn(section: store.selectedSection)
                }
            }
        }
        // Floating results panel anchored under the toolbar on the
        // right. `.searchSuggestions` couldn't escape the field's
        // width, so we draw our own panel. It only appears when the
        // user has an active query with hits; clicking a row routes
        // to the file and clears the query. A transparent backdrop
        // catches clicks outside the panel and dismisses by clearing
        // the query, matching popover behaviour.
        .overlay(alignment: .topTrailing) {
            if store.searchQuery.count >= 2 && !store.searchResults.isEmpty {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { store.searchQuery = "" }
                    SearchResultsFloatingPanel()
                        .padding(.trailing, 16)
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.12), value: store.searchResults.count)
        // Native `.searchable` so macOS 26 draws the chrome and the
        // field collapses / expands consistently with Finder and Mail.
        .searchable(
            text: $bindableStore.searchQuery,
            placement: .toolbar,
            prompt: "Search the repo"
        )
        // Recompute results only when the query changes, not on every
        // SwiftUI body invocation. Hovering over a suggestion row
        // re-renders the list; without this cache, each hover ran the
        // scanner over every file on disk, producing the flicker.
        .task(id: store.searchQuery) {
            let query = store.searchQuery
            guard query.count >= 2 else {
                store.searchResults = []
                return
            }
            // Tiny debounce so fast typing doesn't kick off a scan
            // mid-keystroke. 120ms is below human-perceivable latency
            // but enough to coalesce a burst of keypresses.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, store.searchQuery == query else { return }
            let results = SearchScanner.run(query: query, store: store)
            guard !Task.isCancelled, store.searchQuery == query else { return }
            store.searchResults = results
        }
        .toolbar {
            // `.labelStyle(.titleAndIcon)` on Save forces both the count
            // and the glyph to render — without it the toolbar auto-
            // collapses to icon-only on tight widths and the dirty-count
            // badge disappears.
            ToolbarItem(placement: .primaryAction) {
                let dirtyCount = store.dirtyDraftCount
                Button {
                    Task { await store.saveSession() }
                } label: {
                    if dirtyCount > 0 {
                        Label("Save (\(dirtyCount))", systemImage: "tray.and.arrow.down.fill")
                    } else {
                        Label("Save", systemImage: "tray.and.arrow.down")
                    }
                }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(dirtyCount == 0)
                .help("Flush every unsaved edit in this session to disk")
            }
            // Without an explicit ToolbarSpacer between them, macOS 26
            // groups consecutive `.primaryAction` items into a single
            // pill — Save and Refresh fuse with no visual seam.
            // `.fixed` keeps them adjacent but rendered as separate
            // capsules.
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Re-read the repository from disk")
            }
        }
    }
}

private struct SidebarView: View {
    @Binding var selection: SidebarSection

    var body: some View {
        List(SidebarSection.allCases, selection: Binding(
            get: { Optional(selection) },
            set: { if let value = $0 { selection = value } }
        )) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
        .navigationTitle("Repository")
    }
}

private struct ContentColumn: View {
    @Environment(RepositoryStore.self) private var store
    let section: SidebarSection

    var body: some View {
        switch section {
        case .dashboard: DashboardView()
        case .packages: PackagesListView()
        case .manifests: ManifestsListView()
        case .catalogs: CatalogsListView()
        case .git: GitView()
        }
    }
}

private struct DetailColumn: View {
    @Environment(RepositoryStore.self) private var store
    let section: SidebarSection

    var body: some View {
        switch section {
        case .dashboard: DashboardDetailView()
        case .packages: PackageDetailView()
        case .manifests: ManifestDetailView()
        case .catalogs: CatalogDetailView()
        case .git: GitDetailView()
        }
    }
}

private struct FullWidthColumn: View {
    let section: SidebarSection

    var body: some View {
        switch section {
        case .dashboard: DashboardView()
        case .git: GitView()
        default: EmptyView()
        }
    }
}

/// Compact toolbar chip showing the current branch + ahead/behind +
/// dirty dot. Sits in the trailing toolbar group beside the action
/// buttons so it reads as a status indicator, not a header.
struct RepositoryChip: View {
    let info: GitRepositoryInfo
    let dirtyCount: Int

    var body: some View {
        // macOS 26's toolbar wraps each item in a capsule; without
        // explicit horizontal padding the leading glyph clips against
        // the capsule's inner edge. The padding lives on the HStack so
        // the capsule sizes around it correctly.
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text(info.currentBranch ?? "(detached)")
                .font(.callout)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if dirtyCount > 0 {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .help("\(dirtyCount) uncommitted change\(dirtyCount == 1 ? "" : "s")")
            }
            if info.aheadCount > 0 {
                Image(systemName: "arrow.up")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text("\(info.aheadCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if info.behindCount > 0 {
                Image(systemName: "arrow.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text("\(info.behindCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .help("Current branch")
    }
}
