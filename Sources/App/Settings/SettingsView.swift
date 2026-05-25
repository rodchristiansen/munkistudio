import SwiftUI
import Core
import Infra

/// Content of the Preferences window (Cmd-,). Each feature gets its
/// own tab so settings stay grouped with what they actually affect.
/// Every pane shares ``Self/paneMinHeight`` so the window doesn't
/// jump around when switching between short tabs (General, Git) and
/// tall ones (Testing) — width is fixed too.
struct SettingsView: View {
    /// Height matches the tallest pane (Testing) so the window stays
    /// the same size across tabs.
    static let paneMinHeight: CGFloat = 520

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            PromoterSettingsView()
                .tabItem { Label("Promoter", systemImage: "arrow.up.forward.app") }
            ProfilesSettingsView()
                .tabItem { Label("Profiles", systemImage: "doc.text") }
            TestingSettingsView()
                .tabItem { Label("Testing", systemImage: "checkmark.seal") }
            GitSettingsView()
                .tabItem { Label("Git", systemImage: "arrow.triangle.branch") }
            BuildSettingsView()
                .tabItem { Label("Build", systemImage: "hammer") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560)
    }
}

// MARK: - Promoter

private struct PromoterSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Enable Promoter tab", isOn: $settings.enablePromoterTab)
                HStack {
                    TextField("Deployment folder", text: $settings.autopkgDeploymentPath,
                              prompt: Text("Folder containing promoter.yml"))
                    PathChooserButton.folder(path: $settings.autopkgDeploymentPath)
                }
                .disabled(!settings.enablePromoterTab)
                TextField("Hidden catalogs", text: $settings.promoterHiddenCatalogs,
                          prompt: Text("Comma-separated names to hide from display"))
                    .disabled(!settings.enablePromoterTab)
            } header: {
                Text("Promoter")
            } footer: {
                Text("The Promoter tab shows a preview of recent AutoPkg imports, upcoming promotions, and promoter history — and lets you approve, anticipate, or defer individual items. \"Hidden catalogs\" suppresses catalog names from transition labels and stats without changing which catalogs the promoter actually writes to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(minHeight: SettingsView.paneMinHeight)
    }
}

// MARK: - Profiles

private struct ProfilesSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Enable Profiles tab", isOn: $settings.enableProfilesTab)
                HStack {
                    TextField("Profiles folder", text: $settings.profilesDirectoryPath,
                              prompt: Text("Folder of .mobileconfig files"))
                    PathChooserButton.folder(path: $settings.profilesDirectoryPath)
                }
                .disabled(!settings.enableProfilesTab)
            } header: {
                Text("Profiles")
            } footer: {
                Text("The Profiles tab lists every .mobileconfig under this folder, expanded by default, and opens an XML editor with live validation for each.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(minHeight: SettingsView.paneMinHeight)
    }
}

// MARK: - Testing

