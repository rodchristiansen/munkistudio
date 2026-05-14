import SwiftUI
import Core

/// Repo-overview home view. Inspired by CimianAdmin's Dashboard tile
/// page — at-a-glance counts, recent commits, and a global search
/// entry point so users start in a hub and dive out from there.
struct DashboardView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var recentCommits: [GitCommit] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchHero
                statsGrid
                if let info = store.gitInfo {
                    recentCommitsCard(info: info)
                }
                quickActionsCard
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Dashboard")
        .task(id: store.gitInfo?.workTreeRoot) { await loadCommits() }
    }

    // MARK: Search hero

    private var searchHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search the entire repository")
                .font(.title2.weight(.semibold))
            Text("Full-content search across every key and value in every pkginfo and manifest file — like Cmd-Shift-F in VS Code.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                store.selectedSection = .search
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("Open global search")
                    Spacer()
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Stats

    private var statsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)]
        return LazyVGrid(columns: columns, spacing: 14) {
            StatTile(
                label: "Packages",
                value: "\(store.snapshot.pkginfos.count)",
                icon: "shippingbox",
                color: .blue
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
                icon: "folder",
                color: .teal,
                action: nil
            )
            StatTile(
                label: "Developers",
                value: "\(uniqueDevelopers.count)",
                icon: "person.2",
                color: .pink,
                action: nil
            )
            StatTile(
                label: "Uncommitted",
                value: "\(store.gitDirtyCount)",
                icon: "circle.fill",
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
                Button("Open Git") { store.selectedSection = .git }
                    .controlSize(.small)
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
                                .frame(width: 70, alignment: .leading)
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

    // MARK: Quick actions

    private var quickActionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick actions").font(.headline)
            HStack(spacing: 10) {
                QuickActionButton(label: "Save session", icon: "tray.and.arrow.down", disabled: store.dirtyDraftCount == 0) {
                    Task { await store.saveSession() }
                }
                if store.gitInfo != nil {
                    QuickActionButton(label: "Git pull", icon: "arrow.down", disabled: store.gitActionInFlight != nil) {
                        Task { await store.runGitPull() }
                    }
                    QuickActionButton(label: "Git push", icon: "arrow.up", disabled: store.gitActionInFlight != nil) {
                        Task { await store.runGitPush() }
                    }
                }
                QuickActionButton(label: "Reload repo", icon: "arrow.clockwise", disabled: false) {
                    Task { await store.reload() }
                }
                Spacer()
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
                .strokeBorder(color.opacity(interactive ? 0.18 : 0.1), lineWidth: 1)
        )
    }
}

private struct QuickActionButton: View {
    let label: String
    let icon: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
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
