import SwiftUI
import Core

/// A pkginfo or manifest that Rename / Duplicate / Delete can act on.
enum ActionableRecord {
    case package(PkginfoRecord)
    case manifest(ManifestRecord)
}

/// Ellipsis menu offering Rename / Duplicate / Delete for a pkginfo or
/// manifest, with the prompt and confirmation alerts wired to the store.
/// Embedded in the Packages and Manifests detail views so the editors
/// offer the same actions as the list context menus.
struct RecordActionMenu: View {
    @Environment(RepositoryStore.self) private var store
    let record: ActionableRecord

    @State private var showRename = false
    @State private var showDuplicate = false
    @State private var showDelete = false
    @State private var renameText = ""
    @State private var duplicateText = ""

    var body: some View {
        Menu {
            Button("Rename\u{2026}") {
                renameText = currentName
                showRename = true
            }
            Button("Duplicate\u{2026}") {
                duplicateText = currentName + " copy"
                showDuplicate = true
            }
            Divider()
            Button("Delete\u{2026}", role: .destructive) { showDelete = true }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Rename, duplicate, or delete")
        .alert(renameTitle, isPresented: $showRename) {
            TextField(nameFieldLabel, text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(renameMessage)
        }
        .alert(duplicateTitle, isPresented: $showDuplicate) {
            TextField(nameFieldLabel, text: $duplicateText)
            Button("Duplicate") { commitDuplicate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(duplicateMessage)
        }
        .alert(deleteTitle, isPresented: $showDelete) {
            Button("Delete", role: .destructive) { commitDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    // MARK: Per-kind text

    private var currentName: String {
        switch record {
        case .package(let record): record.fileURL.deletingPathExtension().lastPathComponent
        case .manifest(let record): record.manifest.manifestName
        }
    }

    private var nameFieldLabel: String {
        switch record {
        case .package: "Filename"
        case .manifest: "Name"
        }
    }

    private var renameTitle: String {
        switch record {
        case .package: "Rename Package File"
        case .manifest: "Rename Manifest"
        }
    }

    private var renameMessage: String {
        switch record {
        case .package:
            "Renames the pkginfo file on disk. The package name and any manifest references are left unchanged."
        case .manifest:
            "Names may include slashes to nest the file under manifests/."
        }
    }

    private var duplicateTitle: String {
        switch record {
        case .package: "Duplicate Package"
        case .manifest: "Duplicate Manifest"
        }
    }

    private var duplicateMessage: String {
        switch record {
        case .package: "Creates a copy of this pkginfo file under a new filename."
        case .manifest: "Creates a copy of this manifest's contents under a new name."
        }
    }

    private var deleteTitle: String {
        switch record {
        case .package: "Delete Package"
        case .manifest: "Delete Manifest"
        }
    }

    private var deleteMessage: String {
        switch record {
        case .package(let record):
            "Delete \u{201c}\(record.fileURL.lastPathComponent)\u{201d}? This removes the pkginfo file from disk and can't be undone."
        case .manifest(let record):
            "Delete \u{201c}\(record.manifest.manifestName)\u{201d}? This removes the file from manifests/ and can't be undone."
        }
    }

    // MARK: Commit

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != currentName else { return }
        switch record {
        case .package(let record): Task { await store.renamePackage(record, to: name) }
        case .manifest(let record): Task { await store.renameManifest(record, to: name) }
        }
    }

    private func commitDuplicate() {
        let name = duplicateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch record {
        case .package(let record): Task { await store.duplicatePackage(record, as: name) }
        case .manifest(let record): Task { await store.duplicateManifest(record, as: name) }
        }
    }

    private func commitDelete() {
        switch record {
        case .package(let record): Task { await store.deletePackage(record) }
        case .manifest(let record): Task { await store.deleteManifest(record) }
        }
    }
}
