import SwiftUI
import Core
import Infra

/// Repo-overview home view. Inspired by CimianAdmin's Dashboard tile
/// page — at-a-glance counts, recent commits, and a global search
/// entry point so users start in a hub and dive out from there.
struct DashboardView: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(PromoterStore.self) private var promoterStore
    @Environment(ProfileStore.self) private var profileStore
    @State private var recentCommits: [GitCommit] = []
    /// Cached candidate list — same caching strategy as the Promoter
    /// tab so the dashboard tiles don't trigger 1366×rules set
    /// comparisons on every render.
    @State private var cachedCandidates: [PromotionCandidate] = []
    @State private var repoBytes: Int64 = 0
    @State private var reclaimableBytes: Int64 = 0
    @State private var orphanPackages: [PkginfoRecord] = []
    @State private var todayImportCount: Int = 0
    @State private var profileErrorCount: Int = 0
    @State private var dependencyIssueCount: Int = 0
    @State private var largestPackages: [PkginfoRecord] = []
    @State private var topDevelopers: [(String, Int)] = []
    @State private var topCategories: [(String, Int)] = []
    @State private var missingCategoryCount: Int = 0
    @State private var missingDescriptionCount: Int = 0
    @State private var missingDeveloperCount: Int = 0
    @State private var unhashedCount: Int = 0
    @State private var unattendedCount: Int = 0
    @State private var forcedInstallCount: Int = 0
    @ScaledMetric(relativeTo: .caption) private var shaColumnWidth: CGFloat = 70

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                repositorySection
                healthCheckSection
                activitySection
                if let info = store.gitInfo {
                    recentCommitsCard(info: info)
                }
                recentlyModifiedRow
                insightsRow
                if !orphanPackages.isEmpty {
                    orphanPackagesCard
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Dashboard")
        .task(id: store.gitInfo?.workTreeRoot) { await loadCommits() }
        .onAppear {
            recomputeCandidates()
            recomputeMetrics()
        }
        .onChange(of: store.snapshot.pkginfos.count) { _, _ in
            recomputeCandidates()
            recomputeMetrics()
        }
        .onChange(of: store.snapshot.manifests.count) { _, _ in recomputeMetrics() }
        .onChange(of: profileStore.records.count) { _, _ in recomputeMetrics() }
        .onChange(of: promoterStore.snapshot.imports.count) { _, _ in recomputeMetrics() }
        .onChange(of: promoterStore.snapshot.config.rules.count) { _, _ in recomputeCandidates() }
        // Invalidate after every promote/defer round-trip — busyURL
        // returns to nil once the action commits, signalling that a
        // candidate may have just transitioned out of the tracked set.
        .onChange(of: promoterStore.busyURL) { _, new in
            if new == nil { recomputeCandidates() }
        }
    }

    private func recomputeCandidates() {
        cachedCandidates = FilePromoterService.candidates(
            from: store.snapshot.pkginfos,
            config: promoterStore.snapshot.config,
            now: Date()
        )
    }

    /// `installer_item_size` is documented as kilobytes in the Munki
    /// pkginfo schema. Multiply by 1024 here so every consumer is in
    /// raw bytes and ByteCountFormatter scales it correctly.
    private static func sizeBytes(_ record: PkginfoRecord) -> Int64 {
        Int64(record.pkginfo.installerItemSize ?? 0) * 1024
    }

    private func recomputeMetrics() {
        let pkginfos = store.snapshot.pkginfos
        let manifests = store.snapshot.manifests

        repoBytes = pkginfos.reduce(Int64(0)) { $0 + Self.sizeBytes($1) }

        var byName: [String: [PkginfoRecord]] = [:]
        for record in pkginfos { byName[record.pkginfo.name, default: []].append(record) }
        reclaimableBytes = byName.values.reduce(Int64(0)) { acc, group in
            guard group.count > 1 else { return acc }
            // Treat the highest-version record (by simple version sort)
            // as current; everything else is reclaimable.
            let sorted = group.sorted { lhs, rhs in
                (lhs.pkginfo.version ?? "") < (rhs.pkginfo.version ?? "")
            }
            let older = sorted.dropLast()
            return acc + older.reduce(Int64(0)) { $0 + Self.sizeBytes($1) }
        }

        let referenced = Self.allReferencedPackageNames(manifests: manifests)
        orphanPackages = pkginfos
            .filter { !referenced.contains($0.pkginfo.name) }
            .sorted { Self.sizeBytes($0) > Self.sizeBytes($1) }

        let dayAgo = Date().addingTimeInterval(-24 * 60 * 60)
        todayImportCount = promoterStore.snapshot.imports.filter { $0.date >= dayAgo }.count

        profileErrorCount = profileStore.records.reduce(0) { acc, record in
            let issues = MobileConfigValidator.validate(
                record.xmlString,
                schema: profileStore.payloadSchema
            )
            return acc + (issues.contains(where: { $0.severity == .error }) ? 1 : 0)
        }

        let graph = DependencyGraphBuilder.build(pkginfos: pkginfos.map(\.pkginfo))
        dependencyIssueCount = DependencyLinter.analyze(graph).count

        largestPackages = pkginfos
            .filter { Self.sizeBytes($0) > 0 }
            .sorted { Self.sizeBytes($0) > Self.sizeBytes($1) }
            .prefix(5)
            .map { $0 }

        topDevelopers = Self.topGroups(pkginfos) { $0.pkginfo.developer }
        topCategories = Self.topGroups(pkginfos) { $0.pkginfo.category }

        // Munki-wiki quality signals — these all surface things the
        // Munki docs treat as expectations for a well-tended pkginfo:
        // category & developer are recommended for Managed Software
        // Center grouping; description is required to actually appear
        // there at all; installer_item_hash is the integrity guard.
        missingCategoryCount = pkginfos.filter {
            ($0.pkginfo.category?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }.count
        missingDescriptionCount = pkginfos.filter {
            ($0.pkginfo.description?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }.count
        missingDeveloperCount = pkginfos.filter {
            ($0.pkginfo.developer?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }.count
        // Hash only matters for items that actually carry an installer
        // item (a package, image, or staged installer). Drag-n-drop /
        // copy-from-dmg style entries legitimately have no hash, so
        // gate the count on the presence of an installer_item_location.
        unhashedCount = pkginfos.filter {
            let pkg = $0.pkginfo
            let hasInstaller = !(pkg.installerItemLocation?.isEmpty ?? true)
            let missingHash = (pkg.installerItemHash?.isEmpty ?? true)
            return hasInstaller && missingHash
        }.count
        unattendedCount = pkginfos.filter { $0.pkginfo.unattendedInstall == true }.count
        let now = Date()
        forcedInstallCount = pkginfos.filter {
            ($0.pkginfo.forceInstallAfterDate ?? .distantPast) > now
        }.count
    }

    /// Walk a manifest's install / uninstall / featured / default /
    /// optional lists plus every nested `conditional_items` block,
    /// returning every package name referenced anywhere. Used by the
    /// orphan-packages computation. `included_manifests` entries are
    /// intentionally skipped — those reference other manifests, not
    /// pkginfos.
    private static func allReferencedPackageNames(manifests: [ManifestRecord]) -> Set<String> {
        var names: Set<String> = []

        func collect(_ list: [String]?) {
            guard let list else { return }
            for entry in list { names.insert(entry) }
        }

        func walk(_ items: [ConditionalItem]?) {
            guard let items else { return }
            for item in items {
                collect(item.managedInstalls)
                collect(item.managedUninstalls)
                collect(item.managedUpdates)
                collect(item.optionalInstalls)
                collect(item.featuredItems)
                walk(item.conditionalItems)
            }
        }

        for record in manifests {
            let m = record.manifest
            collect(m.managedInstalls)
            collect(m.managedUninstalls)
            collect(m.managedUpdates)
            collect(m.optionalInstalls)
            collect(m.featuredItems)
            collect(m.defaultInstalls)
            walk(m.conditionalItems)
        }
        return names
    }

    private static func topGroups(
        _ pkginfos: [PkginfoRecord],
        by key: (PkginfoRecord) -> String?
    ) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for record in pkginfos {
            guard let raw = key(record)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { continue }
            counts[raw, default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(5)
            .map { ($0.key, $0.value) }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.zeroPadsFractionDigits = false
        return formatter
    }()

    private static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        return byteFormatter.string(fromByteCount: bytes)
    }

    // MARK: Insights row

    /// Three side-by-side info cards: largest packages, top developers,
    /// top categories. Hidden when there's nothing meaningful to show.
    @ViewBuilder
    private var insightsRow: some View {
        if !largestPackages.isEmpty || !topDevelopers.isEmpty || !topCategories.isEmpty {
            let columns = [
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14)
            ]
            LazyVGrid(columns: columns, spacing: 14) {
                if !largestPackages.isEmpty { largestPackagesCard }
                if !topDevelopers.isEmpty { topDevelopersCard }
                if !topCategories.isEmpty { topCategoriesCard }
            }
        }
    }

    private var largestPackagesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "scalemass")
                    .foregroundStyle(.blue)
                Text("Largest Packages").font(.headline)
                Spacer()
            }
            .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(largestPackages, id: \.id) { record in
                    Button {
                        openPackage(record)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(record.pkginfo.name)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(Self.formatBytes(Self.sizeBytes(record)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var topDevelopersCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .foregroundStyle(.pink)
                Text("Top Developers").font(.headline)
                Spacer()
            }
            .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(topDevelopers, id: \.0) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.0).font(.callout).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(entry.1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var topCategoriesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.teal)
                Text("Top Categories").font(.headline)
                Spacer()
            }
            .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(topCategories, id: \.0) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.0).font(.callout).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(entry.1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var orphanPackagesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.folder")
                    .foregroundStyle(.orange)
                Text("Orphan Packages").font(.headline)
                Text("\(orphanPackages.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 6)
            Text("Not referenced by any manifest's install / uninstall / featured / default / optional list.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(orphanPackages.prefix(8), id: \.id) { record in
                    Button {
                        openPackage(record)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(record.pkginfo.name)
                                .font(.callout)
                                .lineLimit(1)
                            if let version = record.pkginfo.version {
                                Text(version)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            let bytes = Self.sizeBytes(record)
                            if bytes > 0 {
                                Text(Self.formatBytes(bytes))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                if orphanPackages.count > 8 {
                    Text("…and \(orphanPackages.count - 8) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Recently modified

    private var recentlyModifiedRow: some View {
        let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        return LazyVGrid(columns: columns, spacing: 14) {
            recentPackagesCard
            recentManifestsCard
        }
    }

    private var recentPackagesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(Color.munkiStudioBrand)
                Text("Recently Modified Packages").font(.headline)
                Spacer()
            }
            .padding(.bottom, 8)
            if recentPackages.isEmpty {
                Text("No packages yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recentPackages, id: \.id) { record in
                        Button {
                            openPackage(record)
                        } label: {
                            recentPackageRow(record)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func recentPackageRow(_ record: PkginfoRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(record.pkginfo.name)
                .font(.callout)
                .lineLimit(1)
            if let version = record.pkginfo.version {
                Text(version)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if let date = record.modifiedAt {
                Text(relative(date))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
    }

    private var recentManifestsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(.tint)
                Text("Recently Modified Manifests").font(.headline)
                Spacer()
            }
            .padding(.bottom, 8)
            if recentManifests.isEmpty {
                Text("No manifests yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recentManifests, id: \.id) { record in
                        Button {
                            openManifest(record)
                        } label: {
                            recentManifestRow(record)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func recentManifestRow(_ record: ManifestRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(record.manifest.manifestName)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let date = record.modifiedAt {
                Text(relative(date))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
    }

    private var recentPackages: [PkginfoRecord] {
        store.snapshot.pkginfos
            .filter { $0.modifiedAt != nil }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            .prefix(6)
            .map { $0 }
    }

    private var recentManifests: [ManifestRecord] {
        store.snapshot.manifests
            .filter { $0.modifiedAt != nil }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            .prefix(6)
            .map { $0 }
    }

    private func openPackage(_ record: PkginfoRecord) {
        store.selectedSection = .packages
        store.selectedItemID = AnyHashable(record.id)
        let category = record.pkginfo.category?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Uncategorized"
        store.expandedCategories.insert(category)
    }

    private func openManifest(_ record: ManifestRecord) {
        store.selectedSection = .manifests
        store.selectedItemID = AnyHashable(record.id)
    }

    // MARK: Stat sections

    /// Three labeled sections — Repository, Health Check, Activity —
    /// each with its own 5-column tile grid. Section headers are
    /// plain icon + title (no vertical accent bar) to keep the page
    /// quiet but still readable as three short stories.

    private static let gridColumns = Array(
        repeating: GridItem(.flexible(), spacing: 14), count: 5
    )

    private var repositorySection: some View {
        StatSection(title: "Repository", icon: "shippingbox.fill", accent: .munkiStudioBrand) {
            LazyVGrid(columns: Self.gridColumns, spacing: 14) {
                StatTile(
                    label: "Packages",
                    value: "\(store.snapshot.pkginfos.count)",
                    icon: "shippingbox",
                    color: .munkiStudioBrand
                ) { store.selectedSection = .packages }
                StatTile(
                    label: "Manifests",
                    value: "\(store.snapshot.manifests.count)",
                    icon: "list.bullet.rectangle",
                    color: .indigo
                ) { store.selectedSection = .manifests }
                StatTile(
                    label: "Catalogs",
                    value: "\(store.snapshot.catalogs.count)",
                    icon: "books.vertical",
                    color: .purple
                ) { store.selectedSection = .catalogs }
                StatTile(
                    label: "Categories",
                    value: "\(uniqueCategories.count)",
                    icon: "square.grid.2x2",
                    color: .teal,
                    action: nil
                )
                StatTile(
                    label: "Developers",
                    value: "\(uniqueDevelopers.count)",
                    icon: "person",
                    color: .pink,
                    action: nil
                )
                if settings.enableProfilesTab {
                    StatTile(
                        label: "Profiles",
                        value: "\(profileStore.records.count)",
                        icon: "doc.text",
                        color: .cyan
                    ) { store.selectedSection = .profiles }
                }
                StatTile(
                    label: "Repo size",
                    value: Self.formatBytes(repoBytes),
                    icon: "internaldrive",
                    color: .blue,
                    action: nil
                )
                if reclaimableBytes > 0 {
                    StatTile(
                        label: "Reclaimable",
                        value: Self.formatBytes(reclaimableBytes),
                        icon: "trash.slash",
                        color: .orange,
                        action: nil
                    )
                }
                if !orphanPackages.isEmpty {
                    StatTile(
                        label: "Orphan packages",
                        value: "\(orphanPackages.count)",
                        icon: "questionmark.folder",
                        color: .orange
                    ) { store.selectedSection = .packages }
                }
                if let biggest = largestPackages.first {
                    StatTile(
                        label: "Largest single",
                        value: Self.formatBytes(Self.sizeBytes(biggest)),
                        icon: "scalemass",
                        color: .blue
                    ) { openPackage(biggest) }
                }
            }
        }
    }

    private var healthCheckSection: some View {
        StatSection(title: "Health Check", icon: "stethoscope", accent: .red) {
            LazyVGrid(columns: Self.gridColumns, spacing: 14) {
                if missingDescriptionCount > 0 {
                    StatTile(
                        label: "No description",
                        value: "\(missingDescriptionCount)",
                        icon: "text.badge.xmark",
                        color: .red
                    ) { store.selectedSection = .packages }
                }
                if missingCategoryCount > 0 {
                    StatTile(
                        label: "No category",
                        value: "\(missingCategoryCount)",
                        icon: "tray.2",
                        color: .orange
                    ) { store.selectedSection = .packages }
                }
                if missingDeveloperCount > 0 {
                    StatTile(
                        label: "No developer",
                        value: "\(missingDeveloperCount)",
                        icon: "person.crop.circle.badge.questionmark",
                        color: .yellow
                    ) { store.selectedSection = .packages }
                }
                if unhashedCount > 0 {
                    StatTile(
                        label: "Unhashed",
                        value: "\(unhashedCount)",
                        icon: "lock.open.trianglebadge.exclamationmark",
                        color: .red
                    ) { store.selectedSection = .packages }
                }
                if dependencyIssueCount > 0 {
                    StatTile(
                        label: "Dependency issues",
                        value: "\(dependencyIssueCount)",
                        icon: "exclamationmark.triangle",
                        color: .yellow
                    ) { store.selectedSection = .dependencies }
                }
                if settings.enableProfilesTab, profileErrorCount > 0 {
                    StatTile(
                        label: "Profile errors",
                        value: "\(profileErrorCount)",
                        icon: "exclamationmark.triangle.fill",
                        color: .red
                    ) { store.selectedSection = .profiles }
                }
            }
        }
    }

    private var activitySection: some View {
        StatSection(title: "Activity", icon: "bolt.horizontal", accent: .green) {
            LazyVGrid(columns: Self.gridColumns, spacing: 14) {
                StatTile(
                    label: "Uncommitted",
                    value: "\(store.gitDirtyCount)",
                    icon: "arrow.triangle.branch",
                    color: store.gitDirtyCount > 0 ? .orange : .secondary
                ) { store.selectedSection = .git }
                if !store.pkginfoDrafts.isEmpty || !store.manifestDrafts.isEmpty {
                    StatTile(
                        label: "Unsaved edits",
                        value: "\(store.dirtyDraftCount)",
                        icon: "pencil",
                        color: .yellow,
                        action: nil
                    )
                }
                if settings.enablePromoterTab {
                    let eligible = cachedCandidates.filter { $0.isEligible() }.count
                    StatTile(
                        label: "Eligible now",
                        value: "\(eligible)",
                        icon: "checkmark.seal.fill",
                        color: .green
                    ) { store.selectedSection = .promoter }
                    StatTile(
                        label: "Tracked",
                        value: "\(cachedCandidates.count)",
                        icon: "clock.arrow.circlepath",
                        color: .blue
                    ) { store.selectedSection = .promoter }
                    if todayImportCount > 0 {
                        StatTile(
                            label: "Imports (24h)",
                            value: "\(todayImportCount)",
                            icon: "clock.badge.checkmark",
                            color: .green
                        ) { store.selectedSection = .promoter }
                    }
                    StatTile(
                        label: "Recent imports",
                        value: "\(promoterStore.snapshot.imports.count)",
                        icon: "square.and.arrow.down",
                        color: .indigo
                    ) { store.selectedSection = .promoter }
                }
                if unattendedCount > 0 {
                    StatTile(
                        label: "Unattended",
                        value: "\(unattendedCount)",
                        icon: "wand.and.stars",
                        color: .purple
                    ) { store.selectedSection = .packages }
                }
                if forcedInstallCount > 0 {
                    StatTile(
                        label: "Forced installs",
                        value: "\(forcedInstallCount)",
                        icon: "calendar.badge.exclamationmark",
                        color: .orange
                    ) { store.selectedSection = .packages }
                }
            }
        }
    }

    private func branchSummary(info: GitRepositoryInfo) -> String {
        let name = info.currentBranch ?? "(detached)"
        if info.aheadCount == 0, info.behindCount == 0 { return name }
        return "\(name) +\(info.aheadCount)/-\(info.behindCount)"
    }

    private var uniqueCategories: Set<String> {
        Set(store.snapshot.pkginfos.compactMap {
            $0.pkginfo.category?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        })
    }

    private var uniqueDevelopers: Set<String> {
        Set(store.snapshot.pkginfos.compactMap {
            $0.pkginfo.developer?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        })
    }

    // MARK: Recent commits

    private func recentCommitsCard(info: GitRepositoryInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text("Recent commits")
                    .font(.headline)
                Text("on \(info.currentBranch ?? "(detached)")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 10)
            if recentCommits.isEmpty {
                Text("No commits found in this branch yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recentCommits.prefix(5)) { commit in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(commit.sha.prefix(8)))
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .frame(width: shaColumnWidth, alignment: .leading)
                            Text(commit.subject)
                                .font(.callout)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(relative(commit.date))
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func loadCommits() async {
        guard let info = store.gitInfo else { recentCommits = []; return }
        recentCommits = (try? await store.services.git.log(in: info, max: 8)) ?? []
    }

    private func relative(_ date: Date) -> String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        return "\(days)d"
    }
}

/// Labeled section wrapper for a band of related stat tiles. Icon +
/// title only — no left accent bar — so the page reads as three short
/// stories without extra chrome.
private struct StatSection<Content: View>: View {
    let title: String
    let icon: String
    let accent: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(accent)
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            content()
        }
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let icon: String
    let color: Color
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    body(interactive: true)
                }
                .buttonStyle(.plain)
            } else {
                body(interactive: false)
            }
        }
    }

    private func body(interactive: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.secondary.opacity(interactive ? 0.22 : 0.14), lineWidth: 1)
        )
    }
}

struct DashboardDetailView: View {
    var body: some View {
        ContentUnavailableView(
            "Dashboard",
            systemImage: "rectangle.grid.2x2",
            description: Text("Pick a stat tile or search result to dive in.")
        )
    }
}
