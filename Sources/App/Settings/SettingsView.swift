import SwiftUI
import Core

/// Content of the Preferences window (Cmd-,). A `TabView` so each future
/// feature can contribute its own pane without restructuring this view.
struct SettingsView: View {
    var body: some View {
        // One tab per feature, matching Git and Build. "Features" used to
        // bundle Promoter and Profiles together while those two got their
        // own tabs, so where a setting lived was inconsistent.
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            GitSettingsView()
                .tabItem { Label("Git", systemImage: "arrow.triangle.branch") }
            BuildSettingsView()
                .tabItem { Label("Build", systemImage: "hammer") }
            PromoterSettingsView()
                .tabItem { Label("Promoter", systemImage: "arrow.up.forward.square") }
            ProfilesSettingsView()
                .tabItem { Label("Profiles", systemImage: "doc.badge.gearshape") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
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
            } footer: {
                Text("The Promoter tab shows a preview of recent AutoPkg imports, upcoming promotions, and promoter history — and lets you approve, anticipate, or defer individual items. \"Hidden catalogs\" suppresses catalog names from transition labels and stats without changing which catalogs the promoter actually writes to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(minHeight: 260)
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
            } footer: {
                Text("The Profiles tab lists every .mobileconfig under this folder, expanded by default, and opens an XML editor with live validation for each.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(minHeight: 260)
    }
}

// MARK: - Build

private struct BuildSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RepositoryStore.self) private var store

    @State private var installedTool: InstalledPackagingTool?
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
                Text("Package Projects")
            } footer: {
                Text("The Build tab lists package-source projects directly under this folder — each a directory with a build-info file and a payload. The layout is the same for swiftpkg and munkipkg.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Status") {
                    if checking {
                        ProgressView().controlSize(.small)
                    } else if let installedTool {
                        Label(installedTool.displayLabel, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not found", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if let installedTool {
                    LabeledContent("Path", value: installedTool.executablePath)
                }
                HStack {
                    TextField("Executable", text: $settings.munkipkgExecutablePath,
                              prompt: Text("Auto-detect"))
                    PathChooserButton.file(types: [.unixExecutable, .executable], path: $settings.munkipkgExecutablePath)
                }
                HStack {
                    Button("Install swiftpkg") { Task { await install(.swiftpkg) } }
                        .disabled(installing)
                    Button("Install munkipkg") { Task { await install(.munkipkg) } }
                        .disabled(installing)
                    if installing { ProgressView().controlSize(.small) }
                    if let installMessage {
                        Text(installMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Packaging Tool")
            } footer: {
                Text("The Build tab drives swiftpkg or munkipkg — they share the same project layout, so either builds the same sources. Leave Executable blank to auto-detect: swiftpkg first, then munkipkg. Set it to pick a specific binary; the tool is identified by its filename so the right command form is used (swiftpkg builds with `swiftpkg <project>`, munkipkg with `munkipkg --build <project>`). --env and import-suppression are munkipkg-only and are omitted for swiftpkg.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(minHeight: 360)
        .task(id: settings.munkipkgExecutablePath) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refreshStatus()
        }
    }

    private func refreshStatus() async {
        checking = true
        installedTool = await store.services.munkipkg.installedTool()
        checking = false
    }

    private func install(_ tool: PackagingTool) async {
        installing = true
        installMessage = nil
        defer { installing = false }
        do {
            try await store.services.munkipkg.installLatest(tool)
            // Installed at the tool's standard path — drop any custom
            // override so detection picks the freshly installed binary.
            settings.munkipkgExecutablePath = ""
            installMessage = "Installed \(tool.displayName) to \(tool.defaultExecutablePath)."
            await refreshStatus()
        } catch {
            installMessage = error.localizedDescription
        }
    }

}

// MARK: - General

private struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RepositoryStore.self) private var store

    @State private var confirmingReset = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Reopen last repository on launch", isOn: $settings.reopenLastRepositoryOnLaunch)
                LabeledContent("Version", value: AppInfo.version)
            }

            Section {
                Button("Run Setup Again\u{2026}") { replayOnboarding() }
                Button("Reset All Settings\u{2026}", role: .destructive) {
                    confirmingReset = true
                }
                if AppDefaults.isSandbox() {
                    Label(
                        "Sandbox mode — settings live in a throwaway suite that is wiped every launch.",
                        systemImage: "flask"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("Setup")
            } footer: {
                Text("Run Setup Again reopens the first-run wizard without changing anything you've already configured. Reset All Settings clears every MunkiStudio preference and the Recent list, returning the app to a fresh install — it never touches your repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(minHeight: 260)
        .confirmationDialog(
            "Reset all MunkiStudio settings?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset Everything", role: .destructive) { resetEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears every preference and the Recent list, then reopens the setup wizard. Your Munki repository is left untouched.")
        }
    }

    /// Reopen the wizard over the main window. The Settings window is
    /// closed first — otherwise the sheet raises behind it and looks
    /// like the button did nothing.
    private func replayOnboarding() {
        store.isShowingOnboarding = true
        NSApp.keyWindow?.performClose(nil)
    }

    private func resetEverything() {
        settings.resetToDefaults()
        store.clearRecents()
        replayOnboarding()
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
        .frame(minHeight: 160)
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
