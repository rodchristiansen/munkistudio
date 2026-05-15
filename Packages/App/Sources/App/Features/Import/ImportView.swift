import SwiftUI
import Core
import UniformTypeIdentifiers
import AppKit

/// Import section — a single full-width pane. The drop zone routes a
/// single installer into the 4-step wizard and multiple files into the
/// batch queue. State lives in `ImportStore`; child views receive it via
/// `@Bindable` rather than the environment so a missing observable can
/// never crash the view tree.
struct ImportView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var importStore = ImportStore()
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import").font(.largeTitle.bold())
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch importStore.mode {
        case .wizard(let url):
            ImportWizardView(installerURL: url, importStore: importStore)
        case .idle, .running:
            if importStore.queue.isEmpty {
                dropZone
            } else {
                batchQueue
            }
        }
    }

    // MARK: Drop zone

    @ViewBuilder
    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Drop one or more installer files here")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button("Or pick one or more files…") { pickFiles() }
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { receiveDrop($0) }
    }

    // MARK: Batch queue

    @ViewBuilder
    private var batchQueue: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(importStore.queue.count) files queued").font(.headline)
                Spacer()
                Button("Add files…") { pickFiles() }
                Button("Clear queue") { importStore.clearQueue() }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Catalog").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. testing", text: $importStore.batchCatalog)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Subdirectory").font(.caption).foregroundStyle(.secondary)
                    TextField("apps/MyApp (optional)", text: $importStore.batchSubdirectory)
                        .textFieldStyle(.roundedBorder)
                }
            }

            List(importStore.queue) { item in
                HStack(spacing: 10) {
                    queueStatusIcon(item.status)
                    Text(item.fileName)
                    Spacer()
                    Text(item.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button("Process queue") {
                    Task { await processQueue() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(importStore.mode == .running)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { receiveDrop($0) }
    }

    @ViewBuilder
    private func queueStatusIcon(_ status: ImportStore.QueueItem.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .inProgress:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    // MARK: Drop / pick

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                importStore.handle(droppedURLs: urls)
            }
        }
        return true
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["pkg", "mpkg", "dmg", "app", "iso", "zip"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        importStore.handle(droppedURLs: panel.urls)
    }

    // MARK: Batch run

    private func processQueue() async {
        guard let repository = store.repository else { return }
        let emitYAML = repository.defaultFormat == .yaml
        importStore.mode = .running
        for item in importStore.queue where item.status == .pending || item.status == .error {
            item.status = .inProgress
            item.statusText = "Importing…"
            let options = importStore.buildBatchOptions(installerURL: item.installerURL, emitYAML: emitYAML)
            do {
                var outcome: MunkiimportOutcome?
                for try await event in store.services.munkiimport.run(in: repository, options: options) {
                    if case .finished(let result) = event { outcome = result }
                }
                if let outcome, outcome.exitCode == 0 {
                    item.status = .done
                    item.statusText = outcome.pkginfoURL?.lastPathComponent ?? "Imported"
                } else {
                    item.status = .error
                    item.statusText = "munkiimport exited \(outcome?.exitCode ?? -1)"
                }
            } catch {
                item.status = .error
                item.statusText = error.localizedDescription
            }
        }
        importStore.mode = .idle
        await store.reload()
    }
}
