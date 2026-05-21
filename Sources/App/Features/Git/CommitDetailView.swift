import SwiftUI
import Core

/// History-pane right-hand side: a sticky commit header with author /
/// date / refs at the top, then the colored diff body underneath.
struct CommitDetailView: View {
    let text: String
    let commit: GitCommit?

    /// `git show --stat --patch` puts a `---` / `n files changed`
    /// summary block above the unified diff. Split it off so the diff
    /// view itself receives only the `diff --git …` part it knows how
    /// to parse — the summary lives in the header card instead.
    private var split: (summary: String, diff: String) {
        guard let range = text.range(of: "\ndiff --git ") else {
            return (text, "")
        }
        let summary = String(text[..<range.lowerBound])
        let diff = String(text[range.lowerBound...]).trimmingCharacters(in: .newlines)
        return (summary.trimmingCharacters(in: .newlines), diff)
    }

    var body: some View {
        if text.isEmpty {
            ContentUnavailableView(
                "No commit",
                systemImage: "clock.arrow.circlepath",
                description: Text("Pick a commit from the history list.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    headerCard
                    if !split.summary.isEmpty {
                        summaryCard
                    }
                    DiffView(text: split.diff.isEmpty ? text : split.diff, mode: .commit)
                        .frame(minHeight: 200)
                }
                .padding(.bottom, 12)
            }
            .background(Color(white: 0.97).opacity(0.4))
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let commit {
                HStack(spacing: 6) {
                    ForEach(commit.refs, id: \.name) { ref in
                        RefChip(ref: ref)
                    }
                    Spacer(minLength: 0)
                }
                Text(commit.subject)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    Label(commit.author, systemImage: "person.crop.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Label(Self.dateFormatter.string(from: commit.date), systemImage: "clock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(commit.sha.prefix(8))
                        .font(.callout.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            } else {
                Text("Commit")
                    .font(.headline)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 1.0), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    /// Show the `git show --stat` summary as a small monospaced block —
    /// the table of per-file +/- counts plus the trailing "N files
    /// changed, X insertions(+), Y deletions(-)".
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(split.summary)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color.secondary.opacity(0.05), in: .rect(cornerRadius: 8))
        .padding(.horizontal, 14)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// Branch / tag / HEAD chip next to the commit subject. Mirrors Tower's
/// inline ref tokens — coloured by kind, small, monospaced label.
private struct RefChip: View {
    let ref: GitRef

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .imageScale(.small)
            Text(ref.name)
                .font(.caption.monospaced())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(background, in: .capsule)
        .foregroundStyle(foreground)
    }

    private var icon: String {
        switch ref.kind {
        case .head: "circle.fill"
        case .localBranch: "arrow.triangle.branch"
        case .remoteBranch: "cloud"
        case .tag: "tag"
        }
    }

    private var background: Color {
        switch ref.kind {
        case .head: Color.blue.opacity(0.15)
        case .localBranch: Color.blue.opacity(0.12)
        case .remoteBranch: Color.purple.opacity(0.12)
        case .tag: Color.orange.opacity(0.15)
        }
    }

    private var foreground: Color {
        switch ref.kind {
        case .head: .blue
        case .localBranch: .blue
        case .remoteBranch: .purple
        case .tag: .orange
        }
    }
}
