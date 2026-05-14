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
            }
            Spacer()
        }
        .onAppear(perform: loadImage)
        .onChange(of: iconName) { _, _ in loadImage() }
        .onChange(of: packageName) { _, _ in loadImage() }
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
        guard let repo = store.repository else {
            nsImage = nil
            return
        }
        let url = repo.iconsURL.appending(path: resolvedName)
        nsImage = NSImage(contentsOf: url)
    }
}
