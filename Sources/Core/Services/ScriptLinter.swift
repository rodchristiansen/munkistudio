import Foundation

/// Light-weight lint pass over pkginfo script slots. Real validation
/// would shell out to a language-specific tool — we just flag common
/// smells (missing shebang, Windows line endings, `sudo`, bare `except:`)
/// so admins notice them at edit time and at QA time.
public enum ScriptLinter {
    public static func warnings(_ source: String, language: ScriptLanguage) -> [String] {
        guard !source.isEmpty else { return [] }
        var warnings: [String] = []
        let firstLine = source.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        if !firstLine.hasPrefix("#!") && language.expectsShebang {
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
