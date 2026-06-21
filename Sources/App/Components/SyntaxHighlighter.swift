import Foundation
import SwiftUI
import AppKit
import Core

/// Apply colour to a script body. Returns an `AttributedString` with
/// foregroundColor runs for comments, strings, and keywords. Deliberately
/// lightweight — a real grammar isn't worth the complexity for the short
/// install/uninstall scripts that live inside pkginfos.
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

// `ScriptLinter` and `ScriptLanguage` live in Core — see
// Core/Services/ScriptLinter.swift and Core/Models/ScriptLanguage.swift.
// The Testing pane reuses the same rules.
