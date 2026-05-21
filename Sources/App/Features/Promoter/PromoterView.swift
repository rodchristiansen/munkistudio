import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Core
import Infra

/// Promoter tab — three side-by-side columns (Imports / Upcoming /
/// History) over the same `PromoterStore`. Config-style affordances
/// (Promotion Rules, AutoPkg Recipes) live in the toolbar and open
/// modal sheets so they don't crowd the data columns.
///
/// The tab is opt-in; visibility is gated on
/// ``AppSettings.enablePromoterTab`` and on the user having configured
/// an AutoPkg deployment folder.
struct PromoterView: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(PromoterStore.self) private var promoterStore
    @State private var pendingEarly: PromotionCandidate?
    @State private var showRulesSheet = false
    @State private var showRecipesSheet = false
    @State private var pickingDeploymentFolder = false
    /// Cached candidate list. Recomputed only when pkginfo count or
    /// rule set changes — the full O(N×M) match is too expensive to
    /// rerun on every render with thousands of pkginfos.
    @State private var cachedCandidates: [PromotionCandidate] = []
    @State private var cachedCatalogSamples: [[String]] = []
    /// Shared selection across all three columns. Holds a namespaced
    /// row identifier (`"imports::<id>"`, `"upcoming::<url>"`,
    /// `"history::<commit>::<id>"`) so picking a row in one column
    /// clears the selection in the others — the Mac-list pattern.
    @State private var selectedRowID: String?

    var body: some View {
        Group {
            if store.repository == nil {
                ContentUnavailableView(
                    "Open a Repository",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Open a Munki repository to see promoter activity.")
                )
            } else if deploymentPath.isEmpty {
                deploymentMissingState
            } else {
                content
            }
        }
        .navigationTitle("Promoter")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showRulesSheet) {
            sheetWrapper(title: "Promotion Rules") {
                PromoterFileEditor(
                    title: "promoter.yml",
                    fileURL: deploymentURL.appending(path: "promoter.yml"),
                    supportedExtensions: ["yml", "yaml"],
                    onSaved: {
                        Task {
                            await promoterStore.refresh(
                                store: store,
                                deploymentRoot: deploymentURL
                            )
                        }
                    }
                )
            }
        }
        .fileImporter(
            isPresented: $pickingDeploymentFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            receiveDeploymentFolder(result)
        }
        .sheet(isPresented: $showRecipesSheet) {
            sheetWrapper(title: "AutoPkg Recipes") {
                PromoterFileEditor(
                    title: "recipe_list",
                    fileURL: recipeListURL,
                    supportedExtensions: ["yaml", "yml", "plist"],
                    onSaved: nil
                )
            }
        }
        .alert("Promote Early?", isPresented: earlyPresented, presenting: pendingEarly) { candidate in
            Button("Promote Now") {
                Task { await promoterStore.apply(.promote(candidate), store: store) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            let days = candidate.daysRemaining()
            Text("\(candidate.pkgName) \(candidate.version ?? "") is \(days) day\(days == 1 ? "" : "s") short of the \(candidate.requiredDays)-day window for \"\(candidate.ruleName)\". Promote anyway?")
        }
        .alert("Promoter Action Failed", isPresented: errorPresented) {
            Button("OK", role: .cancel) { promoterStore.errorMessage = nil }
        } message: {
            Text(promoterStore.errorMessage ?? "")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showRulesSheet = true } label: {
                Label("Promotion Rules", systemImage: "list.bullet.rectangle")
            }
            .help("View and edit promoter.yml")
            Button { showRecipesSheet = true } label: {
                Label("AutoPkg Recipes", systemImage: "doc.text")
            }
            .help("View and edit recipe_list (YAML or plist)")
            Button {
                Task {
                    await promoterStore.refresh(
                        store: store,
                        deploymentRoot: deploymentURL
                    )
                }
            } label: {
                if promoterStore.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(promoterStore.loading || deploymentPath.isEmpty)
            .help("Re-read promoter.yml and refresh the imports / candidates / history feeds")
        }
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 0) {
            if promoterStore.loading {
                Label("Loading promoter data…", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor), in: .capsule)
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
                    .padding(.top, 8)
            }
            HSplitView {
                columnScroll {
                    PromoterImportsSection(
                        imports: promoterStore.snapshot.imports,
                        hiddenCatalogs: hiddenCatalogs,
                        selectedRowID: $selectedRowID,
                        onOpenPackage: openInPackagesTab
                    )
                }
                columnScroll {
                    PromoterUpcomingSection(
                        candidates: cachedCandidates,
                        busyURL: promoterStore.busyURL,
                        hiddenCatalogs: hiddenCatalogs,
                        pkginfoCount: store.snapshot.pkginfos.count,
                        knownPromoteFromSets: promoterStore.snapshot.config.rules.map { $0.promoteFrom },
                        pkginfoCatalogSamples: cachedCatalogSamples,
                        repositoryPath: store.repository?.rootURL.path,
                        selectedRowID: $selectedRowID,
                        onPromote: handlePromote,
                        onDefer: { candidate in
                            Task { await promoterStore.apply(.defer_(candidate), store: store) }
                        },
                        onOpenPackage: openInPackagesTab
                    )
                }
                columnScroll {
                    PromoterHistorySection(
                        entries: promoterStore.snapshot.history,
                        hiddenCatalogs: hiddenCatalogs,
                        selectedRowID: $selectedRowID,
                        onOpenPackage: openInPackagesTab
                    )
                }
            }
        }
        .onAppear { recomputeCache(animated: false) }
        .onChange(of: store.snapshot.pkginfos.count) { _, _ in recomputeCache(animated: false) }
        .onChange(of: promoterStore.snapshot.config.rules.count) { _, _ in recomputeCache(animated: false) }
        // Animate when a promote / defer round-trip completes:
        // busyURL goes nil → URL → nil, so the trailing-nil edge is
        // the signal that the candidate list may have just changed
        // for non-load reasons. easeOut(0.25) lets the approved row
        // fade out cleanly instead of disappearing on the next tick.
        .onChange(of: promoterStore.busyURL) { _, new in
            if new == nil {
                recomputeCache(animated: true)
            }
        }
    }

    /// Recompute the candidate list + sample catalogs and store in
    /// @State. Called when pkginfo count or rule count changes, not
    /// on every render — the match is O(N×M) and dominated body
    /// time on repos with thousands of pkginfos.
    private func recomputeCache(animated: Bool) {
        let candidates = FilePromoterService.candidates(
            from: store.snapshot.pkginfos,
            config: promoterStore.snapshot.config,
            now: Date()
        )
        let samples = computeCatalogSamples()
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                cachedCandidates = candidates
                cachedCatalogSamples = samples
            }
        } else {
            cachedCandidates = candidates
            cachedCatalogSamples = samples
        }
    }

    private func computeCatalogSamples() -> [[String]] {
        var seen: Set<String> = []
        var result: [[String]] = []
        for record in store.snapshot.pkginfos {
            let catalogs = record.pkginfo.catalogs ?? []
            let key = catalogs.joined(separator: "\u{1F}")
            if seen.insert(key).inserted {
                result.append(catalogs)
                if result.count >= 5 { break }
            }
        }
        return result
    }

    /// Plain scroll wrapper for one column. The title + count live
    /// *inside* each section view (e.g. "Recent AutoPkg Imports 51"),
    /// so the column itself stays chrome-free — no double headings.
    @ViewBuilder
    private func columnScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(minWidth: 280, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Jump to the Packages tab and select the matching pkginfo by
    /// name. Used by row clicks in every column so the user can pivot
    /// from "what got promoted" to "the actual package". The lookup
    /// tries an exact name match first, then falls back to a
    /// file-basename match so AutoPkg import rows (whose `pkgName`
    /// is sometimes the dashed filename like `Chrome-147.0.7727.138`)
    /// still resolve.
    private func openInPackagesTab(named pkgName: String) {
        let lower = pkgName.lowercased()
        let record =
            store.snapshot.pkginfos.first { $0.pkginfo.name.caseInsensitiveCompare(pkgName) == .orderedSame }
            ?? store.snapshot.pkginfos.first { record in
                let base = record.fileURL.deletingPathExtension().lastPathComponent.lowercased()
                return base == lower
            }
            ?? store.snapshot.pkginfos.first { record in
                lower.hasPrefix(record.pkginfo.name.lowercased() + "-")
            }
        guard let record else { return }
        store.selectedSection = .packages
        store.selectedItemID = AnyHashable(record.id)
        let category = (record.pkginfo.category?.trimmingCharacters(in: .whitespaces)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "Uncategorized"
        store.expandedCategories.insert(category)
    }

    /// Modal sheet chrome shared by both editors.
    @ViewBuilder
    private func sheetWrapper<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Done") {
                    showRulesSheet = false
                    showRecipesSheet = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            content()
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    // MARK: Empty states

    private var deploymentMissingState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("AutoPkg deployment folder not set")
                .font(.title3.weight(.semibold))
            Text("Promoter reads `promoter.yml` and surrounding files from your AutoPkg deployment directory. Point MunkiStudio at that folder to enable this tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Choose Folder…") { chooseDeploymentFolder() }
                .buttonStyle(.borderedProminent)
            Text("This is independent of your Munki repository — you can change it any time in Settings → Features.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func handlePromote(_ candidate: PromotionCandidate) {
        if candidate.isEligible() {
            Task { await promoterStore.apply(.promote(candidate), store: store) }
        } else {
            pendingEarly = candidate
        }
    }

    private func chooseDeploymentFolder() {
        pickingDeploymentFolder = true
    }

    private func receiveDeploymentFolder(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        @Bindable var bindable = settings
        bindable.autopkgDeploymentPath = url.path
    }

    // MARK: Bindings & state

    private var deploymentPath: String {
        settings.autopkgDeploymentPath.trimmingCharacters(in: .whitespaces)
    }

    private var deploymentURL: URL {
        URL(fileURLWithPath: deploymentPath)
    }

    /// Resolve the recipe_list file. AutoPkg accepts either YAML or
    /// plist — prefer YAML names since the user's fork supports them,
    /// fall back to the legacy `.plist` if that's what exists on disk.
    private var recipeListURL: URL {
        let candidates = ["recipe_list.yaml", "recipe_list.yml", "recipe_list.plist"]
        for name in candidates {
            let url = deploymentURL.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return deploymentURL.appending(path: "recipe_list.yaml")
    }

    private var hiddenCatalogs: Set<String> {
        settings.promoterHiddenCatalogsSet
    }

    private var earlyPresented: Binding<Bool> {
        Binding(
            get: { pendingEarly != nil },
            set: { if !$0 { pendingEarly = nil } }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { promoterStore.errorMessage != nil },
            set: { if !$0 { promoterStore.errorMessage = nil } }
        )
    }
}

/// Helper for trimming hidden catalog names from a display list without
/// touching the underlying data. Empty `hidden` returns the input as-is.
func filteringHidden(_ catalogs: [String], hidden: Set<String>) -> [String] {
    guard !hidden.isEmpty else { return catalogs }
    return catalogs.filter { !hidden.contains($0) }
}
