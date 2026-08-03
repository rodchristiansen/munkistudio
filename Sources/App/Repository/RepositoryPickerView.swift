import SwiftUI
import UniformTypeIdentifiers

struct RepositoryPickerView: View {
    @Environment(RepositoryStore.self) private var store
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 96
    @State private var picking = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            backdrop
                .ignoresSafeArea()

            // While the setup wizard is up, leave only the backdrop
            // behind it. The hero otherwise peeks out around the sheet
            // and reads as a second, half-hidden screen.
            if !store.isShowingOnboarding {
                ScrollView {
                    VStack(spacing: 36) {
                        Spacer(minLength: 60)
                        hero
                        primaryActions
                        if case .failed(let message) = store.loadState {
                            openFailure(message)
                        }
                        if !store.recentRepositories.isEmpty {
                            recentsSection
                        }
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 48)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }

                versionBadge
                    .padding(16)
            }
        }
        .fileImporter(
            isPresented: $picking,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await store.open(rootURL: url) }
            }
        }
    }

    /// Plain window background — no brand wash. The tinted gradient read
    /// as a stain across the top of an otherwise empty screen, and it
    /// fought the app icon sitting on top of it.
    private var backdrop: some View {
        Color.clear.background(.background)
    }

    private var hero: some View {
        VStack(spacing: 14) {
            AppIconView(size: heroSize * 1.5)
                .shadow(color: .accentColor.opacity(0.18), radius: 24, y: 6)
                .padding(.bottom, 6)

            Text("MunkiStudio")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .tracking(-0.5)

            Text("The Munki repository studio.")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Package · Import · Edit · Lint · Commit · Deploy")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    private var primaryActions: some View {
        Button(action: openRepository) {
            Label("Open Repository…", systemImage: "folder")
                .frame(minWidth: 220)
                .padding(.vertical, 4)
        }
        .keyboardShortcut("o", modifiers: .command)
        .controlSize(.extraLarge)
        .buttonStyle(.borderedProminent)
    }

    /// A failed open used to leave the picker looking untouched — the
    /// user clicked, nothing happened, and there was nowhere to find out
    /// why. `RepositoryStore` records the reason; this shows it.
    private func openFailure(_ message: String) -> some View {
        Label {
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.red.opacity(0.08), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.red.opacity(0.25), lineWidth: 1)
        )
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent")
                    .font(.headline)
                Spacer()
                Text("\(store.recentRepositories.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quinary, in: .capsule)
            }

            VStack(spacing: 6) {
                ForEach(store.recentRepositories, id: \.self) { url in
                    RecentRepoRow(
                        url: url,
                        action: { Task { await store.open(rootURL: url) } },
                        remove: { store.removeRecent(url) }
                    )
                }
            }
        }
        .frame(maxWidth: 520)
    }

    private var versionBadge: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return HStack(spacing: 8) {
            if AppDefaults.isSandbox() {
                Text("SANDBOX")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.15), in: .capsule)
                    .help("Running against a throwaway preference suite — your real settings aren't being touched.")
            }
            if let version {
                Text("v\(version)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func openRepository() {
        picking = true
    }
}

private struct RecentRepoRow: View {
    let url: URL
    let action: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    /// An unmounted share or a moved folder stays in the list — dropping
    /// it silently is worse — but it is drawn as unavailable so clicking
    /// it and getting nothing isn't a mystery.
    private var isAvailable: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isAvailable ? "folder.fill" : "questionmark.folder")
                    .foregroundStyle(isAvailable ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isAvailable ? .primary : .secondary)
                    Text(isAvailable ? url.path : "Unavailable — \(url.path)")
                        .font(.caption)
                        .foregroundStyle(isAvailable ? .secondary : .tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.5)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.tint.opacity(hovering ? 0.35 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remove from Recent", role: .destructive, action: remove)
        }
    }
}
