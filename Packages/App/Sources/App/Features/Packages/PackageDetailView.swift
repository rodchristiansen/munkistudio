import SwiftUI
import AppKit
import Core

/// Tabbed pkginfo editor with eight panels:
/// Basic Info / Contents / Requirements / Installation / Uninstall /
/// Scripts / Alerts / Advanced.
///
/// Each tab is a `Form` so we get free LabeledContent alignment and
/// consistent macOS chrome. The selected tab survives across selection
/// changes (kept in store state) so the user lands back on the tab they
/// were last using.
struct PackageDetailView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        if let record = selectedRecord {
            PackageEditor(record: record).id(record.id)
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
    let record: PkginfoRecord
    @State private var activeTab: EditorTab = .basicInfo

    private var draftBinding: Binding<Pkginfo> {
        Binding(
            get: { store.draftPkginfo(for: record) },
            set: { store.setDraftPkginfo($0, for: record) }
        )
    }

    private var formatBinding: Binding<RepoFormat> {
        Binding(
            get: { store.draftFormat(for: record.fileURL, default: record.format) },
            set: { store.setDraftFormat($0, for: record.fileURL, savedFormat: record.format) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            ScrollView {
                Group {
                    switch activeTab {
                    case .basicInfo: BasicInfoTab(draft: draftBinding, format: formatBinding, fileURL: record.fileURL, createdAt: record.createdAt, modifiedAt: record.modifiedAt)
                    case .contents: ContentsTab(draft: draftBinding)
                    case .requirements: RequirementsTab(draft: draftBinding)
                    case .installation: InstallationTab(draft: draftBinding)
                    case .uninstall: UninstallTab(draft: draftBinding)
                    case .scripts: ScriptsTab(draft: draftBinding)
                    case .alerts: AlertsTab(draft: draftBinding)
                    case .advanced: AdvancedTab(draft: draftBinding)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(16)
            }
            // `windowBackgroundColor` is the standard macOS panel
            // backdrop — sits one step below the cards' brighter
            // `controlBackgroundColor` fill so the cards read as
            // floating. `underPageBackgroundColor` was a heavier grey
            // that buried the cards.
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(EditorTab.allCases) { tab in
                Button {
                    activeTab = tab
                } label: {
                    Text(tab.title)
                        .font(.callout.weight(activeTab == tab ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(activeTab == tab ? Color.accentColor : Color.secondary)
                        .background(
                            activeTab == tab
                                ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                                : AnyShapeStyle(Color.clear)
                        )
                        .clipShape(.capsule)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 0.5)
        }
    }

}

private enum EditorTab: String, CaseIterable, Identifiable {
    case basicInfo, contents, requirements, installation
    case uninstall, scripts, alerts, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basicInfo: "Basic Info"
        case .contents: "Contents"
        case .requirements: "Requirements"
        case .installation: "Installation"
        case .uninstall: "Uninstall"
        case .scripts: "Scripts"
        case .alerts: "Alerts"
        case .advanced: "Advanced"
        }
    }
}

// MARK: Basic Info

private struct BasicInfoTab: View {
    @Binding var draft: Pkginfo
    @Binding var format: RepoFormat
    let fileURL: URL
    let createdAt: Date?
    let modifiedAt: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                identityCard
                catalogsCard
                behaviorCard
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 16) {
                installerCard
                descriptionCard
                fileCard
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("Identity")
            VStack(alignment: .leading, spacing: 10) {
                LabelledField("Name") {
                    TextField("", text: $draft.name).textFieldStyle(.roundedBorder)
                }
                LabelledField("Display name") {
                    TextField("", text: Bindings.optional($draft.displayName)).textFieldStyle(.roundedBorder)
                }
                LabelledField("Version") {
                    TextField("", text: Bindings.optional($draft.version)).textFieldStyle(.roundedBorder)
                }
                LabelledField("Icon name", alignment: .top) {
                    IconNameField(iconName: $draft.iconName, packageName: draft.name)
                }
                LabelledField("Category") {
                    TextField("", text: Bindings.optional($draft.category)).textFieldStyle(.roundedBorder)
                }
                LabelledField("Developer") {
                    TextField("", text: Bindings.optional($draft.developer)).textFieldStyle(.roundedBorder)
                }
            }
            .cardStyle()
        }
    }

    private var catalogsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("Catalogs")
            CatalogChecklist(selected: Bindings.bindArray($draft.catalogs))
                .cardStyle()
        }
    }

