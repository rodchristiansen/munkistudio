import SwiftUI
import AppKit
import Core

/// `icon_name` editor: a thumbnail of the resolved icon next to a
/// searchable picker that filters every file under the repo's `icons/`
/// directory, plus a "Custom…" entry that falls through to a free-text
/// field for hand-typed names (for icons that don't exist yet on disk).
/// Lives in the Basic Info panel.
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
    @State private var pickerOpen: Bool = false
    @State private var iconQuery: String = ""
    @FocusState private var iconQueryFocused: Bool
    /// Filenames the most recent Generate run produced — pinned to the
    /// top of the picker so freshly created icons are easy to choose.
    @State private var generatedIcons: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        pickerOpen = true
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
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: false, vertical: true)
                    .popover(isPresented: $pickerOpen, arrowEdge: .top) {
                        iconPickerPopover
                    }

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
                generatedIcons = written
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

    // MARK: Searchable icon picker

    private var iconPickerPopover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter icons", text: $iconQuery)
                    .textFieldStyle(.plain)
                    .focused($iconQueryFocused)
                    .onSubmit(selectFirstMatch)
                if !iconQuery.isEmpty {
                    Button {
                        iconQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    pickerRow(
                        label: "Use default (\(packageName).png)",
                        iconFile: "\(packageName).png",
                        selected: iconName == nil
                    ) {
                        iconName = nil
                        customMode = false
                    }
                    if !filteredGenerated.isEmpty {
                        sectionHeader("Just generated")
                        ForEach(filteredGenerated, id: \.self) { name in
                            pickerRow(label: name, iconFile: name, selected: iconName == name) {
                                iconName = name
                                customMode = false
                            }
                        }
                    }
                    if !filteredOtherIcons.isEmpty {
                        sectionHeader(generatedIcons.isEmpty ? "Icons" : "All icons")
                        ForEach(filteredOtherIcons, id: \.self) { name in
                            pickerRow(label: name, iconFile: name, selected: iconName == name) {
                                iconName = name
                                customMode = false
                            }
                        }
                    }
                    if !iconQuery.isEmpty, filteredGenerated.isEmpty, filteredOtherIcons.isEmpty {
                        Text("No matching icons")
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                    Divider().padding(.vertical, 2)
                    pickerRow(label: "Custom\u{2026}", iconFile: nil, selected: false) {
                        customMode = true
                        if iconName == nil { iconName = "" }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 320)
        .onAppear { iconQueryFocused = true }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func pickerRow(
        label: String,
        iconFile: String?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            pickerOpen = false
            iconQuery = ""
            loadImage()
        } label: {
            HStack(spacing: 8) {
                IconThumbnail(url: iconURL(for: iconFile))
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark")
                        .imageScale(.small)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func iconURL(for filename: String?) -> URL? {
        guard let filename, let repo = store.repository else { return nil }
        return repo.iconsURL.appending(path: filename)
    }

    private func matches(_ names: [String]) -> [String] {
        guard !iconQuery.isEmpty else { return names }
        let query = iconQuery.lowercased()
        return names.filter { $0.lowercased().contains(query) }
    }

    private var filteredGenerated: [String] {
        matches(generatedIcons)
    }

    /// Every repo icon except those already shown under "Just generated".
    private var filteredOtherIcons: [String] {
        let generated = Set(generatedIcons)
        return matches(availableIcons.filter { !generated.contains($0) })
    }

    private func selectFirstMatch() {
        guard let first = (filteredGenerated + filteredOtherIcons).first else { return }
        iconName = first
        customMode = false
        pickerOpen = false
        iconQuery = ""
        loadImage()
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

/// 32×32 preview of an icon file for a picker row. Loads lazily so a
/// long list only reads the icons actually scrolled into view.
private struct IconThumbnail: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if url != nil {
                Image(systemName: "photo")
                    .foregroundStyle(.quaternary)
            } else {
                Color.clear
            }
        }
        .frame(width: 32, height: 32)
        .task(id: url) {
            guard let url, let data = try? Data(contentsOf: url) else {
                image = nil
                return
            }
            image = NSImage(data: data)
        }
    }
}
