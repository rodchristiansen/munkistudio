import SwiftUI

/// Multi-line script editor with a label header and a monospace text area.
/// Empty content is treated as "no script" — we set the bound optional to
/// `nil` so the corresponding key is omitted from the saved file rather
/// than written as an empty string.
struct ScriptEditor: View {
    let label: String
    @Binding var text: String

    var body: some View {
        DisclosureGroup {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 280)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.regularMaterial, in: .rect(cornerRadius: 6))
        } label: {
            HStack {
                Text(label)
                if !text.isEmpty {
                    Text("\(text.split(separator: "\n").count) lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
