import SwiftUI
import Core
import CoreServices

/// Full-width Build section. A fixed-width munkipkg project list on the
/// left; the selected project's build-info, payload and scripts on the
/// right.
struct BuildView: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var projects: [MunkipkgProject] = []
    @State private var selectedProjectID: String?
    @State private var filter = ""
    @FocusState private var filterFocused: Bool
    @State private var loading = false
    @State private var loadError: String?
    // Context-menu "Build" sets `pendingBuildID` and bumps `buildToken`
    // so the detail view runs a build whether or not the project was
    // already selected.
    @State private var pendingBuildID: String?
    @State private var buildToken = 0
    @State private var renameTarget: MunkipkgProject?
    @State private var renameText = ""
    @State private var deleteTarget: MunkipkgProject?
    @State private var folderWatcher: DirectoryWatcher?
    // Build flags are shared across the session so they stick when
    // switching between projects.
    @State private var buildOptions = MunkipkgBuildOptions()

    private var projectsFolder: URL? {
        let path = settings.munkipkgProjectsPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private var filteredProjects: [MunkipkgProject] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var selectedProject: MunkipkgProject? {
        projects.first { $0.id == selectedProjectID }
    }

    var body: some View {
        content
            .navigationSubtitle(subtitle)
            .toolbar {
                if loading {
                    ToolbarItem(placement: .automatic) {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .task(id: settings.munkipkgProjectsPath) {
                await reload()
                startWatching()
                consumePendingBuildSelection()
            }
            .onChange(of: store.pendingBuildProjectID) { _, _ in
                consumePendingBuildSelection()
            }
            .onDisappear {
                folderWatcher?.cancel()
                folderWatcher = nil
            }
            .alert("Rename Project", isPresented: renamePresented) {
                TextField("Name", text: $renameText)
                Button("Rename") { commitRename() }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .alert("Delete project?", isPresented: deletePresented, presenting: deleteTarget) { target in
                Button("Delete", role: .destructive) {
                    Task { await performDeleteProject(target) }
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: { target in
                Text("\u{201c}\(target.name)\u{201d} will be permanently removed from disk.")
            }
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    /// The project count, shown as the window's toolbar subtitle.
    private var subtitle: String {
        projects.isEmpty
            ? "munkipkg projects"
            : "\(projects.count) munkipkg project\(projects.count == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView {
                Label("Couldn't read projects", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                projectList
                    .frame(width: 260)
                Divider()
                detailArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            FilterField(text: $filter, prompt: "Filter projects", focused: $filterFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            List(selection: $selectedProjectID) {
                ForEach(filteredProjects) { project in
                    Text(project.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.leading, 6)
                        .tag(project.id)
                        .contextMenu { projectContextMenu(project) }
                }
            }
        }
    }

    @ViewBuilder
    private func projectContextMenu(_ project: MunkipkgProject) -> some View {
        Button("Build") {
            selectedProjectID = project.id
            pendingBuildID = project.id
            buildToken += 1
        }
        Button("Reveal in Finder") {
            Workspace.reveal([project.directoryURL])
        }
        Divider()
        Button("Rename…") { startRename(project) }
        Button("Duplicate") { Task { await duplicateProject(project) } }
        Divider()
        Button("Delete…", role: .destructive) { Task { await deleteProject(project) } }
    }

    @ViewBuilder
    private var detailArea: some View {
        if let project = selectedProject {
            BuildProjectDetail(
                project: project,
                autoBuild: pendingBuildID == project.id,
                buildToken: buildToken,
                buildOptions: $buildOptions,
                onBuildConsumed: { pendingBuildID = nil },
                onSaved: { updated in
                    if let index = projects.firstIndex(where: { $0.id == updated.id }) {
                        projects[index] = updated
                    }
                }
            )
            .id(project.id)
        } else {
            ContentUnavailableView("Select a Project", systemImage: "hammer")
        }
    }

    // MARK: data

    /// Honor a pending cross-section selection request: if the store
    /// has a project id queued up (set by Testing-tab double-click,
    /// etc.) and we have a project that matches, select it and clear
    /// the pending id. Runs after `reload()` so the project list is up
    /// to date and we don't drop the request on the first appearance.
    private func consumePendingBuildSelection() {
        guard let pending = store.pendingBuildProjectID else { return }
        if projects.contains(where: { $0.id == pending }) {
            selectedProjectID = pending
            store.pendingBuildProjectID = nil
        }
    }

    private func reload() async {
        guard let folder = projectsFolder else { projects = []; return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            projects = try await store.services.munkipkg.projects(in: folder)
            if selectedProject == nil { selectedProjectID = projects.first?.id }
        } catch {
            loadError = error.localizedDescription
            projects = []
        }
    }

    /// Watch the projects folder so projects added, removed or renamed
    /// on disk show up without a manual refresh.
    private func startWatching() {
        folderWatcher?.cancel()
        folderWatcher = projectsFolder.flatMap { folder in
            DirectoryWatcher(url: folder) {
                Task { await reload() }
            }
        }
    }

    // MARK: project actions

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private func startRename(_ project: MunkipkgProject) {
        renameTarget = project
        renameText = project.name
    }

    private func commitRename() {
        guard let project = renameTarget else { return }
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        renameTarget = nil
        guard !newName.isEmpty, newName != project.name else { return }
        let destination = project.directoryURL.deletingLastPathComponent().appending(path: newName)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        do {
            try FileManager.default.moveItem(at: project.directoryURL, to: destination)
        } catch {
            loadError = "Couldn't rename \"\(project.name)\": \(error.localizedDescription)"
            return
        }
        Task {
            await reload()
            selectedProjectID = projectID(matching: destination)
        }
    }

    /// Resolve a freshly created/renamed project to its `id` from the
    /// reloaded list — `URL.path` can differ from a project's stored id
    /// (percent-escapes, symlinks, trailing slash), so match on the
    /// standardized directory URL rather than assuming the paths agree.
    private func projectID(matching directory: URL) -> String? {
        projects.first {
            $0.directoryURL.standardizedFileURL == directory.standardizedFileURL
        }?.id
    }

    private func duplicateProject(_ project: MunkipkgProject) async {
        let parent = project.directoryURL.deletingLastPathComponent()
        var destination = parent.appending(path: "\(project.name) copy")
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = parent.appending(path: "\(project.name) copy \(index)")
            index += 1
        }
        do {
            try FileManager.default.copyItem(at: project.directoryURL, to: destination)
        } catch {
            loadError = "Couldn't duplicate \"\(project.name)\": \(error.localizedDescription)"
            return
        }
        await reload()
        selectedProjectID = projectID(matching: destination)
    }

    private func deleteProject(_ project: MunkipkgProject) async {
        deleteTarget = project
    }

    private func performDeleteProject(_ project: MunkipkgProject) async {
        deleteTarget = nil
        do {
            try FileManager.default.removeItem(at: project.directoryURL)
        } catch {
            loadError = "Couldn't delete \"\(project.name)\": \(error.localizedDescription)"
            return
        }
        if selectedProjectID == project.id { selectedProjectID = nil }
        await reload()
    }
}

// MARK: - Layout measurement

/// Reports the scripts column's intrinsic height so the payload column
/// can match it.
private struct ScriptsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the payload tree's natural content height so the section can
/// decide whether an Expand button is warranted.
private struct PayloadContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the payload tree-box's visible height — compared against the
/// content height to decide whether the tree overflows.
private struct PayloadBoxHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Project detail

/// Build-info on top in three columns; payload and scripts in a 50/50
/// split underneath. An always-visible build action bar sits on top.
private struct BuildProjectDetail: View {
    let project: MunkipkgProject
    let autoBuild: Bool
    let buildToken: Int
    let onBuildConsumed: () -> Void
    let onSaved: (MunkipkgProject) -> Void

    @Environment(RepositoryStore.self) private var store

    @Binding var buildOptions: MunkipkgBuildOptions
    @State private var buildInfo: BuildInfo
    @State private var format: BuildInfoFormat
    @State private var building = false
    @State private var buildLog: [String] = []
    @State private var builtPackageURL: URL?
    @State private var statusMessage: String?
    @State private var scriptsHeight: CGFloat = 560
    @State private var payloadExpanded = false
    @State private var showBuildOptions = false
    @State private var pickingEnvFile = false

    init(
        project: MunkipkgProject,
        autoBuild: Bool,
        buildToken: Int,
        buildOptions: Binding<MunkipkgBuildOptions>,
        onBuildConsumed: @escaping () -> Void,
        onSaved: @escaping (MunkipkgProject) -> Void
    ) {
        self.project = project
        self.autoBuild = autoBuild
        self.buildToken = buildToken
        self._buildOptions = buildOptions
        self.onBuildConsumed = onBuildConsumed
        self.onSaved = onSaved
        _buildInfo = State(initialValue: project.buildInfo)
        _format = State(initialValue: project.buildInfoFormat)
    }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            if building || !buildLog.isEmpty { buildConsole }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    buildInfoSection
                    payloadAndScripts
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: buildToken) {
            if autoBuild {
                await runBuild()
                onBuildConsumed()
            }
        }
        .task(id: buildInfo) { await autoSave() }
        .task(id: format) { await autoSave() }
        .onDisappear { Task { await persist() } }
    }

    // MARK: action bar + console

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(project.name).font(.headline)
                Spacer()
                if building { ProgressView().controlSize(.small) }
                if let builtPackageURL {
                    Button {
                        Workspace.reveal([builtPackageURL])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        store.pendingImportURLs = [builtPackageURL]
                        store.selectedSection = .importer
                    } label: {
                        Label("Import into Repo", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    showBuildOptions = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .help("Build options")
                .popover(isPresented: $showBuildOptions, arrowEdge: .bottom) {
                    buildOptionsPopover
                }
                Button {
                    Task { await runBuild() }
                } label: {
                    Label("Build Package", systemImage: "hammer.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(building)
            }
            .controlSize(.large)
            if let statusMessage {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var buildOptionsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Build Options").font(.headline)
            optionToggle(
                "Export Bom.txt",
                "Write the package Bill-of-Materials into the project for git tracking.",
                $buildOptions.exportBomInfo
            )
            optionToggle(
                "Skip notarization",
                "Build without notarizing, even when build-info defines notarization.",
                $buildOptions.skipNotarization
            )
            optionToggle(
                "Skip stapling",
                "Notarize but don't staple the ticket onto the package.",
                $buildOptions.skipStapling
            )
            optionToggle(
                "Skip import prompt",
                "Don't prompt to munkiimport the built package afterwards.",
                $buildOptions.skipImport
            )
            optionToggle(
                "Quiet",
                "Suppress munkipkg status output — errors are still shown.",
                $buildOptions.quiet
            )
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(".env file").font(.callout.weight(.medium))
                Text("Environment variables injected into scripts. Leave blank to auto-detect a .env in the project.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Auto-detect", text: $buildOptions.envPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { pickingEnvFile = true }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .fileImporter(
            isPresented: $pickingEnvFile,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                buildOptions.envPath = url.path
            }
        }
    }

    private func optionToggle(_ title: String, _ caption: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(caption)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }


    private var buildConsole: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Build Output")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { buildLog = [] }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(buildLog.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(height: 200)
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: buildLog.count) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: payload + scripts

    private var payloadAndScripts: some View {
        HStack(alignment: .top, spacing: 20) {
            PayloadSection(
                project: project,
                availableHeight: scriptsHeight,
                expanded: $payloadExpanded
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)

            BuildScriptsSection(project: project)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ScriptsHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .onPreferenceChange(ScriptsHeightKey.self) { scriptsHeight = $0 }
    }

    // MARK: build-info form — three columns, left-aligned

    private var buildInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Build Info").font(.title3.weight(.semibold))
                Spacer()
                Picker("", selection: $format) {
                    ForEach(BuildInfoFormat.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("On-disk format of the build-info file")
            }
            HStack(alignment: .top, spacing: 20) {
                packageGroup
                    .frame(maxWidth: .infinity, alignment: .leading)
                optionsGroup
                    .fixedSize(horizontal: true, vertical: false)
                signingGroup
                    .frame(maxWidth: .infinity, alignment: .leading)
                notarizationGroup
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var packageGroup: some View {
        group("Package") {
            row("Output name") { textField($buildInfo.name, prompt: "Example") }
            row("Identifier") { textField($buildInfo.identifier, prompt: "com.example.pkg") }
            row("Version") { textField($buildInfo.version, prompt: "1.0") }
            row("Install location") { textField($buildInfo.installLocation, prompt: "/") }
            row("Product ID") { textField($buildInfo.productID, prompt: "Optional") }
        }
    }

    private var optionsGroup: some View {
        group("Options") {
            row("Ownership") {
                Picker("", selection: $buildInfo.ownership) {
                    Text("Recommended").tag("recommended")
                    Text("Preserve").tag("preserve")
                    Text("Preserve other").tag("preserve-other")
                }
                .labelsHidden().fixedSize()
            }
            row("Post-install") {
                Picker("", selection: $buildInfo.postinstallAction) {
                    Text("None").tag("none")
                    Text("Log out").tag("logout")
                    Text("Restart").tag("restart")
                }
                .labelsHidden().fixedSize()
            }
            toggleRow("Distribution-style package", $buildInfo.distributionStyle)
            toggleRow("Preserve extended attributes", $buildInfo.preserveXattr)
            toggleRow("Suppress bundle relocation", $buildInfo.suppressBundleRelocation)
        }
    }

    private var signingGroup: some View {
        group("Code signing") {
            toggleRow("Sign this package", signingEnabled)
            if buildInfo.signingInfo != nil {
                row("Identity") { textField(signingBinding(\.identity, default: ""), prompt: "Developer ID Installer: …") }
                row("Keychain") { textField(signingBinding(\.keychain, default: ""), prompt: "Optional") }
                toggleRow("Secure timestamp", signingBinding(\.timestamp, default: true))
            }
        }
    }

    private var notarizationGroup: some View {
        group("Notarization") {
            toggleRow("Notarize this package", notarizationEnabled)
            if buildInfo.notarizationInfo != nil {
                row("Keychain profile") { textField(notarizationBinding(\.keychainProfile, default: ""), prompt: "notarytool profile") }
                row("Apple ID") { textField(notarizationBinding(\.appleID, default: ""), prompt: "Optional") }
                row("Team ID") { textField(notarizationBinding(\.teamID, default: ""), prompt: "Optional") }
            }
        }
    }

    // MARK: row helpers — label left, control left

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 8) { content() }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func toggleRow(_ label: String, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            Text(label).font(.callout)
            Spacer(minLength: 0)
        }
    }

    private func textField(_ text: Binding<String>, prompt: String) -> some View {
        TextField("", text: text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
    }

    // MARK: optional-struct bindings

    private var signingEnabled: Binding<Bool> {
        Binding(
            get: { buildInfo.signingInfo != nil },
            set: { buildInfo.signingInfo = $0 ? (buildInfo.signingInfo ?? .init()) : nil }
        )
    }

    private func signingBinding<T>(
        _ keyPath: WritableKeyPath<BuildInfo.SigningInfo, T>,
        default fallback: T
    ) -> Binding<T> {
        Binding(
            get: { buildInfo.signingInfo?[keyPath: keyPath] ?? fallback },
            set: {
                var info = buildInfo.signingInfo ?? .init()
                info[keyPath: keyPath] = $0
                buildInfo.signingInfo = info
            }
        )
    }

    private var notarizationEnabled: Binding<Bool> {
        Binding(
            get: { buildInfo.notarizationInfo != nil },
            set: { buildInfo.notarizationInfo = $0 ? (buildInfo.notarizationInfo ?? .init()) : nil }
        )
    }

    private func notarizationBinding<T>(
        _ keyPath: WritableKeyPath<BuildInfo.NotarizationInfo, T>,
        default fallback: T
    ) -> Binding<T> {
        Binding(
            get: { buildInfo.notarizationInfo?[keyPath: keyPath] ?? fallback },
            set: {
                var info = buildInfo.notarizationInfo ?? .init()
                info[keyPath: keyPath] = $0
                buildInfo.notarizationInfo = info
            }
        )
    }

    // MARK: actions

    /// Debounced auto-save — fired by `.task(id:)` whenever `buildInfo`
    /// or `format` changes. A fresh edit cancels the pending save.
    private func autoSave() async {
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled else { return }
        await persist()
    }

    /// Write `build-info` to disk if it differs from what's on disk.
    private func persist() async {
        guard buildInfo != project.buildInfo || format != project.buildInfoFormat else { return }
        do {
            try await store.services.munkipkg.saveBuildInfo(buildInfo, to: project, format: format)
            onSaved(MunkipkgProject(
                directoryURL: project.directoryURL,
                buildInfo: buildInfo,
                buildInfoFormat: format,
                scripts: project.scripts,
                hasPayload: project.hasPayload
            ))
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func runBuild() async {
        await persist()
        building = true
        buildLog = []
        builtPackageURL = nil
        statusMessage = nil
        defer { building = false }
        do {
            for try await event in store.services.munkipkg.build(project, options: buildOptions) {
                switch event {
                case .line(let line):
                    buildLog.append(line)
                case .finished(let exitCode, let productURL):
                    if exitCode == 0, let productURL {
                        builtPackageURL = productURL
                        statusMessage = "Build succeeded — \(productURL.lastPathComponent)"
                    } else {
                        statusMessage = "munkipkg exited with code \(exitCode)."
                    }
                }
            }
        } catch {
            statusMessage = "Build failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Scripts

/// preinstall + postinstall (and any extras) — always shows both
/// canonical slots, the way pkginfo script slots work.
private struct BuildScriptsSection: View {
    let project: MunkipkgProject

    private var slots: [MunkipkgScript] {
        let directory = project.directoryURL.appending(path: "scripts")
        var names = ["preinstall", "postinstall"]
        for script in project.scripts where !names.contains(script.name) {
            names.append(script.name)
        }
        return names.map { MunkipkgScript(name: $0, fileURL: directory.appending(path: $0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scripts").font(.title3.weight(.semibold))
            ForEach(slots) { script in
                BuildScriptSlot(script: script)
            }
        }
    }
}

/// One munkipkg script slot — loads its file (or starts empty), edits
/// in the shared `ScriptEditor`, and saves it back as executable.
private struct BuildScriptSlot: View {
    let script: MunkipkgScript

    @Environment(RepositoryStore.self) private var store

    @State private var text = ""
    @State private var original = ""
    @State private var loaded = false
    @State private var fullScreenPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(script.name).font(.headline)
                Spacer()
                Button {
                    fullScreenPresented = true
                } label: {
                    Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .controlSize(.small)
                .help("Open full-screen editor with linter and line numbers")
            }
            .frame(height: 32)
            ScriptEditor(label: "", text: $text, editorHeight: 240, showsHeader: false)
        }
        .sheet(isPresented: $fullScreenPresented) {
            ScriptEditorSheet(title: script.name, text: $text)
        }
        .task {
            text = (try? await store.services.munkipkg.readScript(script)) ?? ""
            original = text
            loaded = true
        }
        .task(id: text) { await autoSave() }
        .onDisappear {
            guard loaded, text != original else { return }
            let contents = text
            Task { try? await store.services.munkipkg.writeScript(script, contents: contents) }
        }
    }

    /// Debounced auto-save — a fresh keystroke cancels the pending write.
    private func autoSave() async {
        guard loaded, text != original else { return }
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled, text != original else { return }
        try? await store.services.munkipkg.writeScript(script, contents: text)
        original = text
    }
}

// MARK: - Payload

/// A node in the project's `payload/` tree.
private struct PayloadNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var children: [PayloadNode]?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

private enum PayloadAction {
    case newFolder, addFiles, reveal, rename, delete, edit
}

/// Plain-text file extensions the payload browser opens in the in-app
/// editor — the same sheet the script slots use.
private let payloadTextExtensions: Set<String> = [
    "sh", "bash", "zsh", "command", "py", "rb", "pl", "php", "lua",
    "js", "ts", "swift", "c", "h", "cpp", "cc", "m", "mm", "go", "rs",
    "md", "markdown", "txt", "text", "log", "applescript",
    "json", "yaml", "yml", "xml", "plist", "toml", "csv",
    "conf", "cfg", "ini", "css", "html", "htm",
]

/// Bare dotfile names that are editable text — these report an empty
/// `pathExtension`, so the extension set above never matches them.
private let payloadTextDotfiles: Set<String> = [
    ".env", ".gitignore", ".gitattributes", ".bashrc", ".bash_profile",
    ".zshrc", ".zprofile", ".profile", ".editorconfig",
]

private func isPayloadTextFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    if !ext.isEmpty { return payloadTextExtensions.contains(ext) }
    return payloadTextDotfiles.contains(url.lastPathComponent.lowercased())
}

/// Recursively read a payload directory into `PayloadNode`s. Free and
/// `nonisolated` so it can run on a detached task — the walk is pure
/// file I/O and never touches view state.
private func buildPayloadTree(at directory: URL) -> [PayloadNode] {
    let fileManager = FileManager.default
    let entries = (try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []
    return entries
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        .map { url in
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return PayloadNode(
                url: url,
                isDirectory: isDirectory.boolValue,
                children: isDirectory.boolValue ? buildPayloadTree(at: url) : nil
            )
        }
}

/// File browser for the project's `payload/` — the literal tree that
/// becomes the package's content. Add / remove / rename files, or drag
/// them in from Finder. Collapsed to match the scripts column; an
/// Expand button reveals the rest when the tree overflows.
private struct PayloadSection: View {
    let project: MunkipkgProject
    let availableHeight: CGFloat
    @Binding var expanded: Bool

    @State private var nodes: [PayloadNode] = []
    @State private var selection: String?
    @State private var renameNode: PayloadNode?
    @State private var renameText = ""
    @State private var deleteNode: PayloadNode?
    @State private var addFilesTarget: AddFilesTarget?

    private struct AddFilesTarget: Identifiable {
        let id = UUID()
        let directory: URL
    }
    @State private var contentHeight: CGFloat = 0
    @State private var boxHeight: CGFloat = 0
    @State private var editingURL: URL?
    @State private var editingText = ""
    @State private var editingOriginal = ""
    @State private var editingPermissions: Int?
    @State private var watcher: RecursiveDirectoryWatcher?

    private var payloadURL: URL { project.directoryURL.appending(path: "payload") }

    /// The tree overflows its box when its content is taller than the
    /// visible area — the cue to offer an Expand button.
    private var overflowing: Bool { contentHeight > boxHeight + 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Payload").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                buttonsRow
                treeBox
                if overflowing || expanded {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                    } label: {
                        Label(expanded ? "Collapse" : "Expand",
                              systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.callout)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .frame(height: expanded ? nil : availableHeight, alignment: .top)
        .onAppear {
            reloadTree()
            watcher = RecursiveDirectoryWatcher(url: payloadURL) { reloadTree() }
        }
        .onDisappear {
            watcher?.cancel()
            watcher = nil
        }
        .alert("Rename", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renameNode = nil }
        }
        .alert("Delete from payload?", isPresented: deletePresented, presenting: deleteNode) { node in
            Button("Delete", role: .destructive) {
                performDelete(node)
            }
            Button("Cancel", role: .cancel) { deleteNode = nil }
        } message: { node in
            Text("\u{201c}\(node.name)\u{201d} will be removed from the payload on disk.")
        }
        .sheet(isPresented: editingPresented) {
            ScriptEditorSheet(title: editingURL?.lastPathComponent ?? "", text: $editingText)
        }
        .fileImporter(
            isPresented: addFilesPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            receiveAddFilesResult(result)
        }
    }

    private var buttonsRow: some View {
        HStack(spacing: 6) {
            Button { newFolder(in: nil) } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("New Folder")
            Button { addFiles(to: nil) } label: {
                Image(systemName: "doc.badge.plus")
            }
            .help("Add Files…")
            Button { deleteSelection() } label: {
                Image(systemName: "trash")
            }
            .help("Delete")
            .disabled(selection == nil)
            Button {
                Workspace.reveal([payloadURL])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .help("Reveal in Finder")
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(height: 32)
    }

    @ViewBuilder
    private var treeBox: some View {
        Group {
            if expanded {
                treeContent
            } else {
                ScrollView { treeContent }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: expanded ? nil : .infinity, alignment: .topLeading)
        .background {
            GeometryReader { proxy in
                Color(nsColor: .textBackgroundColor)
                    .preference(key: PayloadBoxHeightKey.self, value: proxy.size.height)
            }
        }
        .clipShape(.rect(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .dropDestination(for: URL.self) { urls, _ in
            importDropped(urls)
            return !urls.isEmpty
        }
        .onPreferenceChange(PayloadContentHeightKey.self) { contentHeight = $0 }
        .onPreferenceChange(PayloadBoxHeightKey.self) { boxHeight = $0 }
    }

    private var treeContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            if nodes.isEmpty {
                Text("Drag files and folders here, or use the buttons above — they become the package's content.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } else {
                ForEach(nodes) { node in
                    PayloadTreeRow(node: node, depth: 0, selection: $selection, perform: perform)
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PayloadContentHeightKey.self, value: proxy.size.height)
            }
        )
    }

    // MARK: actions

    private func perform(_ action: PayloadAction, on node: PayloadNode) {
        switch action {
        case .newFolder: newFolder(in: node)
        case .addFiles: addFiles(to: node)
        case .reveal: Workspace.reveal([node.url])
        case .rename: renameNode = node; renameText = node.name
        case .delete: delete(node)
        case .edit: beginEditing(node)
        }
    }

    // MARK: in-app text editing

    private var editingPresented: Binding<Bool> {
        Binding(get: { editingURL != nil }, set: { if !$0 { commitEdit() } })
    }

    private func beginEditing(_ node: PayloadNode) {
        guard !node.isDirectory,
              let data = try? Data(contentsOf: node.url) else { return }
        // Refuse to edit non-UTF-8 content as text — a lossy decode
        // would write U+FFFD replacements back over a binary plist,
        // a Latin-1 config, etc. Hand those to the system editor.
        guard let text = String(data: data, encoding: .utf8) else {
            Workspace.open(node.url)
            return
        }
        editingText = text
        editingOriginal = text
        // Remember the file's mode — an atomic write replaces the inode,
        // so the executable bit on a staged helper/script would be lost
        // unless we restore it on save.
        editingPermissions = (try? FileManager.default.attributesOfItem(atPath: node.url.path))
            .flatMap { $0[.posixPermissions] as? NSNumber }?.intValue
        editingURL = node.url
    }

    private func commitEdit() {
        if let url = editingURL, editingText != editingOriginal {
            try? editingText.write(to: url, atomically: true, encoding: .utf8)
            if let mode = editingPermissions {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: mode)],
                    ofItemAtPath: url.path
                )
            }
        }
        editingURL = nil
        editingPermissions = nil
    }

    /// Directory new items land in — the given folder (or the selection
    /// when none is passed), a file's parent, else the payload root.
    private func destination(for node: PayloadNode?) -> URL {
        let target = node ?? selection.flatMap { findNode($0, in: nodes) }
        guard let target else { return payloadURL }
        return target.isDirectory ? target.url : target.url.deletingLastPathComponent()
    }

    private func newFolder(in node: PayloadNode?) {
        let directory = destination(for: node)
        var url = directory.appending(path: "New Folder")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "New Folder \(index)")
            index += 1
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        reloadTree()
    }

    private func addFiles(to node: PayloadNode?) {
        addFilesTarget = AddFilesTarget(directory: destination(for: node))
    }

    private func receiveAddFilesResult(_ result: Result<[URL], any Error>) {
        defer { addFilesTarget = nil }
        guard let target = addFilesTarget,
              case .success(let urls) = result else { return }
        for source in urls {
            try? FileManager.default.copyItem(
                at: source,
                to: target.directory.appending(path: source.lastPathComponent)
            )
        }
        reloadTree()
    }

    private var addFilesPresented: Binding<Bool> {
        Binding(get: { addFilesTarget != nil }, set: { if !$0 { addFilesTarget = nil } })
    }

    private func importDropped(_ urls: [URL]) {
        let directory = destination(for: nil)
        for url in urls {
            try? FileManager.default.copyItem(
                at: url,
                to: directory.appending(path: url.lastPathComponent)
            )
        }
        reloadTree()
    }

    private func deleteSelection() {
        guard let selection, let node = findNode(selection, in: nodes) else { return }
        delete(node)
    }

    private func delete(_ node: PayloadNode) {
        deleteNode = node
    }

    private func performDelete(_ node: PayloadNode) {
        deleteNode = nil
        try? FileManager.default.removeItem(at: node.url)
        if selection == node.id { selection = nil }
        reloadTree()
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteNode != nil }, set: { if !$0 { deleteNode = nil } })
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameNode != nil }, set: { if !$0 { renameNode = nil } })
    }

    private func commitRename() {
        guard let node = renameNode else { return }
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        renameNode = nil
        guard !newName.isEmpty, newName != node.name else { return }
        let destination = node.url.deletingLastPathComponent().appending(path: newName)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try? FileManager.default.moveItem(at: node.url, to: destination)
        reloadTree()
    }

    // MARK: tree

    private func reloadTree() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: payloadURL.path) {
            try? fileManager.createDirectory(at: payloadURL, withIntermediateDirectories: true)
        }
        // Walk the payload off the main actor — an app-bundle payload
        // can hold thousands of files, and reloadTree fires on every
        // FSEvent burst. Publishing `nodes` hops back to the main actor.
        let root = payloadURL
        Task {
            nodes = await Task.detached { buildPayloadTree(at: root) }.value
        }
    }

    private func findNode(_ id: String, in nodes: [PayloadNode]) -> PayloadNode? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children, let found = findNode(id, in: children) {
                return found
            }
        }
        return nil
    }
}

/// One row of the payload outline. Folders default to expanded and draw
/// their children recursively; every row carries the standard file
/// context menu.
private struct PayloadTreeRow: View {
    let node: PayloadNode
    let depth: Int
    @Binding var selection: String?
    let perform: (PayloadAction, PayloadNode) -> Void

    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            rowContent
            if expanded, let children = node.children {
                ForEach(children) { child in
                    PayloadTreeRow(node: child, depth: depth + 1, selection: $selection, perform: perform)
                }
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 5) {
            if node.isDirectory {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .contentShape(.rect)
                    .onTapGesture { expanded.toggle() }
            } else {
                Color.clear.frame(width: 12)
            }
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(node.name).font(.callout).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.leading, CGFloat(depth) * 16 + 4)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selection == node.id ? Color.accentColor.opacity(0.18) : Color.clear,
            in: .rect(cornerRadius: 4)
        )
        .contentShape(.rect)
        // Single-tap selects; double-tap opens. The count:1 handler is
        // attached first so SwiftUI delivers selection immediately
        // instead of stalling for the double-click interval.
        .onTapGesture { selection = node.id }
        .onTapGesture(count: 2) {
            if node.isDirectory {
                expanded.toggle()
            } else if isPayloadTextFile(node.url) {
                perform(.edit, node)
            } else {
                Workspace.open(node.url)
            }
        }
        .contextMenu {
            if node.isDirectory {
                Button("New Folder") { perform(.newFolder, node) }
                Button("Add Files…") { perform(.addFiles, node) }
            } else {
                if isPayloadTextFile(node.url) {
                    Button("Edit") { perform(.edit, node) }
                }
                Button("Open") { Workspace.open(node.url) }
                let apps = Workspace.applications(toOpen: node.url)
                if !apps.isEmpty {
                    Menu("Open With") {
                        ForEach(apps, id: \.self) { app in
                            Button(FileManager.default.displayName(atPath: app.path)) {
                                Workspace.open([node.url], with: app)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Rename…") { perform(.rename, node) }
            Button("Reveal in Finder") { perform(.reveal, node) }
            Divider()
            Button("Delete", role: .destructive) { perform(.delete, node) }
        }
    }
}

// MARK: - File-system watchers

/// Watches a single directory for direct-child changes — entries added,
/// removed or renamed. Not recursive: a directory vnode's `.write`
/// event fires only for changes to that directory's own listing.
private final class DirectoryWatcher {
    private var source: (any DispatchSourceFileSystemObject)?

    init?(url: URL, onChange: @escaping () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }
}

/// Watches a directory tree recursively via FSEvents — used for a
/// package payload, where files can land at any depth.
private final class RecursiveDirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<RecursiveDirectoryWatcher>.fromOpaque(info)
                .takeUnretainedValue()
                .onChange()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func cancel() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { cancel() }
}
