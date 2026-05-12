import SwiftUI
import Core

/// Detail editor for the selected pkginfo. Built as one scrolling `Form`
/// with collapsible sections so the user sees structure but doesn't have
/// to click between tabs.
///
/// Editing mutates a `@State` copy of the record; the Save button writes
/// it back to disk through the package service and patches the snapshot.
struct PackageDetailView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        if let record = selectedRecord {
            PackageEditor(record: record)
                .id(record.id)
        } else {
            ContentUnavailableView(
                "No package selected",
                systemImage: "shippingbox",
                description: Text("Pick a package from the list to view its details.")
            )
        }
    }

    private var selectedRecord: PkginfoRecord? {
        guard let selectedItem = store.selectedItemID,
              let url = selectedItem.base as? URL else { return nil }
        return store.snapshot.pkginfos.first { $0.fileURL == url }
    }
}

private struct PackageEditor: View {
    @Environment(RepositoryStore.self) private var store
    @State private var draft: Pkginfo
    @State private var format: RepoFormat
    @State private var fileURL: URL
    @State private var isDirty: Bool = false
    @State private var saveError: String?

    init(record: PkginfoRecord) {
        _draft = State(initialValue: record.pkginfo)
        _format = State(initialValue: record.format)
        _fileURL = State(initialValue: record.fileURL)
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $draft.name)
                TextField("Display name", text: optional($draft.displayName))
                TextField("Version", text: optional($draft.version))
                TextField("Developer", text: optional($draft.developer))
                TextField("Category", text: optional($draft.category))
            }

            Section("Description") {
                TextEditor(text: optional($draft.description))
                    .frame(minHeight: 80)
            }

            Section("Installer") {
                TextField("Installer item location", text: optional($draft.installerItemLocation))
                TextField("Installer item hash", text: optional($draft.installerItemHash))
                if let size = draft.installerItemSize {
                    LabeledContent("Installer item size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
                Picker("Installer type", selection: typePicker) {
                    ForEach(InstallerType.knownCases, id: \.rawValue) { type in
                        Text(type.rawValue).tag(InstallerType?(type))
                    }
                    if case .unknown(let value) = draft.installerType ?? .pkg {
                        Text(value).tag(draft.installerType)
                    }
                }
            }

            Section("Catalogs") {
                ChipField(values: bindArray(\.catalogs), placeholder: "Add catalog")
            }

            Section("Architectures") {
                ChipField(
                    values: Binding(
                        get: { (draft.supportedArchitectures ?? []).map(\.rawValue) },
                        set: { draft.supportedArchitectures = $0.isEmpty ? nil : $0.map(SupportedArchitecture.init(rawValue:)) }
                    ),
                    placeholder: "arm64 / x86_64"
                )
            }

            Section("Scripts") {
                ScriptEditor(label: "Pre-install", text: optional($draft.preinstallScript))
                ScriptEditor(label: "Post-install", text: optional($draft.postinstallScript))
                ScriptEditor(label: "Pre-uninstall", text: optional($draft.preuninstallScript))
                ScriptEditor(label: "Post-uninstall", text: optional($draft.postuninstallScript))
                ScriptEditor(label: "Install check", text: optional($draft.installcheckScript))
                ScriptEditor(label: "Uninstall check", text: optional($draft.uninstallcheckScript))
            }

            Section("Behavior") {
                Toggle("Unattended install", isOn: optionalBool($draft.unattendedInstall))
                Toggle("Unattended uninstall", isOn: optionalBool($draft.unattendedUninstall))
                Toggle("Auto-remove", isOn: optionalBool($draft.autoremove))
                Toggle("Featured", isOn: optionalBool($draft.featured))
                Picker("Restart action", selection: restartPicker) {
                    Text("Unspecified").tag(RestartAction?.none)
                    ForEach(RestartAction.allCases, id: \.rawValue) { action in
                        Text(action.rawValue).tag(RestartAction?(action))
                    }
                }
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

    private var typePicker: Binding<InstallerType?> {
        Binding(get: { draft.installerType }, set: { draft.installerType = $0 })
    }

    private var restartPicker: Binding<RestartAction?> {
        Binding(get: { draft.restartAction }, set: { draft.restartAction = $0 })
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func optionalBool(_ binding: Binding<Bool?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue ?? false }, set: { binding.wrappedValue = $0 ? true : nil })
    }

    private func bindArray(_ keyPath: WritableKeyPath<Pkginfo, [String]?>) -> Binding<[String]> {
        Binding(
            get: { draft[keyPath: keyPath] ?? [] },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func save() async {
        // Convert format if needed.
        var url = fileURL
        if url.pathExtension != format.preferredExtension {
            url = url.deletingPathExtension().appendingPathExtension(format.preferredExtension)
        }
        let record = PkginfoRecord(pkginfo: draft, fileURL: url, format: format)
        do {
            try await store.services.packages.save(record)
            if url != fileURL {
                // Remove the old-extension file.
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

private extension InstallerType {
    static let knownCases: [InstallerType] = [
        .pkg, .copyFromDmg, .nopkg, .stageOSInstaller,
        .startosinstall, .configurationProfile, .appleUpdateMetadata,
    ]
}
