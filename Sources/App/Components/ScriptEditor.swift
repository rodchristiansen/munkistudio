import SwiftUI
import AppKit

/// Always-expanded script editor.
///
/// Inline: a plain SwiftUI ``TextEditor``. The richer
/// ``HighlightedTextEditor`` (NSTextView + NSRulerView) does NOT play
/// well inside the outer pkginfo ScrollView — nesting an NSScrollView
/// inside SwiftUI's ScrollView produces a layout where the inner view
/// reports zero size, so the whole script card looked empty. The
/// expand sheet opens the rich editor with full canvas + line numbers
/// + linter, which is the right place for it.
struct ScriptEditor: View {
    let label: String
    @Binding var text: String
    /// Inline editor height. Callers pass a bigger value when two
    /// editors are placed side-by-side so the pair claims as much
    /// vertical room as two stacked single editors would.
    var editorHeight: CGFloat = 200
    /// Callers that supply their own title / Expand / Save row pass
    /// `false` so only the bordered editor is drawn.
    var showsHeader: Bool = true

    @State private var fullScreenPresented: Bool = false

    private var language: ScriptLanguage { ScriptLanguage.detect(in: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader { header }
            inlineEditor
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $fullScreenPresented) {
            ScriptEditorSheet(title: label, text: $text)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !label.isEmpty {
                Text(label).font(.headline)
            }
            Button {
                fullScreenPresented = true
            } label: {
                Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Open full-screen editor with linter and line numbers")
            if !text.isEmpty {
                Text(language.displayName)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.18), in: .capsule)
                Text("\(lineCount) lines")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !text.isEmpty {
                Button(role: .destructive) {
                    text = ""
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Clear")
            }
        }
    }

    private var inlineEditor: some View {
        // Plain SwiftUI TextEditor. Monospaced, soft-wrapping. Height
        // comes from `editorHeight` so paired side-by-side editors can
        // be taller than a single full-width one.
        TextEditor(text: $text)
            .font(.system(.callout, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(maxWidth: .infinity)
            .frame(height: editorHeight)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
            )
    }

    private var lineCount: Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

/// Full-screen script editor with a wider canvas and the linter panel.
///
/// Like the inline editor, this uses a plain SwiftUI ``TextEditor``
/// rather than ``HighlightedTextEditor`` — the NSTextView/NSScrollView
/// inside the SwiftUI sheet was rendering its ruler but never laying
/// out glyphs (the text never appeared at any width). Once we sort
/// out the NSScrollView sizing in a follow-up, we can swap this back.
struct ScriptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var text: String

    private var language: ScriptLanguage { ScriptLanguage.detect(in: text) }
    private var warnings: [String] { ScriptLinter.warnings(text, language: language) }
    private var lineCount: Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(.title2.bold())
                Text(language.displayName)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: .capsule)
                Text("\(lineCount) lines")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
                    .keyboardShortcut("w", modifiers: [.command])
            }
            // Linter goes ABOVE the editor: feedback that requires
            // scrolling past 100+ lines of script to see is feedback
            // the user never reads.
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Linter").font(.headline)
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5)
                )
            }
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minWidth: 760, minHeight: 480)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                )
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 620)
    }
}
