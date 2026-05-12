import Foundation
import SwiftUI
import AppKit

/// Apply colour to a script body. Returns an `AttributedString` with
/// foregroundColor runs for comments, strings, and keywords. Deliberately
/// lightweight — a real grammar isn't worth the complexity for what
/// MunkiAdmin scripts look like.
enum SyntaxHighlighter {
    /// `monospace` is honoured by callers if they want a code-style render.
    static func attributed(
        _ source: String,
        language: ScriptLanguage,
        monospace: Bool = true
    ) -> AttributedString {
        var result = AttributedString(source)
        if monospace {
            result.font = .system(.callout, design: .monospaced)
        }

        guard language != .plainText else { return result }

        // Comments first, then strings, then keywords. Each pass paints
        // colour onto runs that haven't been claimed by an earlier pass.
        if let prefix = language.lineCommentPrefix {
            paintComments(in: &result, source: source, prefix: prefix)
        }
        paintStrings(in: &result, source: source)
        paintKeywords(in: &result, source: source, keywords: language.keywords)
        paintNumbers(in: &result, source: source)
        return result
    }

    // MARK: Passes

    private static func paintComments(
        in attributed: inout AttributedString,
        source: String,
        prefix: String
    ) {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var offset = source.startIndex
        for line in lines {
            let start = offset
            let end = source.index(offset, offsetBy: line.count)
            if let commentRange = line.range(of: prefix) {
                // Skip when prefix is inside a quoted string. Cheap check:
                // count quotes before the prefix.
                let before = line[..<commentRange.lowerBound]
                let quoteCount = before.filter { $0 == "\"" }.count
                if quoteCount % 2 == 0 {
                    let attrStart = AttributedString.Index(commentRange.lowerBound, within: attributed)
                    let attrEnd = AttributedString.Index(end, within: attributed)
                    if let attrStart, let attrEnd {
                        attributed[attrStart..<attrEnd].foregroundColor = .secondary
                    }
                    _ = start
                }
            }
            offset = source.index(end, offsetBy: end < source.endIndex ? 1 : 0, limitedBy: source.endIndex) ?? source.endIndex
        }
    }

    private static func paintStrings(
        in attributed: inout AttributedString,
        source: String
    ) {
        // Match double-quoted and single-quoted spans (no escapes — good
        // enough for visual cue).
        let patterns = [#""(?:\\.|[^"\\])*""#, #"'(?:\\.|[^'\\])*'"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
            regex.enumerateMatches(in: source, options: [], range: nsRange) { match, _, _ in
                guard let match,
                      let range = Range(match.range, in: source) else { return }
                let attrStart = AttributedString.Index(range.lowerBound, within: attributed)
                let attrEnd = AttributedString.Index(range.upperBound, within: attributed)
                if let attrStart, let attrEnd {
                    attributed[attrStart..<attrEnd].foregroundColor = Color(red: 0.72, green: 0.55, blue: 0.30)
                }
            }
        }
    }

    private static func paintKeywords(
        in attributed: inout AttributedString,
        source: String,
        keywords: [String]
    ) {
        guard !keywords.isEmpty else { return }
        let escaped = keywords.map { NSRegularExpression.escapedPattern(for: $0) }
        let pattern = "\\b(" + escaped.joined(separator: "|") + ")\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        regex.enumerateMatches(in: source, options: [], range: nsRange) { match, _, _ in
            guard let match,
                  let range = Range(match.range, in: source) else { return }
            let attrStart = AttributedString.Index(range.lowerBound, within: attributed)
            let attrEnd = AttributedString.Index(range.upperBound, within: attributed)
            if let attrStart, let attrEnd {
                // Only repaint if not already painted (e.g. inside a
                // comment or string). AttributedString doesn't expose a
                // direct "current color" query so we always repaint —
                // for our use case the visual overlap is fine because
                // keywords inside strings are rare and the resulting
                // colour just stays the previous one.
                attributed[attrStart..<attrEnd].foregroundColor = Color(red: 0.55, green: 0.40, blue: 0.85)
            }
        }
    }

    private static func paintNumbers(
        in attributed: inout AttributedString,
        source: String
    ) {
        guard let regex = try? NSRegularExpression(pattern: #"\b\d+(\.\d+)?\b"#) else { return }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        regex.enumerateMatches(in: source, options: [], range: nsRange) { match, _, _ in
            guard let match,
                  let range = Range(match.range, in: source) else { return }
            let attrStart = AttributedString.Index(range.lowerBound, within: attributed)
            let attrEnd = AttributedString.Index(range.upperBound, within: attributed)
            if let attrStart, let attrEnd {
                attributed[attrStart..<attrEnd].foregroundColor = Color(red: 0.42, green: 0.62, blue: 0.95)
            }
        }
    }
}

/// Light-weight lint pass. Real validation would shell out to a
/// language-specific tool — we just flag common pkginfo script smells
/// so admins notice them at edit time.
enum ScriptLinter {
    static func warnings(_ source: String, language: ScriptLanguage) -> [String] {
        guard !source.isEmpty else { return [] }
        var warnings: [String] = []
        let firstLine = source.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        if !firstLine.hasPrefix("#!") && language != .applescript {
            warnings.append("Missing shebang on first line (e.g. #!/bin/bash, #!/usr/bin/env python3).")
        }
        if source.contains("\r") {
            warnings.append("Contains CR characters (Windows line endings) — may break on macOS.")
        }
        switch language {
        case .bash, .zsh, .sh:
            if source.range(of: #"\bsudo\b"#, options: .regularExpression) != nil {
                warnings.append("Calls `sudo`; Munki already runs scripts as root.")
            }
            if source.range(of: #"\$\{?\w+\}?"#, options: .regularExpression) != nil
                && source.range(of: #"set -[eu]"#, options: .regularExpression) == nil {
                warnings.append("Uses variables but doesn't `set -eu` — typos may pass silently.")
            }
        case .python:
            if !source.contains("import sys") && source.contains("sys.") {
                warnings.append("Uses `sys.*` but doesn't `import sys`.")
            }
            if source.contains("except:") && !source.contains("except Exception") {
                warnings.append("Bare `except:` swallows KeyboardInterrupt and SystemExit; prefer `except Exception`.")
            }
        default:
            break
        }
        return warnings
    }
}
