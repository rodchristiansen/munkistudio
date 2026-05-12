import SwiftUI
import AppKit

/// Always-expanded script editor. Each section shows the inline editor
/// with line numbers and a small "Expand" affordance opening a full-
/// screen sheet with syntax highlighting and a lint panel.
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

            LineNumberedTextEditor(text: $text, language: language)
                .frame(minHeight: 120, maxHeight: 220)
        }
        .sheet(isPresented: $fullScreenPresented) {
            ScriptEditorSheet(title: label, text: $text)
        }
    }

    private var lineCount: Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

/// Plain text editor with a left gutter of line numbers. The text is
/// rendered live in the editable area; a separate overlay shows the
/// syntax-highlighted version when `showsHighlighting` is true.
struct LineNumberedTextEditor: View {
    @Binding var text: String
    let language: ScriptLanguage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter
                .frame(width: 36)
                .background(Color.secondary.opacity(0.08))
            ZStack(alignment: .topLeading) {
                // Highlighted overlay (read-only)
                ScrollView {
                    Text(SyntaxHighlighter.attributed(text, language: language))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.disabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .allowsHitTesting(false)

                // Editable layer; the text colour is mostly clear so the
                // overlay above shows through, but we keep cursor &
                // selection visible.
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary.opacity(0.0))
                    // 0-opacity primary keeps the I-beam selection /
                    // cursor accent visible while letting the highlighted
                    // overlay above carry the visible glyphs.
            }
        }
        .background(Color.secondary.opacity(0.04), in: .rect(cornerRadius: 6))
    }

    private var gutter: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(1...max(1, lines), id: \.self) { lineNumber in
                    Text("\(lineNumber)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        .disabled(true)
    }

    private var lines: Int {
        max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
    }
}

/// Full-screen script editor sheet.
///
/// Shows the language badge in the title, the syntax-highlighted body,
/// and a collapsible lint panel beneath it.
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
            LineNumberedTextEditor(text: $text, language: language)
                .frame(minWidth: 760, minHeight: 480)
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
        .frame(minWidth: 820, minHeight: 600)
    }
}
