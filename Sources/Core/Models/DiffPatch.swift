import Foundation

/// Parsed unified-diff payload from `git diff`. One ``DiffFile`` per
/// `diff --git …` header in the input; one ``DiffHunk`` per `@@ … @@`
/// section underneath; ``DiffLine`` describes each line of the hunk.
///
/// The parser is forgiving: input it doesn't recognise as a header,
/// hunk header, or diff line is ignored. Empty input parses to an empty
/// ``DiffPatch``.
public struct DiffPatch: Sendable, Hashable {
    public var files: [DiffFile]
    public init(files: [DiffFile] = []) { self.files = files }
    public var isEmpty: Bool { files.allSatisfy(\.hunks.isEmpty) && files.isEmpty }
}

public struct DiffFile: Sendable, Hashable, Identifiable {
    /// Lines from `diff --git` up to (not including) the first hunk.
    /// Held verbatim so we can splice the hunk back into a one-hunk
    /// patch that `git apply` accepts.
    public var headerLines: [String]
    /// Path with the `a/` prefix from the file header.
    public var oldPath: String
    /// Path with the `b/` prefix from the file header.
    public var newPath: String
    public var hunks: [DiffHunk]

    public var id: String { oldPath + "→" + newPath }

    /// Convenience name for display — prefers the new path (current
    /// state), falls back to the old path for deletions.
    public var displayPath: String {
        newPath == "/dev/null" ? oldPath : newPath
    }

    public init(
        headerLines: [String],
        oldPath: String,
        newPath: String,
        hunks: [DiffHunk] = []
    ) {
        self.headerLines = headerLines
        self.oldPath = oldPath
        self.newPath = newPath
        self.hunks = hunks
    }

    public var insertions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count }
    }
    public var deletions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count }
    }
}

public struct DiffHunk: Sendable, Hashable, Identifiable {
    public var id: UUID
    /// The raw `@@ -old,olen +new,nlen @@ trailing context` header.
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]

    public init(
        id: UUID = UUID(),
        header: String,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [DiffLine] = []
    ) {
        self.id = id
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }

    public var insertions: Int { lines.filter { $0.kind == .addition }.count }
    public var deletions: Int { lines.filter { $0.kind == .deletion }.count }
}

public struct DiffLine: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case context, addition, deletion
        /// `\ No newline at end of file` — preserved so reconstructed
        /// patches don't accidentally insert a newline back in.
        case noNewline
    }

    public var id: UUID
    public var kind: Kind
    /// 1-based line number in the pre-image side, or `nil` for additions.
    public var oldLine: Int?
    /// 1-based line number in the post-image side, or `nil` for deletions.
    public var newLine: Int?
    /// Raw line content WITHOUT the leading `+ -` marker.
    public var content: String

    public init(
        id: UUID = UUID(),
        kind: Kind,
        oldLine: Int? = nil,
        newLine: Int? = nil,
        content: String
    ) {
        self.id = id
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.content = content
    }
}

