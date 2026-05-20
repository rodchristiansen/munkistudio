import SwiftUI
import AppKit
import Core
import Infra

/// Promoter tab — preview of AutoPkg imports, upcoming promotions, and
/// promoter history. The tab is opt-in; visibility is gated on
/// ``AppSettings.enablePromoterTab`` and on the user having configured an
/// AutoPkg deployment folder (where `promoter.yml` lives).
///
/// Five tabs under a single content area:
/// - Upcoming — promotions tracked by the rules, with approve / promote
///   early / defer actions per item.
/// - Imports — recent AutoPkg import commits with version + catalogs.
/// - History — promoter commits with per-item `before → after` deltas.
/// - Rules — the raw `promoter.yml` editor.
/// - Recipe List — the AutoPkg `recipe_list.yaml` / `.plist` editor.
struct PromoterView: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var model = PromoterModel()
    @State private var pendingEarly: PromotionCandidate?
    @State private var section: PromoterSection = .upcoming

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
        .task(id: refreshKey) { await model.refresh(store: store, deploymentRoot: deploymentURL) }
        .toolbar { toolbarContent }
        .alert("Promote Early?", isPresented: earlyPresented, presenting: pendingEarly) { candidate in
            Button("Promote Now") {
                Task { await model.apply(.promote(candidate), store: store) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            let days = candidate.daysRemaining()
            Text("\(candidate.pkgName) \(candidate.version ?? "") is \(days) day\(days == 1 ? "" : "s") short of the \(candidate.requiredDays)-day window for \"\(candidate.ruleName)\". Promote anyway?")
        }
        .alert("Promoter Action Failed", isPresented: errorPresented) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Header chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.refresh(store: store, deploymentRoot: deploymentURL) }
            } label: {
                if model.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.loading || deploymentPath.isEmpty)
            .help("Re-read promoter.yml and refresh the imports / candidates / history feeds")
        }
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryHeader
            Picker("Section", selection: $section) {
                ForEach(PromoterSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .upcoming:
            ScrollView {
                PromoterUpcomingSection(
                    candidates: model.snapshot.candidates,
                    busyURL: model.busyURL,
                    hiddenCatalogs: hiddenCatalogs,
                    onPromote: handlePromote,
                    onDefer: { candidate in
                        Task { await model.apply(.defer_(candidate), store: store) }
                    }
                )
                .padding(.vertical, 4)
            }
        case .imports:
            ScrollView {
                PromoterImportsSection(
                    imports: model.snapshot.imports,
                    hiddenCatalogs: hiddenCatalogs
                )
                .padding(.vertical, 4)
            }
        case .history:
            ScrollView {
                PromoterHistorySection(
                    entries: model.snapshot.history,
                    hiddenCatalogs: hiddenCatalogs
                )
                .padding(.vertical, 4)
            }
        case .rules:
            PromoterFileEditor(
                title: "promoter.yml",
                fileURL: deploymentURL.appending(path: "promoter.yml"),
                supportedExtensions: ["yml", "yaml"],
                onSaved: {
                    Task { await model.refresh(store: store, deploymentRoot: deploymentURL) }
                }
            )
        case .recipeList:
            PromoterFileEditor(
                title: "recipe_list",
                fileURL: recipeListURL,
                supportedExtensions: ["yaml", "yml", "plist"],
                onSaved: nil
            )
        }
    }

    private var summaryHeader: some View {
        let candidates = model.snapshot.candidates
        let eligibleCount = candidates.filter { $0.isEligible() }.count
        return HStack(spacing: 16) {
            statTile(label: "Eligible now", value: "\(eligibleCount)", icon: "checkmark.seal.fill", tint: .green)
            statTile(label: "Tracked", value: "\(candidates.count)", icon: "clock.arrow.circlepath", tint: .blue)
            statTile(label: "Recent imports", value: "\(model.snapshot.imports.count)", icon: "square.and.arrow.down", tint: .indigo)
            statTile(label: "Rules", value: "\(model.snapshot.config.rules.count)", icon: "list.bullet.rectangle", tint: .secondary)
            Spacer()
        }
    }

    private func statTile(label: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint == .secondary ? AnyShapeStyle(Color.primary) : AnyShapeStyle(tint))
        }
        .padding(12)
        .frame(minWidth: 130, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
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
            Text("You can change this any time in Settings → Features.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func handlePromote(_ candidate: PromotionCandidate) {
        if candidate.isEligible() {
            Task { await model.apply(.promote(candidate), store: store) }
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
        panel.message = "Select the AutoPkg deployment folder containing promoter.yml."
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

    /// Resolve the recipe_list file. AutoPkg accepts either YAML or plist
    /// — prefer the YAML names since the user's fork supports them, but
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

    /// Recompute whenever the user reconfigures the deployment path, opens
    /// a different repo, or the pkginfo snapshot changes (a save just
    /// happened).
    private var refreshKey: String {
        let repoPath = store.repository?.rootURL.path ?? "-"
        return repoPath + "|" + deploymentPath + "|" + String(store.snapshot.pkginfos.count)
    }

    private var earlyPresented: Binding<Bool> {
        Binding(
            get: { pendingEarly != nil },
            set: { if !$0 { pendingEarly = nil } }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

/// Tabs offered by the Promoter view. The order matters — Upcoming
/// first because it's the action surface; configuration tabs sit at
/// the trailing end.
enum PromoterSection: String, CaseIterable, Identifiable, Hashable {
    case upcoming, imports, history, rules, recipeList

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upcoming: "Upcoming"
        case .imports: "Imports"
        case .history: "History"
        case .rules: "Rules"
        case .recipeList: "Recipe List"
        }
    }

    var systemImage: String {
        switch self {
        case .upcoming: "calendar.badge.clock"
        case .imports: "square.and.arrow.down"
        case .history: "clock.arrow.circlepath"
        case .rules: "list.bullet.rectangle"
        case .recipeList: "doc.text"
        }
    }
}

/// View-local observable model. Owns the latest snapshot, the loading
/// flag, the per-row busy URL, and any user-surfaced error string.
@Observable
@MainActor
final class PromoterModel {
    var snapshot: PromoterSnapshot = .empty
    var loading: Bool = false
    var busyURL: URL?
    var errorMessage: String?

    enum Action {
        case promote(PromotionCandidate)
        case defer_(PromotionCandidate)
    }

    func refresh(store: RepositoryStore, deploymentRoot: URL) async {
        guard let repo = store.repository else {
            snapshot = .empty
            return
        }
        loading = true
        defer { loading = false }
        do {
            snapshot = try await store.services.promoter.snapshot(
                repository: repo,
                deploymentRoot: deploymentRoot,
                pkginfos: store.snapshot.pkginfos
            )
        } catch {
            snapshot = .empty
            errorMessage = error.localizedDescription
        }
    }

    func apply(_ action: Action, store: RepositoryStore) async {
        let candidate: PromotionCandidate = {
            switch action {
            case .promote(let c): return c
            case .defer_(let c): return c
            }
        }()
        busyURL = candidate.pkginfoURL
        defer { busyURL = nil }
        do {
            let updated: PkginfoRecord
            switch action {
            case .promote(let c):
                updated = try await store.services.promoter.promote(c, in: store.snapshot.pkginfos)
            case .defer_(let c):
                updated = try await store.services.promoter.defer_(c, in: store.snapshot.pkginfos)
            }
            store.upsert(updated)
            // Recompute candidates against the new pkginfo state — no
            // need to re-shell git for imports / history, since neither
            // changed.
            let config = snapshot.config
            let recomputed = FilePromoterService.candidates(
                from: store.snapshot.pkginfos,
                config: config,
                now: Date()
            )
            snapshot = PromoterSnapshot(
                config: config,
                imports: snapshot.imports,
                candidates: recomputed,
                history: snapshot.history
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Helper for trimming hidden catalog names from a display list without
/// touching the underlying data. Empty `hidden` returns the input as-is.
func filteringHidden(_ catalogs: [String], hidden: Set<String>) -> [String] {
    guard !hidden.isEmpty else { return catalogs }
    return catalogs.filter { !hidden.contains($0) }
}
