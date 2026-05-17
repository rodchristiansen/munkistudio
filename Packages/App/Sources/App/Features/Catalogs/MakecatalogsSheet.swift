import SwiftUI
import Core

/// Modal sheet for running `makecatalogs`. Streams stdout/stderr lines as
/// they arrive and exposes an outcome (exit code, warnings) when done.
struct MakecatalogsSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var output: String = ""
    @State private var outcome: MakecatalogsOutcome?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "books.vertical.fill")
                Text("Rebuilding catalogs").font(.headline)
                Spacer()
                if outcome == nil { ProgressView().controlSize(.small) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(minWidth: 820, minHeight: 140)
                .background(.regularMaterial, in: .rect(cornerRadius: 8))
                // Tail the log — keep the newest line in view as
                // output streams in, so the run shows live progress.
                .onChange(of: output) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            if let outcome {
                HStack {
                    if outcome.exitCode == 0 {
                        Label("makecatalogs succeeded", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("makecatalogs exited \(outcome.exitCode)", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                    if outcome.hadWarnings {
                        Label("Warnings", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.return)
                }
            } else {
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        task?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .padding(16)
        .task { await run() }
        .onDisappear { task?.cancel() }
    }

    private func run() async {
        guard let repo = store.repository else { return }
        let services = store.services
        let work = Task {
            do {
                for try await event in services.makecatalogs.run(in: repo, options: .init()) {
                    switch event {
                    case .line(let line):
                        await MainActor.run { output += line + "\n" }
                    case .finished(let result):
                        await MainActor.run { outcome = result }
                    }
                }
            } catch {
                await MainActor.run {
                    output += "✖ \(error.localizedDescription)\n"
                    outcome = MakecatalogsOutcome(exitCode: -1, hadWarnings: true)
                }
            }
        }
        task = work
        await work.value
    }
}