private struct TestingSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var tartStatus: TartStatus = .checking
    @State private var refreshingTart = false
    @State private var copiedInstallCommand = false
    @State private var isPullingImage = false
    @State private var pullErrorMessage: String?
    @State private var pullSuccessMessage: String?

    private static let installCommand = "brew install cirruslabs/cli/tart"
    private static let recommendedBaseImage = "ghcr.io/cirruslabs/macos-sequoia-base:latest"

    enum TartStatus: Equatable {
        case checking
        case missing
        case present(version: String, path: String)

        var isPresent: Bool {
            if case .present = self { return true }
            return false
        }
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
            Toggle("Enable Testing tab", isOn: $settings.enableTestingTab)
            TextField("Your name", text: $settings.testerName,
                      prompt: Text("Attributed to checklist updates"))
                .disabled(!settings.enableTestingTab)

            Picker("Install environment", selection: $settings.testingEnvironmentRaw) {
                Text("None (skip install steps)").tag("none")
                Text("Host Mac (smoke test only)").tag("host")
                Text("Tart (ephemeral macOS VM)").tag("tart")
            }
            .disabled(!settings.enableTestingTab)

            TextField("Tart base image", text: $settings.tartBaseImage,
                      prompt: Text(Self.recommendedBaseImage))
                .disabled(!settings.enableTestingTab || settings.testingEnvironmentRaw != "tart")

            // Image setup helpers — appear once Tart is installed so a
            // first-time user can fill in the recommended image and
            // kick off the pull without leaving the Settings pane.
            if tartStatus.isPresent && settings.testingEnvironmentRaw == "tart" {
                LabeledContent("Image setup") {
                    HStack(spacing: 8) {
                        Button("Use recommended") {
                            settings.tartBaseImage = Self.recommendedBaseImage
                        }
                        .controlSize(.small)
                        .disabled(settings.tartBaseImage == Self.recommendedBaseImage)

                        if isPullingImage {
                            ProgressView().controlSize(.small)
                            Text("Pulling image — this may take several minutes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Pull image") { Task { await pullBaseImage() } }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                                .disabled(settings.tartBaseImage.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Spacer()
                    }
                }
                if let pullSuccessMessage {
                    LabeledContent("Last pull") {
                        Label(pullSuccessMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
                if let pullErrorMessage {
                    LabeledContent("Pull error") {
                        Text(pullErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }

            TextField("Tart SSH user", text: $settings.tartSSHUser,
                      prompt: Text("admin"))
                .disabled(!settings.enableTestingTab || settings.testingEnvironmentRaw != "tart")

            LabeledContent("Tart status") {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    switch tartStatus {
                    case .checking:
                        ProgressView().controlSize(.small)
                        Text("Checking…").foregroundStyle(.secondary)
                    case .missing:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Not installed").foregroundStyle(.orange)
                    case .present(let version, _):
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(version).foregroundStyle(.green)
                    }
                    if refreshingTart {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Refresh") { Task { await refreshTartStatus() } }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
            }

            if case .missing = tartStatus {
                LabeledContent("Install") {
                    HStack(spacing: 6) {
                        Text(Self.installCommand)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button(action: copyInstallCommand) {
                            Image(systemName: copiedInstallCommand ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help(copiedInstallCommand ? "Copied" : "Copy to clipboard")
                        Spacer()
                        Link("GitHub Releases",
                             destination: URL(string: "https://github.com/cirruslabs/tart/releases")!)
                            .font(.caption)
                    }
                }
            }
            } header: {
                Text("Testing")
            } footer: {
                Text("Phase A/B: pkginfo schema validation, script lint, optional build via munkipkg, build-artifact check, and a repo-local checklist persisted to .munkistudio/testing-checklist.json. Phase C uses Tart to clone an ephemeral macOS guest per install test — Apple's licensing caps macOS guests at 2 concurrent per host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(minHeight: SettingsView.paneMinHeight)
        .task { await refreshTartStatus() }
    }

    @MainActor
    private func refreshTartStatus() async {
        refreshingTart = true
        defer { refreshingTart = false }
        let detector = TartDetector()
        if let path = await detector.locate() {
            let version = await detector.version() ?? "installed"
            tartStatus = .present(version: version, path: path)
            // One-time promotion: when Tart shows up and the env is
            // still at the default "none", flip to "tart" so the user
            // doesn't have to. We don't repeat this — if they switch
            // back to "none" later it stays sticky.
            if !settings.testingEnvironmentAutoFlipped,
               settings.testingEnvironmentRaw == "none" {
                settings.testingEnvironmentRaw = "tart"
                settings.testingEnvironmentAutoFlipped = true
            }
        } else {
            tartStatus = .missing
        }
    }

    /// Pull the configured Tart base image. Runs on a detached task so
    /// the multi-GB transfer doesn't block the Settings UI.
    @MainActor
    private func pullBaseImage() async {
        let image = settings.tartBaseImage.trimmingCharacters(in: .whitespaces)
        guard !image.isEmpty else { return }
        isPullingImage = true
        pullErrorMessage = nil
        pullSuccessMessage = nil
        defer { isPullingImage = false }

        let result: CommandResult? = await Task.detached {
            try? await TartDetector().pullImage(image)
        }.value

        guard let result else {
            pullErrorMessage = "Tart not found on PATH."
            return
        }
        if result.success {
            pullSuccessMessage = "Pulled \(image)."
        } else {
            let tail = result.stderr
                .split(separator: "\n", omittingEmptySubsequences: true)
                .last
                .map(String.init)
                ?? "tart pull exited \(result.exitCode)"
            pullErrorMessage = tail
        }
    }

    /// Drop the install command on the pasteboard and flash a checkmark
    /// in the copy button for two seconds. Sidesteps the Automation
    /// permission dance that scripting Terminal.app would need.
    private func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
        copiedInstallCommand = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copiedInstallCommand = false
        }
    }
}

// MARK: - Build

private struct BuildSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RepositoryStore.self) private var store

    @State private var munkipkgVersion: String?
    @State private var checking = false
    @State private var installing = false
    @State private var installMessage: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                HStack {
                    TextField("Projects folder", text: $settings.munkipkgProjectsPath,
                              prompt: Text("Path to a folder of munkipkg projects"))
                    PathChooserButton.folder(path: $settings.munkipkgProjectsPath)
                }
            } header: {
                Text("munkipkg Projects")
            } footer: {
                Text("The Build tab lists munkipkg package-source projects directly under this folder — each a directory with a build-info file and a payload.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Status") {
                    if checking {
                        ProgressView().controlSize(.small)
                    } else if let munkipkgVersion {
                        Label(munkipkgVersion, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not found", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                HStack {
                    TextField("Executable", text: $settings.munkipkgExecutablePath,
                              prompt: Text("/usr/local/munki/munkipkg"))
                    PathChooserButton.file(types: [.unixExecutable, .executable], path: $settings.munkipkgExecutablePath)
                }
                HStack {
                    Button("Download & Install munkipkg") { Task { await install() } }
                        .disabled(installing)
                    if installing { ProgressView().controlSize(.small) }
                    if let installMessage {
                        Text(installMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("munkipkg Tool")
            } footer: {
                Text("MunkiStudio targets the Swift munkipkg fork — YAML build-info, skip-import, and --env support. Build also works with the stock python munkipkg; the import-suppression flag is auto-detected from --help. Download & Install fetches the latest fork release and installs it to /usr/local/munki (asks for your password). Leave the path blank to use that standard location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(minHeight: SettingsView.paneMinHeight)
        .task(id: settings.munkipkgExecutablePath) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refreshStatus()
        }
    }

    private func refreshStatus() async {
        checking = true
        munkipkgVersion = await store.services.munkipkg.version()
        checking = false
    }

    private func install() async {
        installing = true
        installMessage = nil
        defer { installing = false }
        do {
            try await store.services.munkipkg.installLatest()
            // Installed at the standard path — drop any custom override.
            settings.munkipkgExecutablePath = ""
            installMessage = "Installed to /usr/local/munki/munkipkg."
            await refreshStatus()
        } catch {
            installMessage = error.localizedDescription
        }
    }

}

// MARK: - General

private struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Toggle("Reopen last repository on launch", isOn: $settings.reopenLastRepositoryOnLaunch)
            LabeledContent("Version", value: AppInfo.version)
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(minHeight: SettingsView.paneMinHeight)
    }
}

// MARK: - Git

private struct GitSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Show the Git tab", isOn: $settings.showGitSection)
            } header: {
                Text("Git Tab")
            } footer: {
                Text("The Git tab appears automatically when the open repository is a git working tree. Turn this off to hide it even then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Hooks directory", text: $settings.gitHooksPathOverride,
                          prompt: Text("Auto-detect"))
            } header: {
                Text("Git Hooks")
            } footer: {
                Text("Leave blank to auto-detect — core.hooksPath, then a version-controlled .githooks folder, then the default .git/hooks. Set an absolute or repo-relative path to override.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(minHeight: SettingsView.paneMinHeight)
    }
}

// MARK: - About

private struct AboutSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MunkiStudio").font(.title3).fontWeight(.semibold)
                    Text("Munki software-deployment repository manager")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("github.com/rodchristiansen/munkistudio",
                         destination: URL(string: "https://github.com/rodchristiansen/munkistudio")!)
                        .font(.caption)
                }
            }

            VStack(spacing: 6) {
                labeledInfo("Version", AppInfo.version)
                labeledInfo("Bundle ID", Bundle.main.bundleIdentifier ?? "—")
                labeledInfo("Platform", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                labeledInfo("Swift", "6.2")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Related Projects").font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.secondary).textCase(.uppercase)
                projectRow("ReportMate", "Unified reporting + visibility for Mac + Windows fleets",
                           "https://github.com/reportmate")
                projectRow("BootstrapMate", "Provisioning + bootstrap tooling with a DevOps-first workflow",
                           "https://github.com/bootstrapmate")
                projectRow("Cimian", "Managed software deployment for MSI(X), EXE, NUPKG, and PWSH on Windows",
                           "https://github.com/windowsadmins/cimian")
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Author").font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.secondary).textCase(.uppercase)
                Text("Rod Christiansen").font(.body).fontWeight(.medium)
                Text("Vancouver, BC, Canada")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Managing a fleet of 1000+ computers. Focused on infrastructure, DevOps architecture, CI/CD pipelines, and automating at scale.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    linkRow("GitHub", "github.com/rodchristiansen", "https://github.com/rodchristiansen")
                    linkRow("Blog", "blog.focused.systems", "https://blog.focused.systems")
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func projectRow(_ name: String, _ desc: String, _ urlString: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let url = URL(string: urlString) {
                Link(name, destination: url).font(.callout).fontWeight(.medium)
            } else {
                Text(name).font(.callout).fontWeight(.medium)
            }
            Text(desc).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func linkRow(_ label: String, _ display: String, _ urlString: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.callout).fontWeight(.medium)
            if let url = URL(string: urlString) {
                Link(display, destination: url).font(.caption).foregroundStyle(.blue)
            }
        }
    }

    private func labeledInfo(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value).font(.caption).textSelection(.enabled)
            Spacer()
        }
    }
}

// MARK: - Shared

private enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        if let build, build != short { return "\(short) (\(build))" }
        return short
    }
}
