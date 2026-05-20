import SwiftUI
import AppKit
import Core

/// Tabbed pkginfo editor with five panels, each telling one story:
///   - Overview: what is this thing — identity, MSC fields, catalogs,
///     requirements, installer metadata, file metadata.
///   - Detection: how Munki recognizes the item is (or isn't) installed
///     — installs, installcheck_script, version_script, receipts,
///     uninstallcheck_script.
///   - Install: how the item gets onto disk — items_to_copy,
///     blocking_applications, installer_environment, installer_choices,
///     preinstall_script, postinstall_script.
///   - Uninstall: parallel to Install — method, uninstaller item,
///     uninstall_script, preuninstall_script, postuninstall_script.
///   - Advanced: flags, alerts, sizes & paths.
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
    @State private var activeTab: EditorTab = .overview
    @State private var hoveredTab: EditorTab? = nil

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
                    case .overview: OverviewTab(draft: draftBinding, format: formatBinding, fileURL: record.fileURL, createdAt: record.createdAt, modifiedAt: record.modifiedAt)
                    case .detection: DetectionTab(draft: draftBinding)
                    case .install: InstallTab(draft: draftBinding)
                    case .uninstall: UninstallTab(draft: draftBinding)
                    case .advanced: AdvancedTab(draft: draftBinding)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(16)
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(EditorTab.allCases) { tab in
                tabButton(tab)
            }
            Spacer()
            RecordActionMenu(record: .package(record))
                .padding(.trailing, 14)
        }
        .padding(.top, 18)
        // Continuous baseline rule across the whole strip so the row
        // reads as a single tabbed control instead of disconnected
        // labels. Each active tab paints its accent rule on top.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 1)
        }
    }

    /// Underlined-tab style. Every tab reads as a real clickable
    /// element — full primary text colour, hover tint, weight bump
    /// on the active one — and only the accent underline plus a soft
    /// glow distinguishes the active tab from its peers.
    private func tabButton(_ tab: EditorTab) -> some View {
        let isActive = activeTab == tab
        let isHovered = hoveredTab == tab
        return Button {
            activeTab = tab
        } label: {
            VStack(spacing: 0) {
                Text(tab.title)
                    .font(.title3.weight(isActive ? .bold : .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(
                        (isHovered && !isActive)
                            ? Color.primary.opacity(0.06)
                            : Color.clear,
                        in: .rect(cornerRadius: 6)
                    )
                Rectangle()
                    .fill(isActive ? Color.accentColor : Color.clear)
                    .frame(height: 2)
                    .shadow(
                        color: isActive ? Color.accentColor.opacity(0.32) : .clear,
                        radius: 3,
                        y: 1
                    )
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredTab = tab
            } else if hoveredTab == tab {
                hoveredTab = nil
            }
        }
    }

}

private enum EditorTab: String, CaseIterable, Identifiable {
    case overview, detection, install, uninstall, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .detection: "Detection"
        case .install: "Install"
        case .uninstall: "Uninstall"
        case .advanced: "Advanced"
        }
    }
}

// MARK: Overview

