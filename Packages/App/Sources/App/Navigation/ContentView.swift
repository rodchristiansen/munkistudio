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
        .navigationTitle(store.repository?.displayName ?? "MunkiAdmin")
    }
}

/// Full three-column workspace. Sidebar destinations swap out the middle
/// (content list) and right (detail) columns.
struct RepositoryWorkspace: View {
    @Environment(RepositoryStore.self) private var store
    @State private var makecatalogsPresented: Bool = false

    var body: some View {
        @Bindable var bindableStore = store
        NavigationSplitView {
            SidebarView(selection: $bindableStore.selectedSection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            ContentColumn(section: store.selectedSection)
                .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 600)
        } detail: {
            DetailColumn(section: store.selectedSection)
        }
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                if let info = store.gitInfo {
                    RepositoryChip(info: info)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
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
        case .packages: PackageDetailView()
        case .manifests: ManifestDetailView()
        case .catalogs: CatalogDetailView()
        case .git: GitDetailView()
        }
    }
}

/// Top-bar chip showing the current branch + ahead/behind. Stays out of
/// the way when no git repo is detected.
struct RepositoryChip: View {
    let info: GitRepositoryInfo

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            Text(info.currentBranch ?? "(detached)")
                .font(.callout.monospaced())
            if info.aheadCount > 0 {
                Label("\(info.aheadCount)", systemImage: "arrow.up").labelStyle(.titleAndIcon)
            }
            if info.behindCount > 0 {
                Label("\(info.behindCount)", systemImage: "arrow.down").labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: .capsule)
    }
}
