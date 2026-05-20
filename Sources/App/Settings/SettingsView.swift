import SwiftUI
import AppKit
import Core

/// Content of the Preferences window (Cmd-,). A `TabView` so each future
/// feature can contribute its own pane without restructuring this view.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            FeatureSettingsView()
                .tabItem { Label("Features", systemImage: "switch.2") }
            GitSettingsView()
                .tabItem { Label("Git", systemImage: "arrow.triangle.branch") }
            BuildSettingsView()
                .tabItem { Label("Build", systemImage: "hammer") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
    }
}

// MARK: - Features

private struct FeatureSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Enable Profiles tab", isOn: $settings.enableProfilesTab)
                HStack {
                    TextField("Profiles folder", text: $settings.profilesDirectoryPath,
                              prompt: Text("Folder of .mobileconfig files"))
                    Button("Choose…") { chooseFolder(into: $settings.profilesDirectoryPath) }
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
        .frame(minHeight: 220)
    }

    private func chooseFolder(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
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
                    Button("Choose…") { chooseFolder(into: $settings.munkipkgProjectsPath) }
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
                    Button("Choose…") { chooseExecutable(into: $settings.munkipkgExecutablePath) }
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
                Text("MunkiStudio targets the Swift munkipkg fork — YAML build-info, --no-import and --env support. Download & Install fetches the latest release from GitHub and installs it to /usr/local/munki (asks for your password). Leave the path blank to use that standard location.")
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

    private func chooseExecutable(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    private func chooseFolder(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
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
        .frame(minHeight: 160)
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
