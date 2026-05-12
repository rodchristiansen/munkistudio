import SwiftUI
import Core

/// Two-column pkginfo editor.
///
/// Layout (top → bottom):
/// 1. Identity ║ Installer
/// 2. Catalogs ║ Architectures
/// 3. Description (full width)
/// 4. Scripts (full width, side-by-side pre/post pairs)
/// 5. Behavior ║ File
///
/// Sections always show their content — no disclosure groups. Scripts
/// take over the full width because they're the part users edit most.
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                twoColumn {
                    identitySection
                } right: {
                    installerSection
                }
                twoColumn {
                    catalogsSection
                } right: {
                    behaviorSection
                }
                descriptionSection
                scriptsSection
                twoColumn {
                    architecturesSection
                } right: {
                    fileSection
                }

                if let saveError {
                    Text(saveError).foregroundStyle(.red)
                }
            }
            .padding(16)
        }
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

    // MARK: Sections

    private var identitySection: some View {
        Card(title: "Identity") {
            LabelledField("Name") { TextField("", text: $draft.name) }
            LabelledField("Display name") { TextField("", text: optional($draft.displayName)) }
            LabelledField("Version") { TextField("", text: optional($draft.version)) }
            LabelledField("Developer") { TextField("", text: optional($draft.developer)) }
            LabelledField("Category") { TextField("", text: optional($draft.category)) }
        }
    }

    private var installerSection: some View {
        Card(title: "Installer") {
            LabelledField("Location") { TextField("", text: optional($draft.installerItemLocation)) }
            LabelledField("Hash") {
                TextField("", text: optional($draft.installerItemHash))
                    .font(.system(.callout, design: .monospaced))
            }
            if let size = draft.installerItemSize {
                LabelledField("Size") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            }
            LabelledField("Type") {
                Picker("", selection: typeBinding) {
                    ForEach(InstallerType.knownCases, id: \.rawValue) { type in
                        Text(type.rawValue).tag(InstallerType?(type))
                    }
                    if case .unknown(let value) = draft.installerType ?? .pkg {
                        Text(value).tag(draft.installerType)
                    }
                    Text("Unspecified").tag(InstallerType?.none)
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private var catalogsSection: some View {
        Card(title: "Catalogs") {
            CatalogChecklist(selected: bindArray(\.catalogs))
        }
    }

    private var architecturesSection: some View {
        Card(title: "Architectures") {
            ArchitecturePicker(selected: $draft.supportedArchitectures)
        }
    }

    private var descriptionSection: some View {
        Card(title: "Description") {
            TextEditor(text: optional($draft.description))
                .frame(minHeight: 80, maxHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.regularMaterial.opacity(0.5), in: .rect(cornerRadius: 6))
        }
    }

    private var scriptsSection: some View {
        Card(title: "Scripts") {
            VStack(spacing: 12) {
                ScriptEditor(label: "Install check", text: optional($draft.installcheckScript))
                HStack(alignment: .top, spacing: 12) {
                    ScriptEditor(label: "Pre-install", text: optional($draft.preinstallScript))
                        .frame(maxWidth: .infinity)
                    ScriptEditor(label: "Post-install", text: optional($draft.postinstallScript))
                        .frame(maxWidth: .infinity)
                }
                ScriptEditor(label: "Uninstall check", text: optional($draft.uninstallcheckScript))
                HStack(alignment: .top, spacing: 12) {
                    ScriptEditor(label: "Pre-uninstall", text: optional($draft.preuninstallScript))
                        .frame(maxWidth: .infinity)
                    ScriptEditor(label: "Post-uninstall", text: optional($draft.postuninstallScript))
                        .frame(maxWidth: .infinity)
                }
                ScriptEditor(label: "Uninstall script", text: optional($draft.uninstallScript))
            }
        }
    }

    private var behaviorSection: some View {
        Card(title: "Behavior") {
            Toggle("Unattended install", isOn: optionalBool($draft.unattendedInstall))
            Toggle("Unattended uninstall", isOn: optionalBool($draft.unattendedUninstall))
            Toggle("Auto-remove", isOn: optionalBool($draft.autoremove))
            Toggle("Featured", isOn: optionalBool($draft.featured))
            Toggle("Uninstallable", isOn: optionalBool($draft.uninstallable))
            LabelledField("Restart action") {
                Picker("", selection: restartBinding) {
                    Text("Unspecified").tag(RestartAction?.none)
                    ForEach(RestartAction.allCases, id: \.rawValue) { action in
                        Text(action.rawValue).tag(RestartAction?(action))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            LabelledField("Min macOS") { TextField("", text: optional($draft.minimumOSVersion)) }
            LabelledField("Max macOS") { TextField("", text: optional($draft.maximumOSVersion)) }
        }
    }

    private var fileSection: some View {
        Card(title: "File") {
            LabelledField("Path") {
                Text(fileURL.path)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            LabelledField("Format") {
                Picker("", selection: $format) {
                    ForEach(RepoFormat.allCases, id: \.self) { format in
                        Text(format.preferredExtension.uppercased()).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: Layout helpers

    /// Two equal columns that collapse to a single column when the view
    /// is narrower than a threshold (so it stays usable on a half-width
    /// detail pane).
    @ViewBuilder
    private func twoColumn<L: View, R: View>(
        @ViewBuilder _ left: () -> L,
        @ViewBuilder right: () -> R
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                left().frame(maxWidth: .infinity, alignment: .topLeading)
                right().frame(maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 16) {
                left()
                right()
            }
        }
    }

    // MARK: Bindings

    private var typeBinding: Binding<InstallerType?> {
        Binding(get: { draft.installerType }, set: { draft.installerType = $0 })
    }

    private var restartBinding: Binding<RestartAction?> {
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

    // MARK: Save

    private func save() async {
        var url = fileURL
        if url.pathExtension != format.preferredExtension {
            url = url.deletingPathExtension().appendingPathExtension(format.preferredExtension)
        }
        let record = PkginfoRecord(pkginfo: draft, fileURL: url, format: format)
        do {
            try await store.services.packages.save(record)
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

// MARK: Reusable views

/// Section card with a header. We avoid SwiftUI's `Form` here because
/// we want full control over the two-column layout and we don't want
/// the implicit insets `Form` adds.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.regularMaterial.opacity(0.5), in: .rect(cornerRadius: 8))
        }
    }
}

/// `LabeledContent`-shaped row with a left-aligned label.
struct LabelledField<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension InstallerType {
    static let knownCases: [InstallerType] = [
        .pkg, .copyFromDmg, .nopkg, .stageOSInstaller,
        .startosinstall, .configurationProfile, .appleUpdateMetadata,
    ]
}
