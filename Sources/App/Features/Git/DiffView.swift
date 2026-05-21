import SwiftUI
import Core

/// Tower-style structured diff view: a header card per file, then each
/// hunk in its own card with a stat-bar header and the line table
/// underneath.
///
/// In ``Mode/workingTree`` the hunk header offers Stage / Discard
/// buttons; in ``Mode/commit`` (history diff for a committed change)
/// the buttons are hidden because there's nothing to stage.
struct DiffView: View {
    enum Mode: Equatable { case workingTree, commit }

    let text: String
    var mode: Mode = .workingTree
    /// Whether the focused file is currently staged. Drives the
    /// per-hunk button labels (Unstage Chunk vs Stage Chunk).
    var anyStaged: Bool = false
    var onStageHunk: ((DiffFile, DiffHunk) -> Void)? = nil
    var onUnstageHunk: ((DiffFile, DiffHunk) -> Void)? = nil
    var onDiscardHunk: ((DiffFile, DiffHunk) -> Void)? = nil

    private var patch: DiffPatch { DiffParser.parse(text) }

    var body: some View {
        if patch.isEmpty {
            ContentUnavailableView(
                "No diff",
                systemImage: "text.alignleft",
                description: Text(mode == .commit
                    ? "Select a commit to view its changes."
                    : "Pick a file to view its diff.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(patch.files) { file in
                        fileCard(file)
                    }
                }
                .padding(14)
            }
            .background(Color(white: 0.97).opacity(0.4))
        }
    }

    @ViewBuilder
    private func fileCard(_ file: DiffFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            fileHeader(file)
            ForEach(file.hunks) { hunk in
                hunkCard(file: file, hunk: hunk)
            }
            if file.hunks.isEmpty {
                Text("No hunks (binary or mode-only change).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .background(Color(white: 1.0), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }

    private func fileHeader(_ file: DiffFile) -> some View {
        HStack(spacing: 8) {
            GitFileGlyph(relativePath: file.displayPath)
            Text(file.displayPath)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            statBadge(insertions: file.insertions, deletions: file.deletions)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(.rect(topLeadingRadius: 8, topTrailingRadius: 8))
    }

    private func hunkCard(file: DiffFile, hunk: DiffHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            hunkHeader(file: file, hunk: hunk)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(hunk.lines) { line in
                    DiffLineRow(line: line)
                }
            }
            .padding(.vertical, 2)
        }
        .background(Color(white: 0.99))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.secondary.opacity(0.12)).frame(height: 0.5)
        }
    }

    private func hunkHeader(file: DiffFile, hunk: DiffHunk) -> some View {
        HStack(spacing: 8) {
            Text(hunk.header)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.blue)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            statBadge(insertions: hunk.insertions, deletions: hunk.deletions)
            if mode == .workingTree {
                Button(anyStaged ? "Unstage Chunk" : "Stage Chunk") {
                    if anyStaged {
                        onUnstageHunk?(file, hunk)
                    } else {
                        onStageHunk?(file, hunk)
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                Button("Discard Chunk", role: .destructive) {
                    onDiscardHunk?(file, hunk)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.08))
    }

    private func statBadge(insertions: Int, deletions: Int) -> some View {
        HStack(spacing: 6) {
            if insertions > 0 {
                Text("+\(insertions)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Color(red: 0.18, green: 0.55, blue: 0.24))
            }
            if deletions > 0 {
                Text("-\(deletions)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Color(red: 0.74, green: 0.20, blue: 0.18))
            }
        }
    }
}

/// One line of a diff hunk — two-column line numbers (old | new),
/// a colored gutter strip, then the content. Inspired by Tower's
/// per-line layout.
private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            numberCell(line.oldLine)
            numberCell(line.newLine)
            Rectangle()
                .fill(gutterColor)
                .frame(width: 3)
            Text(prefix + line.content)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .background(rowBackground)
                .textSelection(.enabled)
        }
    }

    private func numberCell(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 42, alignment: .trailing)
            .padding(.trailing, 6)
            .background(Color.secondary.opacity(0.05))
    }

    private var prefix: String {
        switch line.kind {
        case .addition: "+ "
        case .deletion: "- "
        case .context: "  "
        case .noNewline: "\\ "
        }
    }

    private var gutterColor: Color {
        switch line.kind {
        case .addition: Color(red: 0.18, green: 0.55, blue: 0.24)
        case .deletion: Color(red: 0.78, green: 0.20, blue: 0.18)
        case .context, .noNewline: Color.clear
        }
    }

    private var rowBackground: Color {
        switch line.kind {
        case .addition: Color(red: 0.84, green: 0.96, blue: 0.86).opacity(0.5)
        case .deletion: Color(red: 0.98, green: 0.85, blue: 0.84).opacity(0.5)
        case .context, .noNewline: Color.clear
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .addition: Color(red: 0.10, green: 0.45, blue: 0.18)
        case .deletion: Color(red: 0.62, green: 0.15, blue: 0.13)
        case .context: .primary
        case .noNewline: .secondary
        }
    }
}