    private var behaviorCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("Behavior")
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Autoremove", isOn: Bindings.optionalBool($draft.autoremove))
                Toggle("Uninstallable", isOn: Bindings.optionalBool($draft.uninstallable))
                Toggle("Unattended install", isOn: Bindings.optionalBool($draft.unattendedInstall))
                Toggle("Unattended uninstall", isOn: Bindings.optionalBool($draft.unattendedUninstall))
                Toggle("Featured", isOn: Bindings.optionalBool($draft.featured))
                Toggle("On demand", isOn: Bindings.optionalBool($draft.onDemand))
            }
            .cardStyle()
        }
    }

    private var installerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("Installer")
            VStack(alignment: .leading, spacing: 10) {
                LabelledField("Type") {
                    Picker("", selection: typeBinding) {
                        Text("Unspecified").tag(InstallerType?.none)
                        ForEach(InstallerType.knownCases, id: \.rawValue) { type in
                            Text(type.rawValue).tag(InstallerType?(type))
                        }
                        if case .unknown(let value) = draft.installerType ?? .pkg {
                            Text(value).tag(draft.installerType)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                LabelledField("Location") {
                    TextField("", text: Bindings.optional($draft.installerItemLocation))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                }
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
                LabelledField("Force install after", alignment: .center) {
                    ForceInstallDateField(date: $draft.forceInstallAfterDate)
                }
            }
            .cardStyle()
        }
    }

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("Description")
            TextEditor(text: Bindings.optional($draft.description))
                .frame(minHeight: 140)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
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
                    Picker("", selection: $format) {
                        ForEach(RepoFormat.allCases, id: \.self) { format in
                            Text(format.preferredExtension.uppercased()).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
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

    private var typeBinding: Binding<InstallerType?> {
        Binding(get: { draft.installerType }, set: { draft.installerType = $0 })
    }

    private var restartBinding: Binding<RestartAction?> {
        Binding(get: { draft.restartAction }, set: { draft.restartAction = $0 })
    }
}

// MARK: Contents

private struct ContentsTab: View {
    @Binding var draft: Pkginfo

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                CardSectionHeader("Installs")
                InstallsTable(items: Bindings.bindArray($draft.installs))
                    .cardStyle()
            }
            VStack(alignment: .leading, spacing: 0) {
                CardSectionHeader("Receipts")
                ReceiptsTable(items: Bindings.bindArray($draft.receipts))
                    .cardStyle()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: Requirements

private struct RequirementsTab: View {
    @Binding var draft: Pkginfo

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    CardSectionHeader("Requires")
                    StringListEditor(
                        values: Bindings.bindArray($draft.requires),
                        placeholder: "Add required item"
                    )
                    .cardStyle()
                }
                VStack(alignment: .leading, spacing: 0) {
                    CardSectionHeader("Update for")
                    StringListEditor(
                        values: Bindings.bindArray($draft.updateFor),
                        placeholder: "Add target"
                    )
                    .cardStyle()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    CardSectionHeader("Versions")
                    VStack(alignment: .leading, spacing: 10) {
                        LabelledField("Min macOS") {
                            TextField("", text: Bindings.optional($draft.minimumOSVersion))
                                .textFieldStyle(.roundedBorder)
                        }
                        LabelledField("Max macOS") {
                            TextField("", text: Bindings.optional($draft.maximumOSVersion))
                                .textFieldStyle(.roundedBorder)
                        }
                        LabelledField("Min munki") {
                            TextField("", text: Bindings.optional($draft.minimumMunkiVersion))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .cardStyle()
                }
                VStack(alignment: .leading, spacing: 0) {
                    CardSectionHeader("Installable condition")
                    TextEditor(text: Bindings.optional($draft.installableCondition))
                        .frame(minHeight: 100)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        .font(.system(.callout, design: .monospaced))
                        .cardStyle()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: Installation

private struct InstallationTab: View {
    @Binding var draft: Pkginfo

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                CardSectionHeader("Items to copy")
                ItemsToCopyTable(items: Bindings.bindArray($draft.itemsToCopy))
                    .cardStyle()
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    CardSectionHeader("Blocking applications")
                    StringListEditor(
                        values: blockingBinding,
                        placeholder: "Add bundle id or app name"
                    )
                    .cardStyle()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 0) {
                    CardSectionHeader("Supported architectures")
                    ArchitecturePicker(selected: $draft.supportedArchitectures)
                        .cardStyle()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var blockingBinding: Binding<[String]> {
        Binding(
            get: { (draft.blockingApplications ?? []).map(\.rawValue) },
            set: { newValues in
                draft.blockingApplications = newValues.isEmpty
                    ? nil
                    : newValues.map { BlockingApplication(rawValue: $0) }
            }
        )
    }
}

// MARK: Uninstall

private struct UninstallTab: View {
    @Binding var draft: Pkginfo

    private static let methods: [String] = [
        "removepackages", "remove_copied_items", "uninstall_script",
        "remove_app", "remove_profile", "uninstall_package",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                CardSectionHeader("Method")
                VStack(alignment: .leading, spacing: 10) {
                    LabelledField("Uninstall method") {
                        Picker("", selection: methodBinding) {
                            Text("Unspecified").tag(String?.none)
                            ForEach(Self.methods, id: \.self) { method in
                                Text(method).tag(String?(method))
                            }
                            if let m = draft.uninstallMethod, !Self.methods.contains(m) {
                                Text(m).tag(String?(m))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    Toggle("Uninstallable", isOn: Bindings.optionalBool($draft.uninstallable))
                }
                .cardStyle()
            }
            VStack(alignment: .leading, spacing: 0) {
                CardSectionHeader("Uninstall script")
                ScriptEditor(
                    label: "",
                    text: Bindings.optional($draft.uninstallScript)
                )
                .cardStyle()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var methodBinding: Binding<String?> {
        Binding(get: { draft.uninstallMethod }, set: { draft.uninstallMethod = $0 })
    }
}

// MARK: Scripts

private struct ScriptsTab: View {
    @Binding var draft: Pkginfo

    /// Default inline editor height for a single full-width card.
    private static let singleHeight: CGFloat = 200
    /// Paired side-by-side cards get double height so the pair claims
    /// the same vertical real estate as two stacked single cards —
    /// the user gets twice the script-editing area, not half.
    private static let pairedHeight: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            scriptCard("Install check", text: Bindings.optional($draft.installcheckScript), height: Self.singleHeight)
            HStack(alignment: .top, spacing: 16) {
                scriptCard("Pre-install", text: Bindings.optional($draft.preinstallScript), height: Self.pairedHeight)
                scriptCard("Post-install", text: Bindings.optional($draft.postinstallScript), height: Self.pairedHeight)
            }
            scriptCard("Uninstall check", text: Bindings.optional($draft.uninstallcheckScript), height: Self.singleHeight)
            HStack(alignment: .top, spacing: 16) {
                scriptCard("Pre-uninstall", text: Bindings.optional($draft.preuninstallScript), height: Self.pairedHeight)
                scriptCard("Post-uninstall", text: Bindings.optional($draft.postuninstallScript), height: Self.pairedHeight)
            }
            scriptCard("Version script", text: Bindings.optional($draft.versionScript), height: Self.singleHeight)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func scriptCard(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader(title)
            ScriptEditor(label: "", text: text, editorHeight: height)
                .frame(maxWidth: .infinity)
                .cardStyle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Alerts

private struct AlertsTab: View {
    @Binding var draft: Pkginfo

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                CardSectionHeader("Pre-install alert")
                AlertEditor(title: "Pre-install alert", alert: $draft.preinstallAlert)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
            }
            VStack(alignment: .leading, spacing: 0) {
                CardSectionHeader("Pre-uninstall alert")
                AlertEditor(title: "Pre-uninstall alert", alert: $draft.preuninstallAlert)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct AlertEditor: View {
    let title: String
    @Binding var alert: PreinstallAlert?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: enabledBinding) { Text("Enable \(title)").font(.headline) }
            Group {
                LabelledField("Title") {
                    TextField("Attention", text: textBinding(\.alertTitle))
                        .textFieldStyle(.roundedBorder)
                }
                LabelledField("Detail", alignment: .top) {
                    TextEditor(text: textBinding(\.alertDetail))
                        .frame(minHeight: 100)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }
                LabelledField("OK label") {
                    TextField("OK", text: textBinding(\.okLabel))
                        .textFieldStyle(.roundedBorder)
                }
                LabelledField("Cancel label") {
                    TextField("Cancel", text: textBinding(\.cancelLabel))
                        .textFieldStyle(.roundedBorder)
                }
            }
            .disabled(alert == nil)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { alert != nil },
            set: { isOn in
                alert = isOn ? (alert ?? PreinstallAlert()) : nil
            }
        )
    }

    private func textBinding(_ keyPath: WritableKeyPath<PreinstallAlert, String?>) -> Binding<String> {
        Binding(
            get: { alert?[keyPath: keyPath] ?? "" },
            set: { newValue in
                var current = alert ?? PreinstallAlert()
                current[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
                alert = current
            }
        )
    }
}

// MARK: Advanced

private struct AdvancedTab: View {
    @Binding var draft: Pkginfo

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    CardSectionHeader("Advanced options")
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Autoremove", isOn: Bindings.optionalBool($draft.autoremove))
                        Toggle("Apple update item", isOn: Bindings.optionalBool($draft.appleItem))
                        Toggle("Suppress bundle relocation", isOn: Bindings.optionalBool($draft.suppressBundleRelocation))
                        Toggle("Allow untrusted package signature", isOn: Bindings.optionalBool($draft.allowUntrusted))
                        Toggle("Precache", isOn: Bindings.optionalBool($draft.precache))
                        Toggle("Featured", isOn: Bindings.optionalBool($draft.featured))
                    }
                    .cardStyle()
                }
                VStack(alignment: .leading, spacing: 0) {
                    CardSectionHeader("Sizes & paths")
                    VStack(alignment: .leading, spacing: 10) {
                        LabelledField("Installer item hash") {
                            TextField("", text: Bindings.optional($draft.installerItemHash))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                        }
                        LabelledField("Installer item size") {
                            OptionalIntField(value: $draft.installerItemSize, placeholder: "kilobytes")
                        }
                        LabelledField("Package path") {
                            TextField("", text: Bindings.optional($draft.packagePath))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .cardStyle()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 0) {
                CardSectionHeader("Admin notes")
                TextEditor(text: Bindings.optional($draft.notes))
                    .frame(minHeight: 280)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .cardStyle()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: Reusable views

/// Two-column row: 140pt label + flexible value, baseline-aligned.
struct LabelledField<Value: View>: View {
    let label: String
    let alignment: VerticalAlignment
    @ViewBuilder var value: Value

    init(_ label: String, alignment: VerticalAlignment = .firstTextBaseline, @ViewBuilder value: () -> Value) {
        self.label = label
        self.alignment = alignment
        self.value = value()
    }

    @ScaledMetric(relativeTo: .body) private var labelColumnWidth: CGFloat = 140

    var body: some View {
        HStack(alignment: alignment) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: labelColumnWidth, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OptionalIntField: View {
    @Binding var value: Int?
    let placeholder: String

    @State private var text: String = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .onAppear { text = value.map(String.init) ?? "" }
            .onChange(of: text) { _, new in
                value = Int(new)
            }
            .onChange(of: value) { _, new in
                let str = new.map(String.init) ?? ""
                if str != text { text = str }
            }
    }
}

/// Optional-`Date` toggle + DatePicker.
private struct ForceInstallDateField: View {
    @Binding var date: Date?
    @State private var draftDate: Date = Date()

    var body: some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { date != nil },
                set: { isOn in
                    if isOn {
                        date = draftDate
                    } else {
                        if let date { draftDate = date }
                        date = nil
                    }
                }
            ))
            .labelsHidden()
            DatePicker("", selection: Binding(
                get: { date ?? draftDate },
                set: { newValue in
                    draftDate = newValue
                    if date != nil { date = newValue }
                }
            ))
            .labelsHidden()
            .disabled(date == nil)
        }
    }
}

// MARK: Sub-tables

private struct InstallsTable: View {
    @Binding var items: [InstallsItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                InstallsRow(item: $items[index]) {
                    items.remove(at: index)
                }
            }
            Button {
                items.append(InstallsItem(path: ""))
            } label: {
                Label("Add install item", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct InstallsRow: View {
    @Binding var item: InstallsItem
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Path", text: $item.path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
            }
            HStack {
                LabelledField("Type") {
                    TextField("application", text: Bindings.optional($item.type))
                        .textFieldStyle(.roundedBorder)
                }
                LabelledField("Bundle id") {
                    TextField("", text: Bindings.optional($item.cfBundleIdentifier))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                }
            }
            HStack {
                LabelledField("Bundle short version") {
                    TextField("", text: Bindings.optional($item.cfBundleShortVersionString))
                        .textFieldStyle(.roundedBorder)
                }
                LabelledField("Bundle version") {
                    TextField("", text: Bindings.optional($item.cfBundleVersion))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
    }
}

private struct ReceiptsTable: View {
    @Binding var items: [Receipt]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("Package ID", text: Bindings.optional($items[index].packageid))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    TextField("Version", text: Bindings.optional($items[index].version))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Toggle("Optional", isOn: Bindings.optionalBool($items[index].optional))
                    Button(role: .destructive) {
                        items.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                items.append(Receipt())
            } label: {
                Label("Add receipt", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct ItemsToCopyTable: View {
    @Binding var items: [ItemToCopy]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        LabelledField("Source item") {
                            TextField("", text: $items[index].sourceItem)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                        }
                        Button(role: .destructive) {
                            items.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                    LabelledField("Destination path") {
                        TextField("", text: Bindings.optional($items[index].destinationPath))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                    }
                    LabelledField("Destination item") {
                        TextField("", text: Bindings.optional($items[index].destinationItem))
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        LabelledField("User") {
                            TextField("root", text: Bindings.optional($items[index].user))
                                .textFieldStyle(.roundedBorder)
                        }
                        LabelledField("Group") {
                            TextField("admin", text: Bindings.optional($items[index].group))
                                .textFieldStyle(.roundedBorder)
                        }
                        LabelledField("Mode") {
                            TextField("0755", text: Bindings.optional($items[index].mode))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
            }
            Button {
                items.append(ItemToCopy(sourceItem: ""))
            } label: {
                Label("Add item to copy", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }
}

// Plain string-list editor with row + minus and an inline Add field.
private struct StringListEditor: View {
    @Binding var values: [String]
    let placeholder: String
    @State private var pending: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(values.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("", text: $values[index])
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    Button(role: .destructive) {
                        values.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                TextField(placeholder, text: $pending)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                Button("Add", action: commit)
                    .disabled(pending.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func commit() {
        let value = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        values.append(value)
        pending = ""
    }
}

// MARK: Binding helpers

private enum Bindings {
    static func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    static func optionalBool(_ binding: Binding<Bool?>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue ?? false },
            set: { binding.wrappedValue = $0 ? true : nil }
        )
    }

    /// Bridges `Binding<[T]?>` ↔ `Binding<[T]>` without capturing a
    /// `WritableKeyPath` (which isn't `Sendable` and trips concurrency
    /// warnings under strict mode). Pass the `$` projection directly.
    static func bindArray<Element: Sendable>(_ optional: Binding<[Element]?>) -> Binding<[Element]> {
        Binding(
            get: { optional.wrappedValue ?? [] },
            set: { optional.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

private extension InstallerType {
    static let knownCases: [InstallerType] = [
        .pkg, .copyFromDmg, .nopkg, .stageOSInstaller,
        .startosinstall, .configurationProfile, .appleUpdateMetadata,
    ]
}
