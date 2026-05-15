import SwiftUI
import Core
import UniformTypeIdentifiers

/// Bisect step 5: inline drop zone — ZStack + RoundedRectangle + onDrop,
/// no separate struct, no passed ImportStore.
struct ImportView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var importStore = ImportStore()
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import").font(.largeTitle.bold())
            dropZone
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

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
                Button("Or pick one or more files…") { }
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { _ in true }
    }
}
