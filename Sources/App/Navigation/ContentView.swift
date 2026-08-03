import SwiftUI
import Core
import AppKit
import UniformTypeIdentifiers

/// Root view. Shows the repo picker until one is opened, then a
/// three-column `NavigationSplitView` whose middle / detail columns
/// switch on the selected ``SidebarSection``.
struct ContentView: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(AppSettings.self) private var settings

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
        .sheet(isPresented: onboardingPresented) {
            OnboardingView()
                // The wizard leaves only through its own buttons. Without
                // this, a stray dismissal drops the user at an empty app
                // with no way back to setup.
                .interactiveDismissDisabled()
        }
        .fileImporter(
            isPresented: openRepositoryPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await store.open(rootURL: url) }
            }
        }
    }

    private var openRepositoryPresented: Binding<Bool> {
        Binding(
            get: { store.openRepositoryPickerRequested },
            set: { store.openRepositoryPickerRequested = $0 }
        )
    }

    /// Drives the first-run onboarding sheet.
    ///
    /// Two rules here, both of them scar tissue:
    ///
    /// 1. The `get` reads *stored* state, never a recomputed condition.
    ///    It used to be `!hasCompletedOnboarding && !isAlreadyConfigured`,
    ///    so opening a repository inside the wizard — the wizard's own
    ///    step — made the install "configured" and dismissed the sheet
    ///    out from under the user. The decision is made once, in
    ///    ``resolveOnboarding()``.
    ///
    /// 2. The `set` only mirrors presentation. It must **not** record
    ///    completion: SwiftUI writes `false` through a sheet binding for
    ///    reasons that have nothing to do with the user finishing
    ///    (teardown, window changes, accessibility clients inspecting the
    ///    hierarchy). Treating any of those as "onboarding done" burned
    ///    the flag permanently after a stray write. Only ``finish()`` —
    ///    reached from Skip Setup or Get Started — completes onboarding.
    private var onboardingPresented: Binding<Bool> {
        Binding(
            get: { store.isShowingOnboarding },
            set: { store.isShowingOnboarding = $0 }
        )
    }

    /// True once the user has any real configuration: a previously
    /// opened repository, or a feature folder set by hand in Settings.
    /// Used to keep first-run onboarding away from an already-working
    /// install (e.g. an upgrade that adds new onboarding steps).
    private var isAlreadyConfigured: Bool {
        OnboardingGate.isAlreadyConfigured(
            recentRepositoryCount: store.recentRepositories.count,
            featurePaths: [
                settings.munkipkgProjectsPath,
                settings.autopkgDeploymentPath,
                settings.profilesDirectoryPath
            ]
        )
    }

    /// Settle the first-run question once per launch, before anything
    /// else can change the inputs it reads.
    private func resolveOnboarding() {
        // An already-configured user upgrading into a build that adds
        // onboarding steps should never see the wizard. Persist the
        // completion flag so the suppression sticks across launches.
        if OnboardingGate.shouldBackfillCompletion(
            hasCompletedOnboarding: settings.hasCompletedOnboarding,
            isAlreadyConfigured: isAlreadyConfigured
        ) {
            settings.hasCompletedOnboarding = true
        }
        store.isShowingOnboarding = OnboardingGate.shouldPresentOnLaunch(
            hasCompletedOnboarding: settings.hasCompletedOnboarding,
            isAlreadyConfigured: isAlreadyConfigured
        )
    }

    /// Re-open the last repo automatically. Fires at most once per
    /// launch because `store.repository` is non-nil after the first
    /// successful open.
    private func autoOpenIfAvailable() async {
        resolveOnboarding()
        // Don't race a repo open against the wizard — the wizard's own
        // repository step is where a first-run user chooses one.
        guard !store.isShowingOnboarding,
              settings.reopenLastRepositoryOnLaunch,
              store.repository == nil,
              let recent = store.recentRepositories.first,
              FileManager.default.fileExists(atPath: recent.path) else { return }
        await store.open(rootURL: recent)
    }
}

/// Full workspace. The Git section is a single full-width view; the
/// other sections use the standard sidebar / list / detail split.
struct RepositoryWorkspace: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        // Honour Reduce Motion: the slide-from-top
                        // transition becomes a no-op crossfade, and the
                        // implicit animation is suppressed entirely so
                        // the panel snaps in instead of sliding.
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: store.searchResults.count)
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
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    store.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!store.canGoBack)
                .help("Back")

                Button {
                    store.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!store.canGoForward)
                .help("Forward")
            }
            // `.labelStyle(.titleAndIcon)` on Save keeps the dirty-count
            // badge visible at tight widths — otherwise the toolbar
            // collapses to icon-only and the count disappears.
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
        }
    }
}

private struct SidebarView: View {
    @Binding var selection: SidebarSection
    @Environment(AppSettings.self) private var settings
    @Environment(RepositoryStore.self) private var store

    /// Not every section is always shown:
    /// - Build appears once a munkipkg projects folder is configured.
    /// - Git appears when the open repo is a git working tree, unless the
    ///   user has hidden it in Settings.
    private var sections: [SidebarSection] {
        SidebarSection.allCases.filter { section in
            switch section {
            case .build:
                return !settings.munkipkgProjectsPath.trimmingCharacters(in: .whitespaces).isEmpty
            case .git:
                return store.gitInfo != nil && settings.showGitSection
            case .promoter:
                return settings.enablePromoterTab
            case .profiles:
                return settings.enableProfilesTab
            default:
                return true
            }
        }
    }

    var body: some View {
        List(sections, selection: Binding(
            get: { Optional(selection) },
            set: { if let value = $0 { selection = value } }
        )) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
        .navigationTitle("Repository")
        // If the selected section is no longer available (Build folder
        // cleared, Git tab hidden or repo isn't a git tree), fall back to
        // the dashboard so the detail column doesn't render an orphan.
        .onChange(of: sections) { _, current in
            if !current.contains(selection) { selection = .dashboard }
        }
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
        case .profiles: ProfilesListView()
        case .catalogs: CatalogsListView()
        case .dependencies: EmptyView()
        case .build: EmptyView()
        case .clean: EmptyView()
        case .importer: EmptyView()
        case .promoter: EmptyView()
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
        case .profiles: ProfileDetailView()
        case .catalogs: CatalogDetailView()
        case .dependencies: EmptyView()
        case .build: EmptyView()
        case .clean: EmptyView()
        case .importer: EmptyView()
        case .promoter: EmptyView()
        case .git: GitDetailView()
        }
    }
}

private struct FullWidthColumn: View {
    let section: SidebarSection

    var body: some View {
        Group {
            switch section {
            case .dashboard: DashboardView()
            case .git: GitView()
            case .importer: ImportView()
            case .dependencies: DependenciesView()
            case .build: BuildView()
            case .clean: CleanView()
            case .promoter: PromoterView()
            default: EmptyView()
            }
        }
        .navigationTitle(section.title)
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
