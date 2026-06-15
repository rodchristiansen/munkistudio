import SwiftUI
import UniformTypeIdentifiers
import Core

/// First-run onboarding wizard. Shown once, over `ContentView`, until the
/// user finishes or skips it (tracked by `AppSettings.hasCompletedOnboarding`).
/// Walks through the munkipkg tool and opening a repository — the two things
/// a new install needs. Optional feature folders (Build projects, Promoter,
/// Profiles) are deliberately left to Settings so the wizard never edits, or
/// clobbers, a path the user already set.
struct OnboardingView: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case welcome, munkipkg, repository
    }

    @State private var step: Step = .welcome
    @State private var munkipkgVersion: String?
    @State private var checkingMunkipkg = false
    @State private var installingMunkipkg = false
    @State private var munkipkgMessage: String?
    @State private var picker: PickerKind?

    private enum PickerKind: Identifiable {
        case repository
        var id: Self { self }
    }

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
            isPresented: pickerPresented,
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
        case .munkipkg: munkipkgStep
        case .repository: repositoryStep
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
            Text("A couple of quick steps to get set up. The Build, Promoter and Profiles tabs are opt-in — turn them on any time in Settings.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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

            if Step(rawValue: step.rawValue + 1) == nil {
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

    private func openRepository() { picker = .repository }

    private var pickerPresented: Binding<Bool> {
        Binding(get: { picker != nil }, set: { if !$0 { picker = nil } })
    }

    private func handlePickerResult(_ result: Result<[URL], any Error>) {
        defer { picker = nil }
        guard case .success(let urls) = result, let url = urls.first else { return }
        switch picker {
        case .repository:
            Task { await store.open(rootURL: url) }
        case .none:
            break
        }
    }
}