/// What is this thing — identity, MSC fields, catalogs, requirements,
/// installer metadata, and on-disk file metadata. Admin notes sit
/// next to Description on purpose: they're both prose about the item.
private struct OverviewTab: View {
    @Environment(RepositoryStore.self) private var store
    @Binding var draft: Pkginfo
    @Binding var format: RepoFormat
    let fileURL: URL
    let createdAt: Date?
    let modifiedAt: Date?
    @State private var showSuspiciousPackagePrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    identityCard
                    catalogsCard
                    descriptionCard
                    adminNotesCard
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 16) {
                    installerCard
                    requirementsCard
                    fileCard
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            metadataFooter
        }
    }

    /// `_metadata` footer — info Munki tools embed when they create or
    /// touch the pkginfo (created_by, creation_date, munki_version,
    /// os_version, …). Rendered at the bottom with no card chrome and
    /// caption-sized tertiary text so it reads as provenance, not data
    /// the admin is meant to edit.
    @ViewBuilder
    private var metadataFooter: some View {
        if let metadata = draft.metadata, !metadata.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Metadata")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                FlowLayout(spacing: 32) {
                    ForEach(metadata.keys.sorted(), id: \.self) { key in
                        if let value = metadata[key],
                           let display = Self.displayString(for: value) {
                            HStack(spacing: 5) {
                                Text(key)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tertiary)
                                Text(display)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let metadataDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Best-effort string rendering of a PlistValue scalar for the
    /// metadata footer. Containers (array, dictionary, data) are
    /// suppressed — the footer is for at-a-glance provenance, not a
    /// nested plist browser.
    private static func displayString(for value: PlistValue) -> String? {
        switch value {
        case .string(let s):
            return s.isEmpty ? nil : s
        case .integer(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .bool(let b):
            return b ? "true" : "false"
        case .date(let d):
            return metadataDateFormatter.string(from: d)
        case .data, .array, .dictionary:
            return nil
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

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("Description")
            TextEditor(text: Bindings.optional($draft.description))
                .frame(minHeight: 120)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .cardStyle()
        }
    }

    private var adminNotesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("Admin notes")
            TextEditor(text: Bindings.optional($draft.notes))
                .frame(minHeight: 120)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
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
                    HStack(spacing: 6) {
                        TextField("", text: Bindings.optional($draft.installerItemLocation))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                        if let url = installerItemURL, SuspiciousPackage.canInspect(url) {
                            Button {
                                inspectInstaller()
                            } label: {
                                Image(nsImage: SuspiciousPackage.pkgFileIcon)
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                    .accessibilityHidden(true)
                            }
                            .buttonStyle(.borderless)
                            .disabled(!installerItemExists)
                            .accessibilityLabel("Open with Suspicious Package")
                            .help(installerItemExists
                                ? "Inspect this package with Suspicious Package"
                                : "Installer item not found under pkgs/")
                        }
                    }
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
            }
            .cardStyle()
        }
        .alert("Suspicious Package isn't installed", isPresented: $showSuspiciousPackagePrompt) {
            Button("Get Suspicious Package\u{2026}") { SuspiciousPackage.openDownloadPage() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Suspicious Package is a free app for inspecting macOS installer packages. Download it from mothersruin.com, then try again.")
        }
    }

    private var requirementsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("Requirements")
            VStack(alignment: .leading, spacing: 12) {
                LabelledField("Requires", alignment: .top) {
                    StringListEditor(
                        values: Bindings.bindArray($draft.requires),
                        placeholder: "Add required item"
                    )
                }
                LabelledField("Update for", alignment: .top) {
                    StringListEditor(
                        values: Bindings.bindArray($draft.updateFor),
                        placeholder: "Add target"
                    )
                }
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
                LabelledField("Architectures", alignment: .top) {
                    ArchitecturePicker(selected: $draft.supportedArchitectures)
                }
                LabelledField("Force install after", alignment: .center) {
                    ForceInstallDateField(date: $draft.forceInstallAfterDate)
                }
                LabelledField("Installable condition", alignment: .top) {
                    TextEditor(text: Bindings.optional($draft.installableCondition))
                        .frame(minHeight: 80)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        .font(.system(.callout, design: .monospaced))
                }
            }
            .cardStyle()
        }
    }

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("File")
            VStack(alignment: .leading, spacing: 10) {
                LabelledField("Path", alignment: .top) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(fileURL.path)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                    }
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

    /// Absolute path of the installer item under the repo's `pkgs/`.
    /// `installer_item_location` is repo data, so a stray `..` or an
    /// absolute path is rejected rather than allowed to resolve outside
    /// `pkgs/`.
    private var installerItemURL: URL? {
        guard let location = draft.installerItemLocation?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !location.isEmpty,
              let repo = store.repository else { return nil }
        let pkgsRoot = repo.pkgsURL.standardizedFileURL
        let candidate = pkgsRoot.appending(path: location).standardizedFileURL
        // Containment check: the resolved path must stay inside pkgs/.
        guard candidate.path == pkgsRoot.path
                || candidate.path.hasPrefix(pkgsRoot.path + "/") else { return nil }
        return candidate
    }

    private var installerItemExists: Bool {
        guard let url = installerItemURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Open the installer item in Suspicious Package; if the app isn't
    /// installed, prompt the user to download it.
    private func inspectInstaller() {
        guard let url = installerItemURL else { return }
        if !SuspiciousPackage.open(url) {
            showSuspiciousPackagePrompt = true
        }
    }
}

