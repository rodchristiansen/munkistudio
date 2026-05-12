import SwiftUI
import Core

struct IconsListView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        @Bindable var bindableStore = store
        List(selection: $bindableStore.selectedItemID) {
            ForEach(store.snapshot.icons, id: \.filename) { icon in
                HStack {
                    Image(systemName: "photo")
                    VStack(alignment: .leading) {
                        Text(icon.filename)
                        if let size = icon.byteSize {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tag(AnyHashable(icon.filename))
            }
        }
        .navigationTitle("Icons (\(store.snapshot.icons.count))")
        .toolbar {
            Button {
                Task {
                    guard let repo = store.repository else { return }
                    try? await store.services.icons.rebuildIconHashes(in: repo)
                }
            } label: {
                Label("Rebuild icon hashes", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(store.repository == nil)
        }
    }
}

struct IconDetailView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var imageData: Data?

    var body: some View {
        if let asset = selected {
            VStack {
                if let imageData,
                   let image = NSImage(data: imageData) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280, maxHeight: 280)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 80))
                        .foregroundStyle(.secondary)
                }
                Text(asset.filename).font(.headline)
                if let hash = asset.sha256 {
                    Text(hash).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            .padding()
            .task(id: asset.filename) {
                guard let repo = store.repository else { return }
                imageData = try? await store.services.icons.readBytes(of: asset, in: repo)
            }
        } else {
            ContentUnavailableView(
                "No icon selected",
                systemImage: "photo",
                description: Text("Pick an icon from the list to preview.")
            )
        }
    }

    private var selected: IconAsset? {
        guard let id = store.selectedItemID,
              let name = id.base as? String else { return nil }
        return store.snapshot.icons.first { $0.filename == name }
    }
}

import AppKit
