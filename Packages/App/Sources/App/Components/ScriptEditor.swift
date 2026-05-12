import SwiftUI
import AppKit

/// Always-expanded script editor. The inline editor uses
/// ``HighlightedTextEditor`` (NSTextView under the hood) so 95-line
/// scripts scroll internally without breaking the parent ScrollView.
/// An "Expand" button opens the same editor at sheet size with the
/// linter panel beside it.
struct ScriptEditor: View {
    let label: String
    @Binding var text: String

    @State private var fullScreenPresented: Bool = false

    private var language: ScriptLanguage { ScriptLanguage.detect(in: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.headline)
                if !text.isEmpty {
                    Text(language.displayName)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.regularMaterial, in: .capsule)
                    Text("\(lineCount) lines")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    fullScreenPresented = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Open full-screen editor")
                .accessibilityLabel("Open full-screen editor for \(label)")
                if !text.isEmpty {
                    Button(role: .destructive) {
                        text = ""
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear")
                    .accessibilityLabel("Clear \(label) script")
                }
            }

            HighlightedTextEditor(text: $text, language: language)
                .frame(height: 200)
                .background(Color.secondary.opacity(0.04), in: .rect(cornerRadius: 6))
        }
        .sheet(isPresented: $fullScreenPresented) {
            ScriptEditorSheet(title: label, text: $text)
        }
    }

    private var lineCount: Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

/// Full-screen script editor with a wider canvas and the linter panel.
struct ScriptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var text: String

    private var language: ScriptLanguage { ScriptLanguage.detect(in: text) }
    private var warnings: [String] { ScriptLinter.warnings(text, language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(.title2.bold())
                Text(language.displayName)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: .capsule)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
                    .keyboardShortcut("w", modifiers: [.command])
            }
            HighlightedTextEditor(text: $text, language: language)
                .frame(minWidth: 760, minHeight: 480)
                .background(Color.secondary.opacity(0.04), in: .rect(cornerRadius: 6))
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Linter").font(.headline)
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 620)
    }
}
