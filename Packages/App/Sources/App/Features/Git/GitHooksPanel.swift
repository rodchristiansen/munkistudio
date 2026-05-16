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
                        description: Text(state.filter.isEmpty
                            ? "No hooks found."
                            : "No hooks match the filter.")
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
        HStack(spacing: 8) {
            Text(info.source.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(relativeDirectory(info))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// The hooks directory relative to the work-tree root — falls back
    /// to the absolute path if it lives outside the repo.
    private func relativeDirectory(_ info: GitHooksInfo) -> String {
        guard let root = state.info?.workTreeRoot else { return info.directory.path }
        let dir = info.directory.resolvingSymlinksInPath().path
        let base = root.resolvingSymlinksInPath().path
        if dir == base { return "." }
        let prefix = base + "/"
        return dir.hasPrefix(prefix) ? String(dir.dropFirst(prefix.count)) : info.directory.path
    }

    private func hookRow(_ hook: GitHook) -> some View {
        HStack(spacing: 8) {
            Image(systemName: hook.isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(hook.isActive ? Color.green : Color.secondary.opacity(hook.exists ? 1 : 0.5))
                .imageScale(.small)
            Text(hook.name)
                .lineLimit(1)
                .foregroundStyle(hook.exists ? .primary : .secondary)
            Spacer()
            if hook.isActive {
                EmptyView()
            } else if hook.isSample {
                HookBadge(text: "Sample", color: .orange)
            } else {
                HookBadge(text: "Inactive", color: .secondary)
            }
        }
    }
}

/// A small capsule badge used in the hooks list and editor.
struct HookBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.16), in: .capsule)
            .foregroundStyle(color)
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
                metaBar(hook)
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
            if !hook.isSample {
                Toggle("Active", isOn: Binding(
                    get: { hook.isActive },
                    set: { active in Task { await setActive(hook, active) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!hook.exists)
                .help(hook.exists
                      ? "Whether git runs this hook — toggles its executable bit"
                      : "Save the hook to create the file, then activate it")
                Button("Save") { Task { await save(hook) } }
                    .disabled(!state.hookDraftDirty)
            }
            Text(hook.name).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Status badges + a one-line description sitting above the editor.
    private func metaBar(_ hook: GitHook) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if hook.isActive {
                    HookBadge(text: "Active", color: .green)
                } else {
                    HookBadge(text: "Inactive", color: .secondary)
                }
                if hook.isSample { HookBadge(text: "Sample", color: .orange) }
                HookBadge(
                    text: GitHookCatalog.isServerSide(hook.name) ? "Server-side" : "Client-side",
                    color: .blue
                )
            }
            if let summary = GitHookCatalog.summary(for: hook.name) {
                Text(.init(summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hook.isSample {
                Text("Sample hook — git won't run it. Read-only.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else if !hook.exists {
                Text("This hook isn't set up. Type a script and Save to create the file, then toggle Active.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
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
