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
            ScrollView {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minWidth: 520, minHeight: 280)
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
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
