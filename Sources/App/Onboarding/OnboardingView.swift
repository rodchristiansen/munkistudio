import SwiftUI
import UniformTypeIdentifiers
import Core

/// First-run onboarding wizard. Shown once, over `ContentView`, until the
/// user finishes or skips it (tracked by `AppSettings.hasCompletedOnboarding`).
///
/// It walks every surface a new install has to configure: the repository,
/// the munkipkg tool and its projects folder, and the two opt-in tabs
/// (Promoter, Profiles) plus Git. Only the repository step is required —
/// each later step can be passed straight through.
///
/// Nothing here writes a path on the user's behalf. Every field is
/// pre-filled from whatever is already configured and only changes when
/// the user actively edits or picks, so re-running setup on a working
/// install can't clobber it.
struct OnboardingView: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// Repository comes before the tooling steps on purpose: opening a
    /// repo is the one thing the app can't work without, and everything
    /// after it is optional. A user who bails out halfway still ends up
    /// with a working install.
    /// Promoter goes last: it is the least common setup (it needs an
    /// AutoPkg deployment folder) and the most likely to be skipped, so
    /// it shouldn't stand between the user and the steps that matter.
    enum Step: Int, CaseIterable {
        case welcome, repository, munkipkg, profiles, git, promoter
    }

    @State private var step: Step = .welcome
    @State private var munkipkgVersion: String?
    @State private var checkingMunkipkg = false
    @State private var installingMunkipkg = false
    @State private var munkipkgMessage: String?
    @State private var pickingRepository = false

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
        .fileImporter(
            isPresented: $pickingRepository,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handlePickerResult(result)
        }
        .task(id: step) {
            if step == .munkipkg, munkipkgVersion == nil { await refreshMunkipkg() }
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .repository: repositoryStep
        case .munkipkg: munkipkgStep
        case .profiles: profilesStep
        case .git: gitStep
        case .promoter: promoterStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            AppIconView(size: 96)
            Text("Welcome to MunkiStudio")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("The Munki repository studio — package, import, edit, lint, commit and deploy, all in one place.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("A few quick steps to get set up. Only the repository is required — everything after it can be skipped and configured later in Settings.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
    }

    private var munkipkgStep: some View {
        @Bindable var settings = settings
        return onboardingStep(
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

                Divider().padding(.vertical, 2)

                Text("Projects folder")
                    .font(.callout.weight(.medium))
                HStack {
                    TextField(
                        "Projects folder",
                        text: $settings.munkipkgProjectsPath,
                        prompt: Text("Folder of munkipkg projects")
                    )
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    PathChooserButton.folder(path: $settings.munkipkgProjectsPath)
                }
                folderStatus(
                    path: settings.munkipkgProjectsPath,
                    emptyHint: "Optional — the Build tab stays empty until this is set.",
                    describe: { url in
                        let count = Self.subdirectoryCount(of: url) { $0.appending(path: "build-info.plist") }
                        return count == 0
                            ? "No munkipkg projects found directly under this folder."
                            : "\(count) munkipkg project\(count == 1 ? "" : "s") found."
                    }
                )
            }
        }
    }

    private var promoterStep: some View {
        @Bindable var settings = settings
        return onboardingStep(
            icon: "arrow.up.forward.square",
            title: "Promoter",
            subtitle: "Shows recent AutoPkg imports and upcoming catalog promotions, and lets you approve or defer them. Optional — skip if you don't run AutoPkg."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable the Promoter tab", isOn: $settings.enablePromoterTab)

                HStack {
                    TextField(
                        "Deployment folder",
                        text: $settings.autopkgDeploymentPath,
                        prompt: Text("Folder containing promoter.yml")
                    )
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    PathChooserButton.folder(path: $settings.autopkgDeploymentPath)
                }
                .disabled(!settings.enablePromoterTab)

                if settings.enablePromoterTab {
                    folderStatus(
                        path: settings.autopkgDeploymentPath,
                        emptyHint: "Point this at the folder holding the promoter config.",
                        describe: Self.describePromoterConfig
                    )
                }
            }
        }
    }

    private var profilesStep: some View {
        @Bindable var settings = settings
        return onboardingStep(
            icon: "doc.badge.gearshape",
            title: "Configuration Profiles",
            subtitle: "Lists every .mobileconfig under a folder and opens each in an XML editor with live validation. Optional — skip if you don't manage profiles here."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable the Profiles tab", isOn: $settings.enableProfilesTab)

                HStack {
                    TextField(
                        "Profiles folder",
                        text: $settings.profilesDirectoryPath,
                        prompt: Text("Folder of .mobileconfig files")
                    )
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    PathChooserButton.folder(path: $settings.profilesDirectoryPath)
                }
                .disabled(!settings.enableProfilesTab)

                if settings.enableProfilesTab {
                    folderStatus(
                        path: settings.profilesDirectoryPath,
                        emptyHint: "Point this at a folder of .mobileconfig files.",
                        describe: { url in
                            let count = Self.fileCount(under: url, extension: "mobileconfig")
                            return count == 0
                                ? "No .mobileconfig files found under this folder."
                                : "\(count) profile\(count == 1 ? "" : "s") found."
                        }
                    )
                }
            }
        }
    }

    private var gitStep: some View {
        @Bindable var settings = settings
        return onboardingStep(
            icon: "arrow.triangle.branch",
            title: "Git",
            subtitle: "When your repo is a git working tree, MunkiStudio can stage, commit, and push from inside the app."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if store.repository == nil {
                        Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                        Text("Open a repository to check this.")
                    } else if store.gitInfo != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("This repository is a git working tree.")
                    } else {
                        Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                        Text("Not a git working tree — the Git tab stays hidden.")
                    }
                }
                .font(.callout)

                Toggle("Show the Git tab", isOn: $settings.showGitSection)

                Text("Hooks directory")
                    .font(.callout.weight(.medium))
                TextField(
                    "Hooks directory",
                    text: $settings.gitHooksPathOverride,
                    prompt: Text("Auto-detect")
                )
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                Text("Leave blank to auto-detect: core.hooksPath, then .githooks, then .git/hooks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Inline feedback for a folder field — blank, missing, or what was
    /// actually found inside it. Turns "I typed a path" into "the app
    /// can see my files", which is the whole point of doing this in a
    /// wizard rather than leaving it to Settings.
    @ViewBuilder
    private func folderStatus(
        path: String,
        emptyHint: String,
        describe: (URL) -> String
    ) -> some View {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Text(emptyHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let url = URL(fileURLWithPath: trimmed)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue {
                Label(describe(url), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("That folder doesn't exist.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Describe the promoter config found in `url`.
    ///
    /// plist is the project's default on-disk format, so a deployment
    /// folder can legitimately hold `promoter.plist` rather than
    /// `promoter.yml`. Both are recognised here — but `FilePromoterService`
    /// currently parses YAML only, so a plist is reported honestly
    /// instead of implying the tab will populate.
    static func describePromoterConfig(in url: URL) -> String {
        let fm = FileManager.default
        for name in ["promoter.yml", "promoter.yaml"]
        where fm.fileExists(atPath: url.appending(path: name).path) {
            return "Found \(name)."
        }
        if fm.fileExists(atPath: url.appending(path: "promoter.plist").path) {
            return "Found promoter.plist — the Promoter tab reads YAML only, so it won't load yet."
        }
        return "No promoter config here — the Promoter tab will be empty."
    }

    /// Count immediate subdirectories that satisfy `marker` — used to
    /// spot munkipkg projects without loading them.
    private static func subdirectoryCount(of url: URL, marker: (URL) -> URL) -> Int {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { child in
            let candidates = ["build-info.plist", "build-info.yaml", "build-info.yml", "build-info.json"]
            return candidates.contains { FileManager.default.fileExists(atPath: child.appending(path: $0).path) }
        }.count
    }

    private static func fileCount(under url: URL, extension pathExtension: String) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let file as URL in enumerator where file.pathExtension == pathExtension {
            count += 1
        }
        return count
    }

    private var repositoryStep: some View {
        onboardingStep(
            icon: "folder",
            title: "Open your Munki repository",
            subtitle: "Choose the root folder of your Munki repo — the one containing pkgsinfo/, pkgs/, catalogs/ and manifests/."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                switch store.loadState {
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Opening\u{2026}").font(.callout)
                    }
                case .failed(let message):
                    // Silent failure here was the single worst part of
                    // the old flow: a wrong folder looked identical to
                    // no folder at all.
                    Label {
                        Text(message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                case .idle, .ready:
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
                        Text(loadedSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(store.repositoryWarnings, id: \.self) { warning in
                    Label {
                        Text(warning).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Button(store.repository == nil ? "Open Repository\u{2026}" : "Open a Different Repository\u{2026}") {
                    openRepository()
                }
                .disabled(store.loadState == .loading)

                if store.repository == nil {
                    Text("Open a repository to continue, or Skip Setup to do it later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What the app actually found, so a successful open is verifiable
    /// at a glance rather than taken on trust.
    private var loadedSummary: String {
        let snapshot = store.snapshot
        return "\(snapshot.pkginfos.count) pkginfos · \(snapshot.manifests.count) manifests · \(snapshot.catalogs.count) catalogs"
    }

    /// Shared step chrome.
    ///
    /// Everything shares one left edge. The header used to be centred
    /// while the content block sized itself to its widest child and got
    /// centred as a block, so the two never lined up and each step looked
    /// subtly crooked. Form rows can't be centred sensibly, so the header
    /// aligns to the content rather than the other way round.
    @ViewBuilder
    private func onboardingStep<Content: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(Color.munkiStudioBrand)
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
        .frame(maxWidth: 440, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Back") {
                if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
            }
            .disabled(step == .welcome)

            if AppDefaults.isSandbox() {
                Text("SANDBOX")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.15), in: .capsule)
                    .help("Running against a throwaway preference suite — your real settings aren't being touched.")
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { dot in
                    Circle()
                        .fill(dot == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }

            Spacer()

            if step == Step.allCases.last {
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
                // The repository is the one thing the app can't work
                // without. Leaving Continue live here let a user walk
                // the whole wizard without ever opening one and land on
                // an empty window with no idea what went wrong.
                .disabled(!canContinue)
            }
        }
        .padding(16)
    }

    /// Whether the current step is satisfied enough to advance. Only the
    /// repository step gates — everything after it is optional.
    private var canContinue: Bool {
        step != .repository || store.repository != nil
    }

    // MARK: Actions

    private func finish() {
        settings.hasCompletedOnboarding = true
        store.isShowingOnboarding = false
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

    private func openRepository() { pickingRepository = true }

    /// Handle the chosen folder.
    ///
    /// This used to route through a `PickerKind?` that the `isPresented`
    /// binding cleared on dismissal. SwiftUI writes `isPresented = false`
    /// *before* invoking this handler, so the kind was already `nil` by
    /// the time it was read and the `switch` fell through to a no-op —
    /// picking a repository in the wizard silently did nothing at all.
    /// There is only ever one picker here, so there is nothing to route.
    private func handlePickerResult(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task { await store.open(rootURL: url) }
    }
}
