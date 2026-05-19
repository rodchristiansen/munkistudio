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
    let record: ManifestRecord

    private var draft: Binding<Manifest> {
        Binding(
            get: { store.draftManifest(for: record) },
            set: { store.setDraftManifest($0, for: record) }
        )
    }

    private var format: Binding<RepoFormat> {
        Binding(
            get: { store.draftFormat(for: record.fileURL, default: record.format) },
            set: { store.setDraftFormat($0, for: record.fileURL, savedFormat: record.format) }
        )
    }

    private var fileURL: URL { record.fileURL }
    private var createdAt: Date? { record.createdAt }
    private var modifiedAt: Date? { record.modifiedAt }

    var body: some View {
        // Card-based layout matching PackageDetailView. SwiftUI's
        // grouped `Form` pushed every value to the trailing edge,
        // leaving a huge gap between "Name" and "Bootstrap" — the
        // hand-rolled LabelledField keeps the value next to the label.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                identityCard
                catalogsCard
                includedManifestsCard
                itemListCard("Managed installs", kind: .managedInstalls)
                itemListCard("Managed updates", kind: .managedUpdates)
                itemListCard("Managed uninstalls", kind: .managedUninstalls)
                itemListCard("Optional installs", kind: .optionalInstalls)
                itemListCard("Featured items", kind: .featuredItems)
                itemListCard("Default installs", kind: .defaultInstalls)
                conditionsCard
                fileCard
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
    }

    // MARK: Cards

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("Identity") {
                RecordActionMenu(record: .manifest(record))
            }
            VStack(alignment: .leading, spacing: 10) {
                LabelledField("Name") {
                    Text(draft.wrappedValue.manifestName)
                        .font(.system(.callout, design: .monospaced))
                }
                LabelledField("Display name") {
                    TextField("", text: optional(draft.displayName))
                        .textFieldStyle(.roundedBorder)
                }
                LabelledField("User") {
                    TextField("", text: optional(draft.user))
                        .textFieldStyle(.roundedBorder)
                }
                LabelledField("Notes", alignment: .top) {
                    TextEditor(text: optional(draft.notes))
                        .frame(minHeight: 70)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                }
            }
            .cardStyle()
        }
    }

    private var catalogsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("Catalogs")
            CatalogChecklist(selected: bindArray(\.catalogs))
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
        }
    }

    private var includedManifestsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("Included manifests")
            IncludedManifestsEditor(
                values: bindArray(\.includedManifests),
                availableNames: availableManifestNames
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    private func itemListCard(_ title: String, kind: ManifestItemListEditor.Kind) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader(title)
            ManifestItemListEditor(kind: kind, manifest: draft, availableNames: availablePackageNames)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
        }
    }

    private var conditionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("Conditions")
            ConditionalItemsEditor(items: Binding(
                get: { draft.wrappedValue.conditionalItems ?? [] },
                set: { draft.wrappedValue.conditionalItems = $0.isEmpty ? nil : $0 }
            ))
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("File")
            VStack(alignment: .leading, spacing: 10) {
                LabelledField("Path") {
                    Text(fileURL.path)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                LabelledField("Format") {
                    Picker("", selection: format) {
                        ForEach(RepoFormat.allCases, id: \.self) { format in
                            Text(format.preferredExtension.uppercased()).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if let createdAt {
                    LabelledField("Created") {
                        Text(Self.timestampFormatter.string(from: createdAt))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let modifiedAt {
                    LabelledField("Modified") {
                        Text(Self.timestampFormatter.string(from: modifiedAt))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .cardStyle()
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Sorted, de-duplicated package names from the open repo. Used to
    /// populate the install-list add menus so users can't enter package
    /// names that don't exist in this repo.
    private var availablePackageNames: [String] {
        Array(Set(store.snapshot.pkginfos.map(\.pkginfo.name))).sorted()
    }

    /// Sorted manifest paths (the slash-delimited tree path used in
    /// `included_manifests`). Excludes the manifest currently being
    /// edited so it can't include itself.
    private var availableManifestNames: [String] {
        let selfName = draft.wrappedValue.manifestName
        return store.snapshot.manifests
            .map(\.manifest.manifestName)
            .filter { $0 != selfName }
            .sorted()
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func bindArray(_ keyPath: WritableKeyPath<Manifest, [String]?>) -> Binding<[String]> {
        Binding(
            get: { draft.wrappedValue[keyPath: keyPath] ?? [] },
            set: { draft.wrappedValue[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}
