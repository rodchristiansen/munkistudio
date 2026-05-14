import SwiftUI
import Core

/// Full-content search across every pkginfo and manifest file, modeled
/// after VS Code's "Search in Files" sidebar:
///
/// - Reads the on-disk text of each file (plist or YAML alike) and runs
///   a literal, case-insensitive substring scan over every line.
/// - Results group by file. Each match shows its line number plus the
///   line's content with the matched run highlighted.
/// - Clicking a match selects the underlying pkginfo / manifest record
///   so the detail pane opens it for editing.
///
/// The search is intentionally simple — no regex, no whole-word, no
/// case toggle — because the most common admin question is "where does
/// this string appear?" The richer attribute-based query lives in the
/// criteria-search predicate builder (separate task).
struct SearchView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        @Bindable var bindableStore = store
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search the entire repo (Cmd-Shift-F)", text: $bindableStore.searchQuery)
                    .textFieldStyle(.plain)
                if !store.searchQuery.isEmpty {
                    Button {
                        store.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: .rect(cornerRadius: 6))
            .padding(12)

            Divider()

            if store.searchQuery.count < 2 {
                ContentUnavailableView(
                    "Type to search",
                    systemImage: "magnifyingglass",
                    description: Text("Scans every key and value in every pkginfo and manifest file. Minimum two characters.")
                )
            } else {
                let results = SearchScanner.run(query: store.searchQuery, store: store)
                if results.isEmpty {
                    ContentUnavailableView.search(text: store.searchQuery)
                } else {
                    resultsList(results)
                }
            }
        }
        .navigationTitle("Search")
    }

    @ViewBuilder
    private func resultsList(_ results: [SearchScanner.FileResult]) -> some View {
        @Bindable var bindableStore = store
        let totalMatches = results.reduce(0) { $0 + $1.matches.count }
        VStack(alignment: .leading, spacing: 0) {
            Text("\(totalMatches) match\(totalMatches == 1 ? "" : "es") in \(results.count) file\(results.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            List(selection: $bindableStore.selectedItemID) {
                ForEach(results, id: \.fileURL) { file in
                    Section {
                        ForEach(file.matches) { match in
                            HitRow(match: match, query: store.searchQuery)
                                .tag(AnyHashable(file.fileURL))
                                .onTapGesture { selectFile(file) }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: file.kind == .pkginfo ? "shippingbox" : "list.bullet.rectangle")
                                .foregroundStyle(.secondary)
                            Text(file.displayPath)
                                .font(.callout.weight(.semibold))
                            Text("\(file.matches.count)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                        .onTapGesture { selectFile(file) }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func selectFile(_ file: SearchScanner.FileResult) {
        store.selectedItemID = AnyHashable(file.fileURL)
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

    /// Highlight the matched run inline. `AttributedString` ranges are
    /// the most reliable way to drop background color on a substring
    /// inside SwiftUI text — using two `Text(...)` concatenation works
    /// but loses truncation behaviour with long lines.
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

/// Pure scanner — no SwiftUI, easy to test in isolation later. Reads
/// each file once per query; for repos with hundreds of files this is
/// fast enough at human-typing pace. If profiling shows it's a
/// bottleneck we'll switch to a cached line-index keyed on file URL +
/// modification date.
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
        // Most matches first — VS Code orders this way and it surfaces
        // the strongest hits to the top of long result lists.
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

struct SearchDetailView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        if let id = store.selectedItemID,
           let url = id.base as? URL {
            if store.snapshot.pkginfos.contains(where: { $0.fileURL == url }) {
                PackageDetailView().environment(store)
            } else if store.snapshot.manifests.contains(where: { $0.fileURL == url }) {
                ManifestDetailView().environment(store)
            } else {
                Text("Item not found").foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView(
                "No result selected",
                systemImage: "magnifyingglass"
            )
        }
    }
}