// MARK: Detection

/// All the ways Munki recognizes whether this item is installed.
/// `installs` / `installcheck_script` / `version_script` answer
/// "is the right version present?". `receipts` answers it from
/// Apple installer history. `uninstallcheck_script` answers "is it
/// still installed enough to need removing?".
private struct DetectionTab: View {
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
            VStack(alignment: .leading, spacing: 0) {
                CardSectionHeader("Install check script")
                hint("When set, overrides the installs/receipts check.")
                ScriptEditor(label: "", text: Bindings.optional($draft.installcheckScript))
                    .cardStyle()
            }
            VStack(alignment: .leading, spacing: 0) {
                CardSectionHeader("Version script")
                hint("Reports the installed version; Munki compares the output to the pkginfo's version field.")
                ScriptEditor(label: "", text: Bindings.optional($draft.versionScript))
                    .cardStyle()
            }
            VStack(alignment: .leading, spacing: 0) {
                CardSectionHeader("Uninstall check script")
                hint("Exit 0 if the item still needs to be uninstalled, non-zero otherwise.")
                ScriptEditor(label: "", text: Bindings.optional($draft.uninstallcheckScript))
                    .cardStyle()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
    }
}

// MARK: Install

private struct InstallTab: View {
    @Binding var draft: Pkginfo

    /// Side-by-side script editors share this height so the pair
    /// claims as much vertical room as two stacked editors would.
    private static let pairedScriptHeight: CGFloat = 320

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
                    CardSectionHeader("Installer environment")
                    InstallerEnvironmentEditor(environment: $draft.installerEnvironment)
                        .cardStyle()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 0) {
                CardSectionHeader("Installer choices")
                InstallerChoicesTable(choices: $draft.installerChoicesXml)
                    .cardStyle()
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    CardSectionHeader("Pre-install script")
                    ScriptEditor(
                        label: "",
                        text: Bindings.optional($draft.preinstallScript),
                        editorHeight: Self.pairedScriptHeight
                    )
                    .cardStyle()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 0) {
                    CardSectionHeader("Post-install script")
                    ScriptEditor(
                        label: "",
                        text: Bindings.optional($draft.postinstallScript),
                        editorHeight: Self.pairedScriptHeight
                    )
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

    private static let pairedScriptHeight: CGFloat = 320

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
                CardSectionHeader("Uninstaller item")
                VStack(alignment: .leading, spacing: 10) {
                    LabelledField("Location") {
                        TextField("", text: Bindings.optional($draft.uninstallerItemLocation))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                    }
                    LabelledField("Hash") {
                        TextField("", text: Bindings.optional($draft.uninstallerItemHash))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                    }
                    LabelledField("Size") {
                        OptionalIntField(value: $draft.uninstallerItemSize, placeholder: "kilobytes")
                    }
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
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    CardSectionHeader("Pre-uninstall script")
                    ScriptEditor(
                        label: "",
                        text: Bindings.optional($draft.preuninstallScript),
                        editorHeight: Self.pairedScriptHeight
                    )
                    .cardStyle()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 0) {
                    CardSectionHeader("Post-uninstall script")
                    ScriptEditor(
                        label: "",
                        text: Bindings.optional($draft.postuninstallScript),
                        editorHeight: Self.pairedScriptHeight
                    )
                    .cardStyle()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var methodBinding: Binding<String?> {
        Binding(get: { draft.uninstallMethod }, set: { draft.uninstallMethod = $0 })
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
                flagsCard
                sizesCard
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 16) {
                alertCard(title: "Pre-install alert", alert: $draft.preinstallAlert)
                alertCard(title: "Pre-uninstall alert", alert: $draft.preuninstallAlert)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Two-column toggle grid so the flag list stays visually tight
    /// instead of giving each toggle its own row.
    private var flagsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("Flags")
            let columns = [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading)
            ]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                Toggle("Autoremove", isOn: Bindings.optionalBool($draft.autoremove))
                Toggle("Apple update item", isOn: Bindings.optionalBool($draft.appleItem))
                Toggle("Suppress bundle relocation", isOn: Bindings.optionalBool($draft.suppressBundleRelocation))
                Toggle("Allow untrusted signature", isOn: Bindings.optionalBool($draft.allowUntrusted))
                Toggle("Precache", isOn: Bindings.optionalBool($draft.precache))
                Toggle("Featured", isOn: Bindings.optionalBool($draft.featured))
                Toggle("Unattended install", isOn: Bindings.optionalBool($draft.unattendedInstall))
                Toggle("Unattended uninstall", isOn: Bindings.optionalBool($draft.unattendedUninstall))
                Toggle("On demand", isOn: Bindings.optionalBool($draft.onDemand))
            }
            .cardStyle()
        }
    }

    private var sizesCard: some View {
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

    private func alertCard(title: String, alert: Binding<PreinstallAlert?>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader(title)
            AlertEditor(title: title, alert: alert)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
        }
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

/// Key/value editor for `installer_environment` — environment variables
/// passed to `/usr/sbin/installer`. The dictionary is unordered, so rows
/// are sorted by key when loaded.
private struct InstallerEnvironmentEditor: View {
    @Binding var environment: [String: String]?

    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }
    @State private var rows: [Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    TextField("KEY", text: $row.key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    TextField("value", text: $row.value)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                rows.append(Row(key: "", value: ""))
            } label: {
                Label("Add variable", systemImage: "plus")
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            rows = (environment ?? [:])
                .map { Row(key: $0.key, value: $0.value) }
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        }
        .onChange(of: rows) { _, _ in commit() }
    }

    private func commit() {
        var dict: [String: String] = [:]
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            dict[key] = row.value
        }
        environment = dict.isEmpty ? nil : dict
    }
}

