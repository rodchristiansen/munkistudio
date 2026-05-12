import SwiftUI
import Core

/// Right-column pair: a colorized diff viewer on top + a commit composer
/// at the bottom. The composer streams `git commit` output live so admins
/// can see pre-commit hook results.
struct GitDetailView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var diffText: String = ""
    @State private var subject: String = ""
    @State private var messageBody: String = ""
    @State private var runHooks: Bool = true
    @State private var commitLog: String = ""
    @State private var pushing: Bool = false

    var body: some View {
        VSplitView {
            DiffView(text: diffText)
                .frame(minHeight: 200)
                .task(id: store.selectedItemID) { await loadDiff() }
            commitComposer
                .padding(12)
                .frame(minHeight: 240)
        }
    }

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Commit").font(.headline)
            TextField("Subject", text: $subject)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $messageBody)
                .frame(minHeight: 80)
                .border(.tertiary, width: 1)
            HStack {
                Toggle("Run hooks", isOn: $runHooks)
                Spacer()
                Button("Commit") { Task { await commit() } }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(subject.isEmpty || store.gitInfo == nil)
                Button("Commit & Push") { Task { await commitAndPush() } }
                    .disabled(subject.isEmpty || store.gitInfo == nil)
            }
            if !commitLog.isEmpty {
                ScrollView {
                    Text(commitLog)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .background(.regularMaterial, in: .rect(cornerRadius: 6))
            }
            if pushing { ProgressView() }
        }
    }

    private func loadDiff() async {
        guard let info = store.gitInfo,
              let id = store.selectedItemID,
              let path = id.base as? String else {
            diffText = ""
            return
        }
        diffText = (try? await store.services.git.diff(in: info, relativePath: path)) ?? ""
    }

    private func commit() async {
        guard let info = store.gitInfo else { return }
        commitLog = ""
        do {
            for try await event in store.services.git.commit(in: info, subject: subject, body: messageBody.isEmpty ? nil : messageBody, runHooks: runHooks) {
                switch event {
                case .line(let line): commitLog += line + "\n"
                case .finished(let outcome):
                    if outcome.exitCode == 0 {
                        subject = ""
                        messageBody = ""
                        commitLog += "✔ \(outcome.commitSHA ?? "committed")\n"
                    } else {
                        commitLog += "✖ exit \(outcome.exitCode)\n"
                    }
                }
            }
        } catch {
            commitLog += "✖ \(error.localizedDescription)\n"
        }
    }

    private func commitAndPush() async {
        await commit()
        guard let info = store.gitInfo else { return }
        pushing = true
        defer { pushing = false }
        do {
            for try await event in store.services.git.push(in: info) {
                switch event {
                case .line(let line): commitLog += line + "\n"
                case .finished(let outcome):
                    commitLog += outcome.exitCode == 0 ? "✔ pushed\n" : "✖ push exit \(outcome.exitCode)\n"
                }
            }
        } catch {
            commitLog += "✖ \(error.localizedDescription)\n"
        }
    }
}

/// Trivial colorized diff renderer. Splits on newlines and tints each
/// line by leading char.
struct DiffView: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    let s = String(line)
                    Text(s)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(for: s))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .blue }
        return .primary
    }
}
