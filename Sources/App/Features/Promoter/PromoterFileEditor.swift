import SwiftUI
import AppKit
import Yams

/// Plain-text editor for a single configuration file (`promoter.yml`,
/// `recipe_list.yaml`, `recipe_list.plist`, …). Loads the file into a
/// draft, lets the user edit and revert, and persists writes atomically.
///
/// Format detection is by file extension only — every supported format
/// round-trips as raw text, so the user is in charge of validity. A
/// shallow sanity check (UTF-8 parse + plist or YAML load) runs after
/// each edit and surfaces the first error inline; it never blocks a
/// save, because the user might be mid-edit.
struct PromoterFileEditor: View {
    let title: String
    let fileURL: URL
    let supportedExtensions: [String]
    /// Optional hook fired after a successful save — used by the Rules
    /// editor to trigger a Promoter snapshot refresh once `promoter.yml`
    /// changes land on disk.
    var onSaved: (() -> Void)? = nil

    @State private var loaded: String = ""
    @State private var draft: String = ""
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var lintMessage: String?
    @State private var status: Status = .loading

    enum Status: Equatable {
        case loading, ready, missing, unsupported(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: fileURL.path) { await load() }
        .alert("Save Failed", isPresented: saveErrorPresented) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(fileURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            if let lintMessage {
                Label(lintMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } label: { Label("Reveal", systemImage: "magnifyingglass") }
            .disabled(status != .ready)
            .help("Reveal in Finder")
            Button("Revert") { draft = loaded }
                .disabled(!isDirty)
            Button("Save") { Task { await save() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty || status != .ready)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch status {
        case .loading:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            ContentUnavailableView(
                "File not found",
                systemImage: "doc.text.magnifyingglass",
                description: Text("\(fileURL.lastPathComponent) doesn't exist at \(fileURL.deletingLastPathComponent().path).")
            )
        case .unsupported(let ext):
            ContentUnavailableView(
                "Unsupported format",
                systemImage: "questionmark.diamond",
                description: Text("Expected one of \(supportedExtensions.joined(separator: ", ")), got .\(ext).")
            )
        case .ready:
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .padding(10)
                .onChange(of: draft) { _, newValue in
                    lintMessage = Self.shallowLint(newValue, ext: fileURL.pathExtension.lowercased())
                }
        }
    }

    // MARK: Actions

    private func load() async {
        status = .loading
        loadError = nil
        let ext = fileURL.pathExtension.lowercased()
        if !supportedExtensions.contains(ext) && FileManager.default.fileExists(atPath: fileURL.path) {
            status = .unsupported(ext)
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            status = .missing
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let text = String(decoding: data, as: UTF8.self)
            loaded = text
            draft = text
            lintMessage = Self.shallowLint(text, ext: ext)
            status = .ready
        } catch {
            loadError = error.localizedDescription
            status = .missing
        }
    }

    private func save() async {
        do {
            let data = Data(draft.utf8)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
            loaded = draft
            onSaved?()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private var isDirty: Bool { draft != loaded }

    private var saveErrorPresented: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    // MARK: Lint

    /// Quick parse check by extension. Returns `nil` when the text
    /// parses cleanly, or a short message when it doesn't. Never blocks
    /// a save — this is a hint, not a gate.
    static func shallowLint(_ text: String, ext: String) -> String? {
        guard !text.isEmpty else { return nil }
        switch ext {
        case "yaml", "yml":
            do {
                _ = try Yams.load(yaml: text)
                return nil
            } catch {
                return "YAML parse: \(error.localizedDescription)"
            }
        case "plist":
            guard let data = text.data(using: .utf8) else { return "Not valid UTF-8" }
            do {
                _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                return nil
            } catch {
                return "Plist parse: \(error.localizedDescription)"
            }
        default:
            return nil
        }
    }
}