/// One row of an ``InstallerChoicesTable``. Keys other than the three the
/// table edits are kept in `extras` so the choice dict round-trips intact.
private struct InstallerChoice: Identifiable, Equatable {
    let id = UUID()
    var identifier: String
    var attribute: String
    var setting: Int
    var extras: [String: PlistValue]

    static func from(_ value: PlistValue) -> InstallerChoice? {
        guard case .dictionary(var dict) = value else { return nil }
        var identifier = ""
        if case .string(let s)? = dict["choiceIdentifier"] { identifier = s }
        var attribute = "selected"
        if case .string(let s)? = dict["choiceAttribute"] { attribute = s }
        var setting = 0
        switch dict["attributeSetting"] {
        case .integer(let i)?: setting = i
        case .bool(let b)?: setting = b ? 1 : 0
        default: break
        }
        for key in ["choiceIdentifier", "choiceAttribute", "attributeSetting"] {
            dict.removeValue(forKey: key)
        }
        return InstallerChoice(identifier: identifier, attribute: attribute, setting: setting, extras: dict)
    }

    var plistValue: PlistValue {
        var dict = extras
        dict["choiceIdentifier"] = .string(identifier)
        dict["choiceAttribute"] = .string(attribute)
        dict["attributeSetting"] = .integer(setting)
        return .dictionary(dict)
    }
}

/// Structured table for `installer_choices_xml` — the choice changes a
/// distribution package's installer applies. One row per choice with the
/// identifier / attribute / setting columns, matching MunkiAdmin.
private struct InstallerChoicesTable: View {
    @Binding var choices: [PlistValue]?
    @State private var rows: [InstallerChoice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !rows.isEmpty {
                HStack(spacing: 6) {
                    Text("Choice identifier").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Attribute").frame(width: 110, alignment: .leading)
                    Text("Setting").frame(width: 64, alignment: .leading)
                    Color.clear.frame(width: 20)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    TextField("com.example.choice", text: $row.identifier)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity)
                    TextField("selected", text: $row.attribute)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    TextField("0", value: $row.setting, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    Button(role: .destructive) {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                rows.append(InstallerChoice(identifier: "", attribute: "selected", setting: 0, extras: [:]))
            } label: {
                Label("Add choice", systemImage: "plus")
            }
            .buttonStyle(.plain)
        }
        .onAppear { rows = (choices ?? []).compactMap(InstallerChoice.from) }
        .onChange(of: rows) { _, _ in commit() }
    }

    private func commit() {
        let mapped = rows
            .filter { !$0.identifier.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(\.plistValue)
        choices = mapped.isEmpty ? nil : mapped
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
