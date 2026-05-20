import SwiftUI
import AppKit
import Core

/// First-run onboarding wizard. Shown once, over `ContentView`, until the
/// user finishes or skips it (tracked by `AppSettings.hasCompletedOnboarding`).
/// Walks through the munkipkg tool, opening a repository, and the munkipkg
/// projects folder — every step after Welcome is optional.
struct OnboardingView: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case welcome, munkipkg, repository, projectsFolder, profiles
    }

    @State private var step: Step = .welcome
    @State private var munkipkgVersion: String?
    @State private var checkingMunkipkg = false
    @State private var installingMunkipkg = false
    @State private var munkipkgMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                stepContent.padding(32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 580, height: 480)
        .task(id: step) {
            if step == .munkipkg, munkipkgVersion == nil { await refreshMunkipkg() }
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .munkipkg: munkipkgStep
        case .repository: repositoryStep
        case .projectsFolder: projectsFolderStep
        case .profiles: profilesStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 72, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.munkiStudioBrand)
            Text("Welcome to MunkiStudio")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("The Munki repository studio — package, import, edit, lint, commit and deploy, all in one place.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("A few quick steps to get set up.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
    }

    private var munkipkgStep: some View {
        onboardingStep(
            icon: "hammer",
            title: "Set up munkipkg",
            subtitle: "The Build tab uses munkipkg to build packages from source projects. This step is optional — skip it if you don't build packages."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if checkingMunkipkg {
                        ProgressView().controlSize(.small)
                        Text("Checking\u{2026}")
                    } else if let munkipkgVersion {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("munkipkg \(munkipkgVersion) is installed.")
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("munkipkg isn't installed.")
                    }
                }
                .font(.callout)

                if munkipkgVersion == nil && !checkingMunkipkg {
                    Button {
                        Task { await installMunkipkg() }
                    } label: {
                        HStack(spacing: 6) {
                            if installingMunkipkg { ProgressView().controlSize(.small) }
                            Text("Install munkipkg")
                        }
                    }
                    .disabled(installingMunkipkg)
                    Text("Downloads the Swift munkipkg fork and installs it to /usr/local/munki (asks for your password).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let munkipkgMessage {
                    Text(munkipkgMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var repositoryStep: some View {
        onboardingStep(
            icon: "folder",
            title: "Open your Munki repository",
            subtitle: "Choose the root folder of your Munki repo — the one containing pkgsinfo/, pkgs/, catalogs/ and manifests/."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let repo = store.repository {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(repo.displayName).font(.callout.weight(.medium))
                            Text(repo.rootURL.path)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Button(store.repository == nil ? "Open Repository\u{2026}" : "Open a Different Repository\u{2026}") {
                    openRepository()
                }
            }
        }
    }

    private var projectsFolderStep: some View {
        @Bindable var settings = settings
        return onboardingStep(
            icon: "hammer.circle",
            title: "munkipkg projects folder",
            subtitle: "Optional — point MunkiStudio at a folder of munkipkg source projects to enable the Build tab. You can change this any time in Settings."
        ) {
            HStack {
                TextField("Projects folder", text: $settings.munkipkgProjectsPath,
                          prompt: Text("No folder set"))
                    .textFieldStyle(.roundedBorder)
                Button("Choose\u{2026}") { chooseProjectsFolder() }
            }
        }
    }

    private var profilesStep: some View {
        @Bindable var settings = settings
        return onboardingStep(
            icon: "doc.text",
            title: "Profiles tab",
            subtitle: "Optional — manage your folder of .mobileconfig profiles directly in MunkiStudio with an XML editor and live validation. Off by default."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable the Profiles tab", isOn: $settings.enableProfilesTab)
                HStack {
                    TextField("Profiles folder", text: $settings.profilesDirectoryPath,
                              prompt: Text("Folder of .mobileconfig files"))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose\u{2026}") { chooseProfilesFolder() }
                }
                .disabled(!settings.enableProfilesTab)
            }
        }
    }

    @ViewBuilder
    private func onboardingStep<Content: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(Color.munkiStudioBrand)
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            content()
                .padding(.top, 6)
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Back") {
                if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
            }
            .disabled(step == .welcome)

            Spacer()

            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { dot in
                    Circle()
                        .fill(dot == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }

            Spacer()

            if step == .profiles {
                Button("Get Started") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Skip Setup") { finish() }
                Button("Continue") {
                    if let next = Step(rawValue: step.rawValue + 1) { step = next }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: Actions

    private func finish() {
        settings.hasCompletedOnboarding = true
        dismiss()
    }

    private func refreshMunkipkg() async {
        checkingMunkipkg = true
        munkipkgVersion = await store.services.munkipkg.version()
        checkingMunkipkg = false
    }

    private func installMunkipkg() async {
        installingMunkipkg = true
        munkipkgMessage = nil
        defer { installingMunkipkg = false }
        do {
            try await store.services.munkipkg.installLatest()
            munkipkgMessage = "Installed to /usr/local/munki/munkipkg."
            await refreshMunkipkg()
        } catch {
            munkipkgMessage = error.localizedDescription
        }
    }

    private func openRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose the root of your Munki repository."
        if panel.runModal() == .OK, let url = panel.url {
            Task { await store.open(rootURL: url) }
        }
    }

    private func chooseProjectsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.munkipkgProjectsPath = url.path
        }
    }

    private func chooseProfilesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder of .mobileconfig profiles."
        if panel.runModal() == .OK, let url = panel.url {
            settings.profilesDirectoryPath = url.path
        }
    }
}
