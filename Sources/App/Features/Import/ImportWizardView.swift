import SwiftUI
import Core
import AppKit
import UniformTypeIdentifiers

/// Single-file 4-step wizard. Structure mirrors CimianStudio's import
/// page: Review → Edit metadata → Scripts → Location & review.
///
/// `importStore` is threaded explicitly (not via the environment) so a
/// missing observable object can never crash the view tree.
struct ImportWizardView: View {
    let installerURL: URL
    @Bindable var importStore: ImportStore
    @Environment(RepositoryStore.self) private var repoStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            wizardHeader
            Group {
                switch importStore.step {
                case .review: ReviewStep(installerURL: installerURL, importStore: importStore, repoStore: repoStore)
                case .editMetadata: EditMetadataStep(importStore: importStore)
                case .scripts: ScriptsStep(importStore: importStore)
                case .locationAndReview: LocationStep(installerURL: installerURL, importStore: importStore, repoStore: repoStore)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .background(.background.secondary, in: .rect(cornerRadius: 10))
        }
        .task(id: installerURL) {
            // Auto-adopt a matching pkginfo as the template. The user can
            // still click "Start fresh" in Step 1 to discard it.
            guard let match = repoStore.snapshot.pkginfos.first(where: { record in
                !importStore.edited.name.isEmpty &&
                record.pkginfo.name.caseInsensitiveCompare(importStore.edited.name) == .orderedSame
            }) else { return }
            if let repo = repoStore.repository {
                importStore.applyTemplate(match, in: repo)
            } else {
                importStore.templateMatch = match
            }
        }
    }

