import SwiftUI
import AppKit

/// Always-expanded inline script editor with a "full screen" affordance.
/// Mirrors CimianAdmin's pattern: the inline view is compact but never
/// hidden behind a disclosure, and a button opens a dedicated editor
/// window with line numbers and basic lint feedback.
struct ScriptEditor: View {
    let label: String
    @Binding var text: String

    @State private var fullScreenPresented: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.headline)
                if !text.isEmpty {
                    Text("\(lineCount) lines")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    fullScreenPresented = true
                } label: {
                    Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Open in full-screen editor")
                if !text.isEmpty {
                    Button(role: .destructive) {
                        text = ""
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear")
                }
            }

            LineNumberedTextEditor(text: $text)
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

/// Plain text editor with a left gutter of line numbers. Pure SwiftUI;
/// uses the height of each rendered line by mirroring the same font.
struct LineNumberedTextEditor: View {
    @Binding var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter
                .frame(width: 36)
                .background(.regularMaterial.opacity(0.6))
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .background(.regularMaterial.opacity(0.4), in: .rect(cornerRadius: 6))
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

/// Full-screen script editor sheet. Shows line numbers, basic lint
/// feedback (empty body / missing shebang / etc.), and a save button
/// that dismisses with the new text in place via the binding.
struct ScriptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
                    .keyboardShortcut("w", modifiers: [.command])
            }
            LineNumberedTextEditor(text: $text)
                .frame(minWidth: 720, minHeight: 480)
            if !lintWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lintWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 560)
    }

    /// Light-weight checks that surface common script mistakes without
    /// shelling out to shellcheck. Genuinely useful but never blocking.
    private var lintWarnings: [String] {
        guard !text.isEmpty else { return [] }
        var warnings: [String] = []
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        if !firstLine.hasPrefix("#!") {
            warnings.append("Missing shebang on first line (e.g. #!/bin/bash).")
        }
        if text.contains("\r") {
            warnings.append("Contains CR characters (Windows line endings) — may break on macOS.")
        }
        if text.range(of: #"\bsudo\b"#, options: .regularExpression) != nil {
            warnings.append("Calls `sudo`; Munki already runs scripts as root.")
        }
        if text.range(of: #"\$\{?\w+\}?"#, options: .regularExpression) != nil
            && text.range(of: #"set -[eu]"#, options: .regularExpression) == nil {
            warnings.append("Uses variables but doesn't `set -eu` — typos may pass silently.")
        }
        return warnings
    }
}
