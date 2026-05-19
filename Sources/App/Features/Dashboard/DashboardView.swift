import SwiftUI
import Core

/// Repo-overview home view. Inspired by CimianAdmin's Dashboard tile
/// page — at-a-glance counts, recent commits, and a global search
/// entry point so users start in a hub and dive out from there.
struct DashboardView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var recentCommits: [GitCommit] = []
    @ScaledMetric(relativeTo: .caption) private var shaColumnWidth: CGFloat = 70

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statsGrid
                recentlyModifiedRow
                if let info = store.gitInfo {
                    recentCommitsCard(info: info)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Dashboard")
        .task(id: store.gitInfo?.workTreeRoot) { await loadCommits() }
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

    // MARK: Stats

    private var statsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)]
        return LazyVGrid(columns: columns, spacing: 14) {
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
        }
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
