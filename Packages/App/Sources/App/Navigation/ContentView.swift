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
    @State private var makecatalogsPresented: Bool = false

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
                    // No `max:` — when categories or catalog groups
                    // expand, long folder names like
                    // `installed_applications_lab` would clip against
                    // the old 600pt ceiling. Letting the user drag
                    // arbitrarily wide solves it for every list.
                    ContentColumn(section: store.selectedSection)
                        .navigationSplitViewColumnWidth(min: 300, ideal: 420, max: .infinity)
                } detail: {
                    DetailColumn(section: store.selectedSection)
                }
            }
        }
        .toolbar {
            // The chip lives in its own ToolbarItem so the trailing
            // group can't squeeze it. `.fixedSize()` keeps the branch
            // icon + text from being elided when the toolbar is tight.
            ToolbarItem(placement: .primaryAction) {
                if let info = store.gitInfo {
                    RepositoryChip(info: info, dirtyCount: store.gitDirtyCount)
                        .fixedSize()
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
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
                .keyboardShortcut("s", modifiers: .command)
                .disabled(dirtyCount == 0)
                .help("Flush every unsaved edit in this session to disk")
                if store.gitInfo != nil {
                    Button {
                        Task { await store.runGitFetch() }
                    } label: {
                        Label("Fetch", systemImage: "arrow.down.to.line")
                    }
                    .disabled(store.gitActionInFlight != nil)
                    .help("git fetch")
                    Button {
                        Task { await store.runGitPull() }
                    } label: {
                        Label("Pull", systemImage: "arrow.down")
                    }
                    .disabled(store.gitActionInFlight != nil)
                    .help("git pull --rebase --autostash")
                    Button {
                        Task { await store.runGitPush() }
                    } label: {
                        Label("Push", systemImage: "arrow.up")
                    }
                    .disabled(store.gitActionInFlight != nil)
                    .help("git push")
                }
                Button {
                    makecatalogsPresented = true
                } label: {
                    Label("makecatalogs", systemImage: "books.vertical")
                }
                Button {
                    Task { await store.reload() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $makecatalogsPresented) {
            MakecatalogsSheet()
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
        case .search: SearchView()
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
        case .search: SearchDetailView()
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
        case .search: SearchView()
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
