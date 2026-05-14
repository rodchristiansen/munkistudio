import SwiftUI
import Core

/// Middle-column list of pkginfo records. The filter field is rendered
/// inline above the list with an explicit `@FocusState` because
/// `.searchable(placement: .toolbar)` doesn't reliably accept focus from
/// the content column of a `NavigationSplitView`.
struct PackagesListView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var search: String = ""
    @State private var grouping: PackageGrouping = .categories
    @State private var sort: PackageSort = .name
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var bindableStore = store
        VStack(spacing: 0) {
            // Mail.app-style scope strip: switch how the list is
            // grouped without leaving the view. Sort sits inline as a
            // popover menu so the strip stays a single line.
            HStack(spacing: 8) {
                Picker("", selection: $grouping) {
                    ForEach(PackageGrouping.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer()
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(PackageSort.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } label: {
                    Label("Sort: \(sort.title)", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            FilterField(text: $search, prompt: "Filter packages", focused: $searchFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            if store.snapshot.pkginfos.isEmpty {
                EmptyPackagesView()
            } else {
                PackageTreeList(records: filtered, grouping: grouping, sort: sort)
            }
        }
        .navigationTitle("Packages (\(store.snapshot.pkginfos.count))")
        .onAppear { searchFocused = false }
    }

    private var filtered: [PkginfoRecord] {
        guard !search.isEmpty else { return store.snapshot.pkginfos }
        let query = search.lowercased()
        return store.snapshot.pkginfos.filter { record in
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
    case types, categories, developers, directories
    var id: String { rawValue }
    var title: String {
        switch self {
        case .types: "Types"
        case .categories: "Categories"
        case .developers: "Developers"
        case .directories: "Directories"
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

