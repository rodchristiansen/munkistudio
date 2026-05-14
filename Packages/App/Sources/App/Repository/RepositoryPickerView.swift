import SwiftUI
import AppKit

struct RepositoryPickerView: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 96

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            backdrop
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 36) {
                    Spacer(minLength: 60)
                    hero
                    primaryActions
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

    private var backdrop: some View {
        LinearGradient(
            colors: [
                Color.munkiStudioBrand.opacity(colorScheme == .dark ? 0.18 : 0.10),
                Color.munkiStudioBrand.opacity(0.0)
            ],
            startPoint: .top,
            endPoint: .center
        )
        .background(.background)
    }

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.thinMaterial)
                    .frame(width: heroSize * 1.6, height: heroSize * 1.6)
                    .overlay(
                        Circle()
                            .stroke(.tertiary.opacity(0.4), lineWidth: 0.5)
                    )
                    .shadow(color: .accentColor.opacity(0.18), radius: 24, y: 6)
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: heroSize, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
            }
            .accessibilityHidden(true)
            .padding(.bottom, 6)

            Text("MunkiStudio")
                .font(.system(size: 38, weight: .bold, design: .rounded))
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
                    RecentRepoRow(url: url) {
                        Task { await store.open(rootURL: url) }
                    }
                }
            }
        }
        .frame(maxWidth: 520)
    }

    private var versionBadge: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return Group {
            if let version {
                Text("v\(version)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
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
}

private struct RecentRepoRow: View {
    let url: URL
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
    }
}
