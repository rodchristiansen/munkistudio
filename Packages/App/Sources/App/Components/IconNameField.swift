import SwiftUI
import AppKit
import Core

/// `icon_name` editor: a thumbnail of the resolved icon next to a Menu
/// that lists every file under the repo's `icons/` directory, plus a
/// "Custom…" item that falls through to a free-text field for hand-typed
/// names (for icons that don't exist yet on disk). Lives in the Basic
/// Info panel.
struct IconNameField: View {
    @Environment(RepositoryStore.self) private var store
    @Binding var iconName: String?
    /// Used when no `icon_name` is set: Munki resolves to `<name>.png`.
    let packageName: String

    @State private var nsImage: NSImage?
    @State private var customMode: Bool = false
    @State private var generating: Bool = false
    @State private var generateError: String?
    @State private var generateStatus: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Menu {
                        // When the user picks the "default" entry we
                        // unset `icon_name` — Munki resolves to
                        // `<name>.png` automatically, so a value here
                        // would be a no-op.
                        Button("Use default") {
                            iconName = nil
                            customMode = false
                            loadImage()
                        }
                        Divider()
                        ForEach(availableIcons, id: \.self) { name in
                            Button(name) {
                                iconName = name
                                customMode = false
                                loadImage()
                            }
                        }
                        Divider()
                        Button("Custom…") {
                            customMode = true
                            if iconName == nil { iconName = "" }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            // The label only shows what the user
                            // actively chose. `nil` means "use Munki's
                            // default resolver" — we render the
                            // resolved filename without the "Default"
                            // prefix so the picker reads as a single
                            // chosen value.
                            Text(iconName ?? "\(packageName).png")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(iconName == nil ? .secondary : .primary)
                            Image(systemName: "chevron.up.chevron.down")
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: false, vertical: true)

                    Button(action: generate) {
                        if generating {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("Generating\u{2026}")
                            }
                        } else {
                            Label("Generate", systemImage: "wand.and.stars")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(generating || store.repository == nil || packageName.isEmpty)
                    .help("Generate an icon from the installer item with iconimporter")
                }
                if customMode {
                    TextField("filename.png", text: Binding(
                        get: { iconName ?? "" },
                        set: { iconName = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { loadImage() }
                    .onChange(of: iconName ?? "") { _, _ in loadImage() }
                }
                if let generateStatus {
                    Text(generateStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .onAppear(perform: loadImage)
        .onChange(of: iconName) { _, _ in loadImage() }
        .onChange(of: packageName) { _, _ in loadImage() }
        .alert("Icon Generation Failed", isPresented: Binding(
            get: { generateError != nil },
            set: { if !$0 { generateError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(generateError ?? "")
        }
    }

    /// Run `iconimporter` for this package, then refresh the thumbnail.
    /// iconimporter writes `<name>.png` for a single-app package, numbered
    /// `<name>_N.png` variants for a multi-app one, or nothing when the
    /// installer has no extractable application icon.
    private func generate() {
        guard let repo = store.repository, !packageName.isEmpty else { return }
        let name = packageName
        generating = true
        generateStatus = nil
        Task {
            do {
                let written = try await store.services.iconImporter.generateIcon(
                    forItem: name,
                    force: true,
                    in: repo
                )
                // Refresh the icon list so the picker shows the new files.
                if let icons = try? await store.services.icons.load(in: repo) {
                    store.snapshot.icons = icons
                }
                switch written.count {
                case 0:
                    generateStatus = "No application icons found in the installer item."
                case 1:
                    let file = written[0]
                    iconName = (file == "\(name).png") ? nil : file
                    generateStatus = "Generated \(file)."
                default:
                    iconName = written[0]
                    generateStatus = "iconimporter found \(written.count) icons — pick one from the menu."
                }
            } catch {
                generateError = error.localizedDescription
            }
            generating = false
            loadImage()
        }
    }

    private var thumbnail: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "shippingbox")
                    .imageScale(.large)
                    .foregroundStyle(Color.munkiStudioBrand.opacity(0.6))
            }
        }
        .frame(width: 48, height: 48)
        .padding(4)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
    }

    private var availableIcons: [String] {
        store.snapshot.icons.map(\.filename)
    }

    private func loadImage() {
        let resolvedName = iconName ?? "\(packageName).png"
        // Read the bytes ourselves so a freshly regenerated icon always
        // replaces a stale image rather than serving a cached NSImage.
        guard let repo = store.repository,
              let data = try? Data(contentsOf: repo.iconsURL.appending(path: resolvedName)) else {
            nsImage = nil
            return
        }
        nsImage = NSImage(data: data)
    }
}
