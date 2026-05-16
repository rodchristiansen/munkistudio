import SwiftUI
import Core

/// Left-panel hook list for the Git pane's Hooks tab. Shows the resolved
/// hooks directory (and how it was resolved) plus every hook file in it.
struct GitHooksPanel: View {
    @Bindable var state: GitPaneState

    var body: some View {
        VStack(spacing: 0) {
            if let info = state.hooksInfo {
                directoryHeader(info)
                Divider()
                if state.filteredHooks.isEmpty {
                    ContentUnavailableView(
                        "No hooks",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("This directory has no hook files.")
                    )
                } else {
                    List(state.filteredHooks, id: \.id, selection: $state.hookSelection) { hook in
                        hookRow(hook).tag(hook.id)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No hooks directory",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            }
        }
    }

    private func directoryHeader(_ info: GitHooksInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(info.source.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(info.directory.path)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func hookRow(_ hook: GitHook) -> some View {
        HStack(spacing: 8) {
            Image(systemName: hook.isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(hook.isActive ? Color.green : .secondary)
                .imageScale(.small)
            Text(hook.name).lineLimit(1)
            Spacer()
            if hook.isSample {
                Text("sample")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: .capsule)
                    .foregroundStyle(.secondary)
            } else if !hook.isExecutable {
                Text("inactive")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Right-pane viewer/editor for the selected git hook. Real hooks are
/// editable with a Save button and an Active toggle (executable bit);
/// `.sample` files are shown read-only.
struct GitHookDetailPane: View {
    @Bindable var state: GitPaneState
    @Environment(RepositoryStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let hook = state.selectedHook {
            VStack(alignment: .leading, spacing: 0) {
                header(hook)
                Divider()
                TextEditor(text: $state.hookDraft)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .disabled(hook.isSample)
            }
        } else {
            ContentUnavailableView(
                "No hook selected",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Pick a hook from the list to view or edit it.")
            )
        }
    }

    private func header(_ hook: GitHook) -> some View {
        HStack(spacing: 10) {
            Text(hook.name).font(.headline)
            if hook.isSample {
                Text("sample — read-only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !hook.isSample {
                Toggle("Active", isOn: Binding(
                    get: { hook.isExecutable },
                    set: { active in Task { await setActive(hook, active) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Whether git runs this hook — toggles its executable bit")
                Button("Save") { Task { await save(hook) } }
                    .disabled(!state.hookDraftDirty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func save(_ hook: GitHook) async {
        do {
            try await store.services.git.writeHook(hook, contents: state.hookDraft)
            state.hookOriginal = state.hookDraft
            await reloadHooks()
        } catch {
            state.statusMessage = "Hook save failed: \(error.localizedDescription)"
            state.statusKind = .error
        }
    }

    private func setActive(_ hook: GitHook, _ active: Bool) async {
        do {
            try await store.services.git.setHookActive(hook, active: active)
            await reloadHooks()
        } catch {
            state.statusMessage = "Hook update failed: \(error.localizedDescription)"
            state.statusKind = .error
        }
    }

    private func reloadHooks() async {
        guard let info = state.info else { return }
        let override = settings.gitHooksPathOverride.isEmpty ? nil : settings.gitHooksPathOverride
        state.hooksInfo = try? await store.services.git.hooks(in: info, overridePath: override)
    }
}
