import SwiftUI
import Core

/// Middle column of the Profiles tab — folder tree of every
/// `.mobileconfig` under the configured directory, with new / rename /
/// duplicate / delete affordances.
struct ProfilesListView: View {
    @Environment(ProfileStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var search: String = ""
    @State private var showNewProfileSheet = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var bindable = store
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    showNewProfileSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("New profile")
                .disabled(directoryURL == nil)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            FilterField(text: $search, prompt: "Filter profiles", focused: $searchFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            content
        }
        .navigationTitle("Profiles")
        .navigationSubtitle(subtitle)
        .sheet(isPresented: $showNewProfileSheet) {
            NewProfileSheet(directoryURL: directoryURL)
        }
        .alert("Couldn't Complete Action", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.actionError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if directoryURL == nil {
            ContentUnavailableView {
                Label("No profiles folder set", systemImage: "folder.badge.gearshape")
            } description: {
                Text("Choose a folder of .mobileconfig files in Settings → Features.")
            }
        } else if store.records.isEmpty {
            ContentUnavailableView {
                Label("No profiles found", systemImage: "doc.text")
            } description: {
                Text("Scanned \(directoryPath) — found no .mobileconfig files.")
            }
        } else {
            ProfileTreeList(
                records: filtered,
                rootPath: directoryPath,
                forceExpandAll: !search.isEmpty
            )
        }
    }

    private var directoryPath: String {
        settings.profilesDirectoryPath.trimmingCharacters(in: .whitespaces)
    }

    private var directoryURL: URL? {
        directoryPath.isEmpty ? nil : URL(fileURLWithPath: directoryPath)
    }

    private var subtitle: String {
        let total = store.records.count
        let unsaved = store.dirtyCount
        if unsaved > 0 {
            return "\(total) profile\(total == 1 ? "" : "s") · \(unsaved) unsaved"
        }
        return "\(total) profile\(total == 1 ? "" : "s")"
    }

    private var filtered: [ProfileRecord] {
        guard !search.isEmpty else { return store.records }
        let query = search.lowercased()
        return store.records.filter { record in
            record.listLabel.lowercased().contains(query)
                || (record.profile.identifier?.lowercased().contains(query) ?? false)
                || record.fileURL.lastPathComponent.lowercased().contains(query)
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.actionError != nil },
            set: { if !$0 { store.actionError = nil } }
        )
    }
}

private struct NewProfileSheet: View {
    @Environment(ProfileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let directoryURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Profile").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Profile name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("Use slashes to nest, e.g. wifi/staff-network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || directoryURL == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func create() {
        guard let directoryURL else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dismiss()
        Task { await store.create(named: trimmed, directory: directoryURL) }
    }
}