    @ViewBuilder
    private var wizardHeader: some View {
        HStack(spacing: 8) {
            Text(installerURL.lastPathComponent)
                .font(.body.bold())
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)

            Button("Cancel", role: .cancel) { importStore.resetToIdle() }
                .buttonStyle(.bordered)
            // Back is always present (disabled on Step 1) so Cancel /
            // Back / advance never shift position between steps.
            Button("Back") { goBack() }
                .buttonStyle(.bordered)
                .disabled(importStore.step == .review)
            Button(importStore.step.advanceLabel) {
                Task { await advance() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAdvance)
            .frame(minWidth: 90)

            Text(importStore.step.label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
            Button("Pick a different file…") { importStore.resetToIdle() }
                .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    private var canAdvance: Bool {
        switch importStore.step {
        case .review, .editMetadata: !importStore.edited.name.isEmpty
        case .scripts, .locationAndReview: true
        }
    }

    private func goBack() {
        if let previous = ImportStore.WizardStep(rawValue: importStore.step.rawValue - 1) {
            importStore.step = previous
        }
    }

    private func advance() async {
        switch importStore.step {
        case .review: importStore.step = .editMetadata
        case .editMetadata: importStore.step = .scripts
        case .scripts: importStore.step = .locationAndReview
        case .locationAndReview: await runMunkiimport()
        }
    }

    private func runMunkiimport() async {
        guard let repository = repoStore.repository else {
            importStore.statusBanner = .init(severity: .error, title: "Import failed", message: "No repository is open.")
            return
        }
        let services = repoStore.services
        let emitYAML = repository.defaultFormat == .yaml

        let staged: (paths: [ImportStore.ScriptSlot: URL], cleanup: @Sendable () -> Void)
        do {
            staged = try importStore.stageScriptFiles()
        } catch {
            importStore.statusBanner = .init(severity: .error, title: "Import failed", message: error.localizedDescription)
            return
        }
        defer { staged.cleanup() }

        let options = importStore.buildOptions(
            installerURL: installerURL,
            scriptPaths: staged.paths,
            emitYAML: emitYAML
        )

        importStore.output = ""
        importStore.statusBanner = nil

        var outcome: MunkiimportOutcome?
        do {
            for try await event in services.munkiimport.run(in: repository, options: options) {
                switch event {
                case .line(let line):
                    importStore.output.append(line)
                    importStore.output.append("\n")
                case .finished(let result):
                    outcome = result
                }
            }
        } catch {
            importStore.statusBanner = .init(
                severity: .error,
                title: "munkiimport failed to launch",
                message: error.localizedDescription
            )
            return
        }

        if let outcome, outcome.exitCode == 0 {
            await repoStore.reload()
            importStore.statusBanner = .init(
                severity: .success,
                title: "Import complete",
                message: outcome.pkginfoURL.map { "Wrote \($0.lastPathComponent)." }
                    ?? "munkiimport finished without errors."
            )
            if let pkginfoURL = outcome.pkginfoURL,
               let record = repoStore.snapshot.pkginfos.first(where: { $0.fileURL.path == pkginfoURL.path }) {
                repoStore.selectedItemID = record.fileURL as AnyHashable
            }
        } else {
            importStore.statusBanner = .init(
                severity: .error,
                title: "munkiimport exited \(outcome?.exitCode ?? -1)",
                message: outcome?.errorOutput.split(whereSeparator: \.isNewline).first.map(String.init)
                    ?? "See command output below."
            )
        }
    }
}

// MARK: - Step 1: Review

private struct ReviewStep: View {
    let installerURL: URL
    @Bindable var importStore: ImportStore
    let repoStore: RepositoryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let template = importStore.templateMatch {
                    templateBanner(template)
                }

                Text("Detected metadata").font(.headline)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 8) {
                    factRow("Name", importStore.extracted.name)
                    factRow("Version", importStore.extracted.version)
                    factRow("Display name", importStore.extracted.displayName)
                    factRow("Kind", importStore.extracted.installerKindHint.label)
                    if let bundle = importStore.extracted.bundleIdentifier {
                        factRow("Bundle identifier", bundle)
                    }
                    if !importStore.extracted.developer.isEmpty {
                        factRow("Developer", importStore.extracted.developer)
                    }
                    if !importStore.extracted.supportedArchitectures.isEmpty {
                        factRow("Architecture", importStore.extracted.supportedArchitectures.joined(separator: ", "))
                    }
                }

                Text("Anything missing here will be filled in by munkiimport when it inspects the installer. You can override every value in Step 2.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func templateBanner(_ template: PkginfoRecord) -> some View {
        let inherit = importStore.useTemplate
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: inherit ? "checkmark.seal.fill" : "info.circle.fill")
                .foregroundStyle(inherit ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(inherit
                     ? "Using \(template.pkginfo.name) \(template.pkginfo.version ?? "") as template"
                     : "Found existing item: \(template.pkginfo.name) \(template.pkginfo.version ?? "")")
                    .font(.body.bold())
                Text(inherit
                     ? "Catalogs, scripts, blocking_applications, unattended flags inherited. You'll review every field in Step 2."
                     : "This name already exists in the repo. Catalogs, scripts, blocking_applications, etc. can be inherited from the existing pkginfo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Use template") {
                        if let repo = repoStore.repository {
                            importStore.applyTemplate(template, in: repo)
                        }
                    }
                    .disabled(inherit)
                    Button("Start fresh") { importStore.startFresh() }
                        .disabled(!inherit)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.tertiary, in: .rect(cornerRadius: 8))
    }

    @ViewBuilder
    private func factRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value.isEmpty ? "—" : value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 2: Edit metadata

private struct EditMetadataStep: View {
    @Bindable var importStore: ImportStore
    @State private var pickingIcon = false

    private static let iconTypes: [UTType] = ["icns", "png"]
        .compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit metadata").font(.headline)
                Text("Adjust anything you want munkiimport to write into the pkginfo. Empty values fall back to munkiimport's autodetection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        labeled("Name") {
                            TextField("Required", text: $importStore.edited.name)
                                .textFieldStyle(.roundedBorder)
                        }
                        labeled("Version") {
                            TextField("e.g. 123.0", text: $importStore.edited.version)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    GridRow {
                        labeled("Display name") {
                            TextField("Optional", text: $importStore.edited.displayName)
                                .textFieldStyle(.roundedBorder)
                        }
                        labeled("Developer") {
                            TextField("Optional", text: $importStore.edited.developer)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    GridRow {
                        labeled("Category") {
                            TextField("Optional", text: $importStore.edited.category)
                                .textFieldStyle(.roundedBorder)
                        }
                        labeled("Architecture") {
                            Picker("", selection: $importStore.architectureSelection) {
                                ForEach(ImportStore.ArchitectureSelection.allCases) { arch in
                                    Text(arch.label).tag(arch)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    GridRow {
                        labeled("Min macOS") {
                            TextField("e.g. 12.0", text: $importStore.minimumOSVersion)
                                .textFieldStyle(.roundedBorder)
                        }
                        labeled("Max macOS") {
                            TextField("Optional", text: $importStore.maximumOSVersion)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    GridRow {
                        labeled("Min Munki version") {
                            TextField("Optional", text: $importStore.minimumMunkiVersion)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                labeled("Description") {
                    TextEditor(text: $importStore.edited.description)
                        .font(.body)
                        .frame(minHeight: 70)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 1))
                }

                HStack(spacing: 14) {
                    Toggle("Unattended install", isOn: $importStore.unattendedInstall)
                    Toggle("Unattended uninstall", isOn: $importStore.unattendedUninstall)
                    Toggle("Extract icon from installer", isOn: $importStore.extractIcon)
                    Spacer()
                }

                labeled("Custom icon") {
                    HStack(spacing: 8) {
                        Text(importStore.iconPath?.lastPathComponent ?? "None")
                            .foregroundStyle(importStore.iconPath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { pickingIcon = true }
                        if importStore.iconPath != nil {
                            Button("Clear") { importStore.iconPath = nil }
                        }
                        Spacer()
                    }
                }

                Divider()

                labeled("Catalogs") {
                    ChipField(values: $importStore.catalogs, placeholder: "Add a catalog…")
                }
                labeled("Blocking applications") {
                    ChipField(values: $importStore.blockingApplications, placeholder: "Add a blocking app…")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(
            isPresented: $pickingIcon,
            allowedContentTypes: Self.iconTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                importStore.iconPath = url
            }
        }
    }

    @ViewBuilder
    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

}

// MARK: - Step 3: Scripts

private struct ScriptsStep: View {
    @Bindable var importStore: ImportStore
    @State private var selectedSlot: ImportStore.ScriptSlot = .preinstall

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Scripts").font(.headline)
                Text("Optional scripts run by Munki around install / uninstall. Empty slots are omitted. Exit-code semantics for the *_check scripts match Munki: 0 means the action is needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("", selection: $selectedSlot) {
                    ForEach(ImportStore.ScriptSlot.allCases) { slot in
                        Text(slot.tabLabel).tag(slot)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ScriptEditor(
                    label: selectedSlot.rawValue + "_script",
                    text: scriptBinding(selectedSlot),
                    editorHeight: 260
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scriptBinding(_ slot: ImportStore.ScriptSlot) -> Binding<String> {
        Binding(
            get: { importStore.scripts[slot] ?? "" },
            set: { importStore.scripts[slot] = $0.isEmpty ? nil : $0 }
        )
    }
}

// MARK: - Step 4: Location and review

private struct LocationStep: View {
    let installerURL: URL
    @Bindable var importStore: ImportStore
    let repoStore: RepositoryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Location and review").font(.headline)
                Text("The pkginfo and installer will be saved relative to the open repository. The command preview below is exactly what will run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Repo subdirectory").font(.caption).foregroundStyle(.secondary)
                    TextField("apps/MyApp (leave blank for top-level)", text: $importStore.subdirectory)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("munkiimport invocation").font(.caption).foregroundStyle(.secondary)
                    Text(commandPreview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.background.tertiary, in: .rect(cornerRadius: 6))
                }

                if !importStore.output.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("munkiimport output").font(.caption).foregroundStyle(.secondary)
                        Text(importStore.output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.background.tertiary, in: .rect(cornerRadius: 6))
                    }
                }

                if let banner = importStore.statusBanner {
                    StatusBannerView(banner: banner)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var commandPreview: String {
        guard let repo = repoStore.repository else {
            return "/usr/local/munki/munkiimport -n  <no repository open>"
        }
        let emitYAML = repo.defaultFormat == .yaml
        let options = importStore.buildOptions(installerURL: installerURL, scriptPaths: [:], emitYAML: emitYAML)
        return "/usr/local/munki/munkiimport " + MunkiimportPreview.command(repository: repo, options: options)
    }
}

private struct StatusBannerView: View {
    let banner: ImportStore.StatusBanner

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.body.bold())
                Text(banner.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 8))
    }

    private var icon: String {
        switch banner.severity {
        case .info: "info.circle.fill"
        case .success: "checkmark.seal.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch banner.severity {
        case .info: .accentColor
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

/// Renders the flag set the runner will pass, so Step 4 can show the
/// exact command without running it.
enum MunkiimportPreview {
    static func command(repository: MunkiRepository, options: MunkiimportOptions) -> String {
        var parts: [String] = ["-n", "--repo-url", "file://\(repository.rootURL.path)"]
        if !options.subdirectory.isEmpty {
            parts.append(contentsOf: ["--subdirectory", quoted(options.subdirectory)])
        }
        for catalog in options.catalogs where !catalog.isEmpty {
            parts.append(contentsOf: ["--catalog", quoted(catalog)])
        }
        if let value = options.name, !value.isEmpty { parts.append(contentsOf: ["--name", quoted(value)]) }
        if let value = options.displayName, !value.isEmpty { parts.append(contentsOf: ["--displayname", quoted(value)]) }
        if let value = options.version, !value.isEmpty { parts.append(contentsOf: ["--pkgvers", quoted(value)]) }
        if let value = options.developer, !value.isEmpty { parts.append(contentsOf: ["--developer", quoted(value)]) }
        if let value = options.category, !value.isEmpty { parts.append(contentsOf: ["--category", quoted(value)]) }
        if let value = options.description, !value.isEmpty { parts.append(contentsOf: ["--description", quoted(value)]) }
        for arch in options.supportedArchitectures { parts.append(contentsOf: ["--arch", arch]) }
        if options.unattendedInstall { parts.append("--unattended-install") }
        if options.unattendedUninstall { parts.append("--unattended-uninstall") }
        for app in options.blockingApplications { parts.append(contentsOf: ["--blocking-application", quoted(app)]) }
        if let value = options.minimumOSVersion, !value.isEmpty { parts.append(contentsOf: ["--minimum-os-version", value]) }
        if let value = options.maximumOSVersion, !value.isEmpty { parts.append(contentsOf: ["--maximum-os-version", value]) }
        if let value = options.minimumMunkiVersion, !value.isEmpty { parts.append(contentsOf: ["--minimum-munki-version", value]) }
        if options.emitYAML { parts.append("--yaml") }
        if options.extractIcon { parts.append("--extract-icon") }
        if let icon = options.iconPath { parts.append(contentsOf: ["--icon-path", quoted(icon.path)]) }
        parts.append(quoted(options.installerPath.path))
        return parts.joined(separator: " ")
    }

    private static func quoted(_ value: String) -> String {
        value.contains(where: { $0.isWhitespace }) ? "'\(value)'" : value
    }
}
