import SwiftUI
import AppKit
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
                column(title: "Imports", systemImage: "square.and.arrow.down", count: promoterStore.snapshot.imports.count) {
                    PromoterImportsSection(
                        imports: promoterStore.snapshot.imports,
                        hiddenCatalogs: hiddenCatalogs
                    )
                }
                column(title: "Upcoming", systemImage: "calendar.badge.clock", count: promoterStore.snapshot.candidates.count) {
                    PromoterUpcomingSection(
                        candidates: promoterStore.snapshot.candidates,
                        busyURL: promoterStore.busyURL,
                        hiddenCatalogs: hiddenCatalogs,
                        pkginfoCount: store.snapshot.pkginfos.count,
                        knownPromoteFromSets: promoterStore.snapshot.config.rules.map { $0.promoteFrom },
                        pkginfoCatalogSamples: catalogSamples,
                        repositoryPath: store.repository?.rootURL.path,
                        onPromote: handlePromote,
                        onDefer: { candidate in
                            Task { await promoterStore.apply(.defer_(candidate), store: store) }
                        }
                    )
                }
                column(title: "History", systemImage: "clock.arrow.circlepath", count: promoterStore.snapshot.history.count) {
                    PromoterHistorySection(
                        entries: promoterStore.snapshot.history,
                        hiddenCatalogs: hiddenCatalogs
                    )
                }
            }
        }
    }

    /// One scrollable column wrapped in a header strip. Each column is
    /// independently resizable via the `HSplitView` divider so the user
    /// can give whichever column they're focused on more room.
    @ViewBuilder
    private func column<Content: View>(
        title: String,
        systemImage: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                Text(title).font(.headline)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                content()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 280, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
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
        @Bindable var bindable = settings
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select the AutoPkg deployment folder containing promoter.yml. This is independent of your Munki repository folder."
        if panel.runModal() == .OK, let url = panel.url {
            bindable.autopkgDeploymentPath = url.path
        }
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

    /// Up to 5 distinct catalog signatures from the loaded pkginfos —
    /// surfaced in the diagnostic so the user can eyeball them against
    /// the rules' `promote_from` sets.
    private var catalogSamples: [[String]] {
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
