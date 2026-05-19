import SwiftUI
import Core

/// Floating results panel that drops out of the top-right corner of
/// the workspace whenever the toolbar search field has at least two
/// characters and at least one hit. Sized to roughly half the
/// window's width and capped in height; scrolls internally.
struct SearchResultsFloatingPanel: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        GeometryReader { geo in
            let panelWidth = min(900, max(520, geo.size.width * 0.55))
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.searchResults.prefix(40)), id: \.fileURL) { file in
                            fileSection(file)
                        }
                    }
                }
                .frame(maxHeight: min(560, geo.size.height * 0.7))
            }
            .frame(width: panelWidth, alignment: .topLeading)
            // Bright, opaque fill so the panel reads as a distinct
            // surface above the slightly-grey workspace. The shadow
            // does the lift work; the fill only needs to be cleanly
            // brighter than `windowBackgroundColor`.
            .background(
                Color(nsColor: .textBackgroundColor)
                    .clipShape(.rect(cornerRadius: 12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary.opacity(0.7), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.16), radius: 22, x: 0, y: 6)
            .frame(maxWidth: .infinity, alignment: .topTrailing)
        }
        // The GeometryReader fills its parent; constrain so the
        // overlay doesn't claim hit-testing across the whole workspace.
        .frame(maxWidth: .infinity, maxHeight: 640, alignment: .topTrailing)
        .allowsHitTesting(true)
    }

    private var headerRow: some View {
        let total = store.searchResults.reduce(0) { $0 + $1.matches.count }
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text("\(total) match\(total == 1 ? "" : "es") in \(store.searchResults.count) file\(store.searchResults.count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                store.searchQuery = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear search")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func fileSection(_ file: SearchScanner.FileResult) -> some View {
        Button {
            open(file: file)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: file.kind == .pkginfo ? "shippingbox" : "list.bullet.rectangle")
                    .foregroundStyle(file.kind == .pkginfo ? AnyShapeStyle(Color.munkiStudioBrand) : AnyShapeStyle(TintShapeStyle.tint))
                    .imageScale(.small)
                Text(file.displayPath)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(file.matches.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        ForEach(Array(file.matches.prefix(6))) { match in
            Button {
                open(file: file)
            } label: {
                HitRow(match: match, query: store.searchQuery)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        Divider().padding(.leading, 12)
    }

    private func open(file: SearchScanner.FileResult) {
        switch file.kind {
        case .pkginfo:
            if let record = store.snapshot.pkginfos.first(where: { $0.fileURL == file.fileURL }) {
                store.selectedSection = .packages
                store.selectedItemID = AnyHashable(record.id)
                let category = record.pkginfo.category?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Uncategorized"
                store.expandedCategories.insert(category)
            }
        case .manifest:
            if let record = store.snapshot.manifests.first(where: { $0.fileURL == file.fileURL }) {
                store.selectedSection = .manifests
                store.selectedItemID = AnyHashable(record.id)
            }
        }
        store.searchQuery = ""
    }
}

/// Suggestions surfaced under the toolbar's `.searchable` field as the
/// user types. Each row is a single match line — VS Code-style:
/// file path + line number + the matched line with the query
/// highlighted. Tapping a row navigates straight to that record's
/// editor; no Return required.
struct SearchSuggestionRows: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let query = store.searchQuery
        if query.count >= 2 {
            // Render cached results from the store. The actual scan
            // runs in `.task(id: searchQuery)` on the workspace so
            // hovering over a row doesn't trigger a re-scan.
            let results = store.searchResults.prefix(20)
            ForEach(Array(results), id: \.fileURL) { file in
                ForEach(Array(file.matches.prefix(5))) { match in
                    Button {
                        open(file: file)
                    } label: {
                        SuggestionRow(file: file, match: match, query: query)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func open(file: SearchScanner.FileResult) {
        switch file.kind {
        case .pkginfo:
            if let record = store.snapshot.pkginfos.first(where: { $0.fileURL == file.fileURL }) {
                store.selectedSection = .packages
                store.selectedItemID = AnyHashable(record.id)
                let category = record.pkginfo.category?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Uncategorized"
                store.expandedCategories.insert(category)
            }
        case .manifest:
            if let record = store.snapshot.manifests.first(where: { $0.fileURL == file.fileURL }) {
                store.selectedSection = .manifests
                store.selectedItemID = AnyHashable(record.id)
            }
        }
        store.searchQuery = ""
    }
}

private struct SuggestionRow: View {
    let file: SearchScanner.FileResult
    let match: SearchScanner.Match
    let query: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: file.kind == .pkginfo ? "shippingbox" : "list.bullet.rectangle")
                .foregroundStyle(file.kind == .pkginfo ? AnyShapeStyle(Color.munkiStudioBrand) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(file.displayPath)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(":\(match.lineNumber)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                highlightedSnippet
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        // Forces the suggestion dropdown to size up to ~50% of a
        // typical window. `.searchSuggestions` lays out children at
        // their intrinsic width, so a wide minimum on each row makes
        // the whole dropdown grow leftward from the search field.
        .frame(minWidth: 700, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    private var highlightedSnippet: Text {
        var attr = AttributedString(match.line.trimmingCharacters(in: .whitespaces))
        let lower = String(attr.characters).lowercased()
        let needle = query.lowercased()
        var start = lower.startIndex
        while let range = lower.range(of: needle, range: start..<lower.endIndex) {
            if let attrRange = Range(range, in: attr) {
                attr[attrRange].backgroundColor = .yellow.opacity(0.35)
                attr[attrRange].font = .system(.caption, design: .monospaced).weight(.semibold)
            }
            start = range.upperBound
        }
        return Text(attr)
    }
}

/// Legacy custom toolbar search field. Kept compiling so any
/// lingering reference still resolves, but the workspace now uses
/// `.searchable` directly. Safe to delete once no view references it.
struct ToolbarSearchField: View {
    @Environment(RepositoryStore.self) private var store
    @State private var popoverShown = false
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var bindableStore = store
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.body)
            TextField("Search", text: $bindableStore.searchQuery)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($focused)
                .frame(minWidth: 220, idealWidth: 320, maxWidth: 420)
                .onChange(of: store.searchQuery) { _, query in
                    popoverShown = query.count >= 2
                }
                .onSubmit {
                    popoverShown = store.searchQuery.count >= 2
                }
            if !store.searchQuery.isEmpty {
                Button {
                    store.searchQuery = ""
                    popoverShown = false
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(.quaternary.opacity(0.6))
        )
        .overlay(
            Capsule()
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .popover(isPresented: $popoverShown, arrowEdge: .top) {
            SearchResultsPanel { popoverShown = false }
                .frame(width: 680, height: 520)
        }
    }
}

/// Full-pane wrapper used when the workspace's `.search` section is
/// active. Just renders the rich snippet panel without a dismiss
/// button — there's nothing to dismiss when the panel is the section.
struct SearchView: View {
    var body: some View {
        SearchResultsPanel(dismiss: {})
    }
}

/// Result panel surfaced inside the toolbar search popover. Re-uses
/// ``SearchScanner`` and routes selection back into the workspace's
/// section / item bindings.
struct SearchResultsPanel: View {
    @Environment(RepositoryStore.self) private var store
    let dismiss: () -> Void

    var body: some View {
        let results = SearchScanner.run(query: store.searchQuery, store: store)
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                ContentUnavailableView.search(text: store.searchQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let totalMatches = results.reduce(0) { $0 + $1.matches.count }
                HStack {
                    Text("\(totalMatches) match\(totalMatches == 1 ? "" : "es") in \(results.count) file\(results.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Close") { dismiss() }
                        .controlSize(.small)
                        .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                List {
                    ForEach(results, id: \.fileURL) { file in
                        Section {
                            ForEach(file.matches) { match in
                                Button {
                                    open(file: file)
                                } label: {
                                    HitRow(match: match, query: store.searchQuery)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Button {
                                open(file: file)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: file.kind == .pkginfo ? "shippingbox" : "list.bullet.rectangle")
                                        .foregroundStyle(file.kind == .pkginfo ? AnyShapeStyle(Color.munkiStudioBrand) : AnyShapeStyle(TintShapeStyle.tint))
                                    Text(file.displayPath)
                                        .font(.callout.weight(.semibold))
                                    Text("\(file.matches.count)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func open(file: SearchScanner.FileResult) {
        switch file.kind {
        case .pkginfo:
            if let record = store.snapshot.pkginfos.first(where: { $0.fileURL == file.fileURL }) {
                store.selectedSection = .packages
                store.selectedItemID = AnyHashable(record.id)
                let category = record.pkginfo.category?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Uncategorized"
                store.expandedCategories.insert(category)
            }
        case .manifest:
            if let record = store.snapshot.manifests.first(where: { $0.fileURL == file.fileURL }) {
                store.selectedSection = .manifests
                store.selectedItemID = AnyHashable(record.id)
            }
        }
        dismiss()
    }
}

private struct HitRow: View {
    let match: SearchScanner.Match
    let query: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(match.lineNumber)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 36, alignment: .trailing)
            highlightedText
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private var highlightedText: Text {
        var attr = AttributedString(match.line)
        let lower = match.line.lowercased()
        let lowerQuery = query.lowercased()
        var searchStart = lower.startIndex
        while let range = lower.range(of: lowerQuery, range: searchStart..<lower.endIndex) {
            if let attrRange = Range(range, in: attr) {
                attr[attrRange].backgroundColor = .yellow.opacity(0.35)
                attr[attrRange].font = .system(.callout, design: .monospaced).weight(.semibold)
            }
            searchStart = range.upperBound
        }
        return Text(attr)
    }
}

/// Pure scanner — no SwiftUI, easy to test in isolation later.
@MainActor
enum SearchScanner {
    struct FileResult: Sendable {
        enum Kind: Sendable { case pkginfo, manifest }
        let fileURL: URL
        let displayPath: String
        let kind: Kind
        let matches: [Match]
    }

    struct Match: Identifiable, Sendable {
        let id: Int
        let lineNumber: Int
        let line: String
    }

    static func run(query: String, store: RepositoryStore) -> [FileResult] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }

        var results: [FileResult] = []
        let pkgRoot = store.repository?.pkgsinfoURL.path ?? ""
        let manifestRoot = store.repository?.manifestsURL.path ?? ""

        for record in store.snapshot.pkginfos {
            if let result = scan(url: record.fileURL, kind: .pkginfo, root: pkgRoot, needle: needle) {
                results.append(result)
            }
        }
        for record in store.snapshot.manifests {
            if let result = scan(url: record.fileURL, kind: .manifest, root: manifestRoot, needle: needle) {
                results.append(result)
            }
        }
        return results.sorted { $0.matches.count > $1.matches.count }
    }

    private static func scan(url: URL, kind: FileResult.Kind, root: String, needle: String) -> FileResult? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var matches: [Match] = []
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            if line.lowercased().contains(needle) {
                matches.append(Match(id: lineNumber, lineNumber: lineNumber, line: String(line)))
            }
        }
        guard !matches.isEmpty else { return nil }
        let display: String = {
            let prefix = root + "/"
            return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
        }()
        return FileResult(fileURL: url, displayPath: display, kind: kind, matches: matches)
    }
}
