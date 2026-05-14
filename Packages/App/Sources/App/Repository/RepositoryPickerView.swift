import SwiftUI
import AppKit

/// Empty-state landing view. Lists recent repositories and offers an
/// "Open Repository…" affordance backed by a system file picker.
struct RepositoryPickerView: View {
    @Environment(RepositoryStore.self) private var store
    // Decorative app icon scales with the user's Dynamic Type setting
    // so the splash screen stays balanced at every size.
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 56

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: iconSize))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("MunkiStudio")
                    .font(.largeTitle.bold())
                Text("Open a Munki repository directory to get started.")
                    .foregroundStyle(.secondary)
            }

            Button(action: openRepository) {
                Label("Open Repository…", systemImage: "folder")
                    .frame(minWidth: 180)
            }
            .keyboardShortcut("o", modifiers: .command)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            if !store.recentRepositories.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent")
                        .font(.headline)
                    ForEach(store.recentRepositories, id: \.self) { url in
                        Button {
                            Task { await store.open(rootURL: url) }
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent)
                                    Text(url.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(8)
                            .background(.regularMaterial, in: .rect(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 480)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
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
