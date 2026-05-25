import Foundation

/// Languages we recognize in pkginfo scripts. Detection runs on the
/// shebang first, then on simple content heuristics so a Python script
/// with no shebang still gets the right keyword set.
public enum ScriptLanguage: String, CaseIterable, Sendable {
    case bash, zsh, sh, python, ruby, perl, applescript, swift, plainText, xml

    public var displayName: String {
        switch self {
        case .bash: "Bash"
        case .zsh: "Zsh"
        case .sh: "POSIX sh"
        case .python: "Python"
        case .ruby: "Ruby"
        case .perl: "Perl"
        case .applescript: "AppleScript"
        case .swift: "Swift"
        case .plainText: "Plain text"
        case .xml: "XML"
        }
    }

    /// True for interpreted scripts that should carry a `#!` shebang.
    /// Markup and compiled-language sources should not be flagged for a
    /// missing shebang.
    public var expectsShebang: Bool {
        switch self {
        case .bash, .zsh, .sh, .python, .ruby, .perl: true
        case .applescript, .swift, .plainText, .xml: false
        }
    }

    public static func detect(in source: String) -> ScriptLanguage {
        let firstLine = source.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        if firstLine.hasPrefix("#!") {
            let lower = firstLine.lowercased()
            if lower.contains("python") { return .python }
            if lower.contains("bash") { return .bash }
            if lower.contains("zsh") { return .zsh }
            if lower.contains("ruby") { return .ruby }
            if lower.contains("perl") { return .perl }
            if lower.contains("osascript") || lower.contains("applescript") { return .applescript }
            if lower.contains("swift") { return .swift }
            if lower.hasSuffix("/sh") || lower.hasSuffix(" sh") { return .sh }
        }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<?xml")
            || trimmed.hasPrefix("<!DOCTYPE")
            || trimmed.hasPrefix("<plist") {
            return .xml
        }
        if source.range(of: #"^\s*(def |class |from \w+ import|import \w+)"#,
                        options: [.regularExpression, .anchored]) != nil {
            return .python
        }
        if source.range(of: #"tell application "#,
                        options: [.regularExpression, .caseInsensitive]) != nil {
            return .applescript
        }
        if source.range(of: #"^\s*(puts |def \w+|class \w+|end\s*$)"#,
                        options: [.regularExpression, .anchored]) != nil {
            return .ruby
        }
        return .bash // safe default for Munki scripts
    }

    /// Keywords highlighted as the "keyword" colour.
    public var keywords: [String] {
        switch self {
        case .bash, .zsh, .sh:
            ["if", "then", "else", "elif", "fi", "for", "while", "do", "done",
             "case", "esac", "function", "return", "in", "select", "until",
             "exit", "export", "local", "readonly", "set", "unset", "shift",
             "echo", "printf", "read", "test"]
        case .python:
            ["def", "class", "if", "elif", "else", "for", "while", "try",
             "except", "finally", "with", "as", "import", "from", "return",
             "yield", "pass", "break", "continue", "raise", "lambda", "and",
             "or", "not", "in", "is", "True", "False", "None", "global",
             "nonlocal", "async", "await"]
        case .ruby:
            ["def", "class", "module", "if", "elsif", "else", "unless", "case",
             "when", "while", "until", "for", "in", "do", "end", "begin",
             "rescue", "ensure", "raise", "return", "yield", "self", "nil",
             "true", "false", "and", "or", "not", "require", "include"]
        case .perl:
            ["use", "my", "our", "local", "sub", "if", "elsif", "else",
             "unless", "while", "until", "for", "foreach", "do", "return",
             "die", "warn", "print", "printf"]
        case .applescript:
            ["tell", "application", "end", "on", "to", "of", "if", "then",
             "else", "repeat", "with", "set", "get", "return", "try", "error"]
        case .swift:
            ["import", "func", "var", "let", "class", "struct", "enum",
             "protocol", "extension", "if", "else", "guard", "for", "while",
             "do", "try", "throws", "return", "switch", "case", "default",
             "break", "continue", "true", "false", "nil", "self", "Self",
             "async", "await", "actor", "where"]
        case .plainText, .xml:
            []
        }
    }

    /// Single-line comment prefix.
    public var lineCommentPrefix: String? {
        switch self {
        case .bash, .zsh, .sh, .python, .ruby, .perl: "#"
        case .swift: "//"
        case .applescript: "--"
        case .plainText, .xml: nil
        }
    }
}