/// Parse `git diff` output. Tolerant of unknown sections — anything
/// outside a `diff --git` block is dropped on the floor.
public enum DiffParser {
    public static func parse(_ text: String) -> DiffPatch {
        var files: [DiffFile] = []
        // Keep newlines so we can rebuild patches verbatim later.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("diff --git ") else { index += 1; continue }
            var header: [String] = [line]
            var oldPath = ""
            var newPath = ""
            index += 1
            // Header lines until the first hunk (or next file).
            while index < lines.count {
                let candidate = lines[index]
                if candidate.hasPrefix("@@ ") || candidate.hasPrefix("diff --git ") { break }
                header.append(candidate)
                if candidate.hasPrefix("--- ") {
                    oldPath = String(candidate.dropFirst(4))
                } else if candidate.hasPrefix("+++ ") {
                    newPath = String(candidate.dropFirst(4))
                }
                index += 1
            }
            if oldPath.isEmpty {
                // Fall back to the paths embedded in `diff --git a/x b/y`.
                let parts = line.split(separator: " ")
                if parts.count >= 4 {
                    oldPath = String(parts[2])
                    newPath = String(parts[3])
                }
            }
            var file = DiffFile(headerLines: header, oldPath: oldPath, newPath: newPath)
            while index < lines.count, lines[index].hasPrefix("@@ ") {
                let (hunk, consumed) = parseHunk(lines: lines, from: index)
                file.hunks.append(hunk)
                index += consumed
            }
            files.append(file)
        }
        return DiffPatch(files: files)
    }

    /// Parse a single hunk starting at `start` (which must reference a
    /// `@@ … @@` line). Returns the hunk plus how many input lines it
    /// consumed (the header line + every body line until the next hunk
    /// or file).
    private static func parseHunk(lines: [String], from start: Int) -> (DiffHunk, Int) {
        let header = lines[start]
        let (oldStart, oldCount, newStart, newCount) = parseHunkRanges(header)
        var hunk = DiffHunk(
            header: header,
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount
        )
        var oldCursor = oldStart
        var newCursor = newStart
        var consumed = 1
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("@@ ") || line.hasPrefix("diff --git ") { break }
            if line.isEmpty {
                // A trailing empty line is the natural artifact of the
                // split — only keep it when it actually belongs to the
                // hunk body. Heuristic: empty lines inside a hunk are
                // context lines (rendered as " " by git); a *truly* empty
                // input line at end-of-file terminates the patch.
                if index == lines.count - 1 { break }
                hunk.lines.append(DiffLine(
                    kind: .context,
                    oldLine: oldCursor,
                    newLine: newCursor,
                    content: ""
                ))
                oldCursor += 1
                newCursor += 1
                index += 1
                consumed += 1
                continue
            }
            let first = line.first!
            let body = String(line.dropFirst())
            switch first {
            case "+":
                hunk.lines.append(DiffLine(kind: .addition, oldLine: nil, newLine: newCursor, content: body))
                newCursor += 1
            case "-":
                hunk.lines.append(DiffLine(kind: .deletion, oldLine: oldCursor, newLine: nil, content: body))
                oldCursor += 1
            case " ":
                hunk.lines.append(DiffLine(kind: .context, oldLine: oldCursor, newLine: newCursor, content: body))
                oldCursor += 1
                newCursor += 1
            case "\\":
                hunk.lines.append(DiffLine(kind: .noNewline, oldLine: nil, newLine: nil, content: body))
            default:
                // Unknown marker — bail and let the outer loop treat
                // this as the next file's header or noise.
                return (hunk, consumed)
            }
            index += 1
            consumed += 1
        }
        return (hunk, consumed)
    }

    /// Pull `(oldStart, oldCount, newStart, newCount)` out of a hunk
    /// header. Missing counts default to 1 (git's own convention).
    private static func parseHunkRanges(_ header: String) -> (Int, Int, Int, Int) {
        // `@@ -A,B +C,D @@ …` — counts are optional, B/D default to 1.
        let scanner = Scanner(string: header)
        scanner.charactersToBeSkipped = nil
        _ = scanner.scanString("@@")
        _ = scanner.scanCharacters(from: .whitespaces)
        _ = scanner.scanString("-")
        let oldStart = scanner.scanInt() ?? 0
        var oldCount = 1
        if scanner.scanString(",") != nil { oldCount = scanner.scanInt() ?? 1 }
        _ = scanner.scanCharacters(from: .whitespaces)
        _ = scanner.scanString("+")
        let newStart = scanner.scanInt() ?? 0
        var newCount = 1
        if scanner.scanString(",") != nil { newCount = scanner.scanInt() ?? 1 }
        return (oldStart, oldCount, newStart, newCount)
    }
}

public extension DiffFile {
    /// Reconstruct a single-hunk unified-diff patch suitable for
    /// `git apply [--cached]`. The file header is taken verbatim from
    /// the original diff so binary / mode / rename info isn't lost.
    func patch(forHunk hunk: DiffHunk) -> String {
        var out = headerLines.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        out += hunk.header + "\n"
        for line in hunk.lines {
            switch line.kind {
            case .addition: out += "+" + line.content + "\n"
            case .deletion: out += "-" + line.content + "\n"
            case .context: out += " " + line.content + "\n"
            case .noNewline: out += "\\" + line.content + "\n"
            }
        }
        return out
    }
}
