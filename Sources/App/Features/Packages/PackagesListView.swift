import SwiftUI
import Core

/// Middle-column list of pkginfo records. The filter field is rendered
/// inline above the list with an explicit `@FocusState` because
/// `.searchable(placement: .toolbar)` doesn't reliably accept focus from
/// the content column of a `NavigationSplitView`.
struct PackagesListView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var search: String = ""
    @State private var criteriaGroup = PackageCriteriaGroup()
    @State private var filterPopoverShown = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var bindableStore = store
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $bindableStore.packagesGrouping) {
                    ForEach(PackageGrouping.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer()
                filterButton
                SortMenu(sort: $bindableStore.packagesSort)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            FilterField(text: $search, prompt: "Filter packages", focused: $searchFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            if store.snapshot.pkginfos.isEmpty {
                EmptyPackagesView()
            } else {
                PackageTreeList(
                    records: filtered,
                    grouping: store.packagesGrouping,
                    sort: store.packagesSort,
                    forceExpandAll: !search.isEmpty || !criteriaGroup.criteria.isEmpty
                )
            }
        }
        .navigationTitle("Packages")
        .navigationSubtitle(packagesSubtitle)
        .onAppear { searchFocused = false }
        .alert("Couldn't Complete Action", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.packageActionError ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.packageActionError != nil },
            set: { if !$0 { store.packageActionError = nil } }
        )
    }

    /// Pkginfo count, shown as the column's title-bar subtitle.
    private var packagesSubtitle: String {
        let count = store.snapshot.pkginfos.count
        return "\(count) pkginfo file\(count == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var filterButton: some View {
        FilterButton(
            isActive: !criteriaGroup.criteria.isEmpty,
            count: criteriaGroup.criteria.count,
            onClear: { criteriaGroup.criteria.removeAll() }
        ) {
            if criteriaGroup.criteria.isEmpty {
                let attr: PackageAttribute = .name
                criteriaGroup.criteria.append(
                    PackageCriterion(attribute: attr, op: attr.allowedOperators.first ?? .contains, value: "")
                )
            }
            filterPopoverShown = true
        }
        .popover(isPresented: $filterPopoverShown, arrowEdge: .top) {
            PackageCriteriaEditor(group: $criteriaGroup)
                .frame(minWidth: 520, idealWidth: 580)
                .padding(12)
        }
    }

    private var filtered: [PkginfoRecord] {
        var base = store.snapshot.pkginfos
        if !criteriaGroup.criteria.isEmpty {
            base = base.filter { record in
                criteriaGroup.matches(
                    PackageRecordContext(pkginfo: record.pkginfo, filename: record.fileURL.lastPathComponent)
                )
            }
        }
        guard !search.isEmpty else { return base }
        let query = search.lowercased()
        return base.filter { record in
            record.pkginfo.name.lowercased().contains(query)
                || (record.pkginfo.displayName?.lowercased().contains(query) ?? false)
                || (record.pkginfo.category?.lowercased().contains(query) ?? false)
                || (record.pkginfo.developer?.lowercased().contains(query) ?? false)
        }
    }
}

/// Empty-state shown when the repo has no pkginfo files. Surfaces the
/// directory we scanned and any per-file load errors so misnamed repo
/// layouts ("pkginfo/" instead of "pkgsinfo/") are obvious.
struct EmptyPackagesView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ContentUnavailableView {
                Label("No packages found", systemImage: "shippingbox")
            } description: {
                if let repo = store.repository {
                    Text("Scanned \(repo.pkgsinfoURL.path) — found nothing that parses as a pkginfo.")
                } else {
                    Text("Open a Munki repository to see packages here.")
                }
            }

            if !store.snapshot.loadErrors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(store.snapshot.loadErrors.count) file(s) couldn't be parsed")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    ScrollView {
                        ForEach(store.snapshot.loadErrors) { error in
                            VStack(alignment: .leading) {
                                Text(error.fileURL.lastPathComponent).font(.callout.bold())
                                Text(error.message).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.regularMaterial, in: .rect(cornerRadius: 6))
                        }
                    }
                    .frame(maxHeight: 200)
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 16)
    }
}

enum PackageGrouping: String, CaseIterable, Identifiable, Hashable {
    case categories, types, developers, directories
    var id: String { rawValue }
    var title: String {
        switch self {
        case .categories: "Categories"
        case .types: "Types"
        case .developers: "Developers"
        case .directories: "Directories"
        }
    }

    /// SF Symbol for folder rows when grouping by this scope.
    var folderIcon: String {
        switch self {
        case .categories: "square.grid.2x2"
        case .types: "circle.grid.cross"
        case .developers: "person"
        case .directories: "folder"
        }
    }
}

enum PackageSort: String, CaseIterable, Identifiable, Hashable {
    case name, recentlyModified
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "Name"
        case .recentlyModified: "Recently Modified"
        }
    }
}

/// Compact sort menu used in both the Packages and Manifests list
/// headers. Flat single-click choices (no nested submenu) — selected
/// option is marked with a checkmark inline. Icon-only trigger so it
/// stays out of the way; hover shows the current sort.
struct SortMenu: View {
    @Binding var sort: PackageSort

    var body: some View {
        Menu {
            ForEach(PackageSort.allCases) { mode in
                Button {
                    sort = mode
                } label: {
                    if sort == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
                .fontWeight(.semibold)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort: \(sort.title)")
    }
}

/// Shared icon-only filter button with an inline clear-X that appears
/// to its left when criteria are active. Used by both Packages and
/// Manifests list panes so they behave identically.
struct FilterButton: View {
    let isActive: Bool
    let count: Int
    let onClear: () -> Void
    let onOpen: () -> Void

    init(isActive: Bool, count: Int, onClear: @escaping () -> Void, _ onOpen: @escaping () -> Void) {
        self.isActive = isActive
        self.count = count
        self.onClear = onClear
        self.onOpen = onOpen
    }

    var body: some View {
        HStack(spacing: 4) {
            if isActive {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.yellow)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
            Button(action: onOpen) {
                Label(
                    "Filter",
                    systemImage: isActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
                .labelStyle(.iconOnly)
                .fontWeight(.semibold)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(isActive ? "Filter (\(count) rule\(count == 1 ? "" : "s"))" : "Filter")
        }
    }
}

/// Single-line filter input. Pulled out into its own view because the
/// same widget shows up in three list panes — and using a plain
/// `TextField` with `@FocusState` reliably accepts clicks inside a
/// `NavigationSplitView` column where `.searchable` does not.
struct FilterField: View {
    @Binding var text: String
    let prompt: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
            if !text.isEmpty {
                Button {
                    text = ""
                    focused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onTapGesture { focused.wrappedValue = true }
    }
}

