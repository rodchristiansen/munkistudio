import SwiftUI
import Core

/// Form-based manifest editor. Catalogs and the four install lists are
/// each a `ChipField` so admins can add / remove without juggling raw text.
struct ManifestDetailView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        if let record = selectedRecord {
            ManifestEditor(record: record).id(record.id)
        } else {
            ContentUnavailableView(
                "No manifest selected",
                systemImage: "list.bullet.rectangle",
                description: Text("Pick a manifest from the list to view its details.")
            )
        }
    }

    private var selectedRecord: ManifestRecord? {
        guard let selectedItem = store.selectedItemID,
              let url = selectedItem.base as? URL else { return nil }
        return store.snapshot.manifests.first { $0.fileURL == url }
    }
}

private struct ManifestEditor: View {
    @Environment(RepositoryStore.self) private var store
    @State private var draft: Manifest
    @State private var format: RepoFormat
    @State private var fileURL: URL
    @State private var isDirty: Bool = false
    @State private var saveError: String?

    init(record: ManifestRecord) {
        _draft = State(initialValue: record.manifest)
        _format = State(initialValue: record.format)
        _fileURL = State(initialValue: record.fileURL)
    }

    var body: some View {
        Form {
            Section("Identity") {
                LabeledContent("Name", value: draft.manifestName)
                TextField("Display name", text: optional($draft.displayName))
                TextField("User", text: optional($draft.user))
                TextEditor(text: optional($draft.notes)).frame(minHeight: 60)
            }

            Section("Catalogs") {
                ChipField(values: bindArray(\.catalogs), placeholder: "Add catalog")
            }

            Section("Included manifests") {
                ChipField(values: bindArray(\.includedManifests), placeholder: "Add manifest name")
            }

            Section("Managed installs") {
                ChipField(values: bindArray(\.managedInstalls), placeholder: "Add package")
            }

            Section("Managed updates") {
                ChipField(values: bindArray(\.managedUpdates), placeholder: "Add package")
            }

            Section("Managed uninstalls") {
                ChipField(values: bindArray(\.managedUninstalls), placeholder: "Add package")
            }

            Section("Optional installs") {
                ChipField(values: bindArray(\.optionalInstalls), placeholder: "Add package")
            }

            Section("Featured items") {
                ChipField(values: bindArray(\.featuredItems), placeholder: "Add package")
            }

            Section("Conditional items") {
                ConditionalItemsEditor(items: Binding(
                    get: { draft.conditionalItems ?? [] },
                    set: { draft.conditionalItems = $0.isEmpty ? nil : $0 }
                ))
            }

            Section("File") {
                LabeledContent("Path", value: fileURL.path)
                Picker("Format", selection: $format) {
                    ForEach(RepoFormat.allCases, id: \.self) { format in
                        Text(format.preferredExtension.uppercased()).tag(format)
                    }
                }
            }

            if let saveError {
                Section { Text(saveError).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Save") { Task { await save() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty)
            }
        }
        .onChange(of: draft) { isDirty = true }
        .onChange(of: format) { isDirty = true }
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func bindArray(_ keyPath: WritableKeyPath<Manifest, [String]?>) -> Binding<[String]> {
        Binding(
            get: { draft[keyPath: keyPath] ?? [] },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func save() async {
        var url = fileURL
        if url.pathExtension != format.preferredExtension {
            url = url.deletingPathExtension().appendingPathExtension(format.preferredExtension)
        }
        let record = ManifestRecord(manifest: draft, fileURL: url, format: format)
        do {
            try await store.services.manifests.save(record)
            if url != fileURL {
                try? FileManager.default.removeItem(at: fileURL)
                fileURL = url
            }
            store.upsert(record)
            isDirty = false
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}
