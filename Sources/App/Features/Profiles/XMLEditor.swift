import SwiftUI
import AppKit

/// SwiftUI wrapper around an `NSTextView` that highlights XML
/// syntax as the user types. Built specifically for `.mobileconfig`
/// editing — we don't need every nuance of a full XML grammar, just
/// enough visual structure that tags / strings / comments stand
/// apart from prose.
///
/// Implementation notes:
///   - Coloring is regex-driven. No JavaScript runtime, no
///     external dep. The XML the validator already understands
///     (plain plist XML) covers everything we need.
///   - The text storage is the source of truth. The SwiftUI
///     binding is synced *to* the storage on external changes
///     and *from* the storage on user edits, with a one-shot
///     guard to break feedback loops.
///   - Native `NSTextView` means we get a working undo stack,
///     find / replace via Edit menu, selection, and font-size
///     control for free.
struct XMLEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        // Editing-friendly defaults — turn off macOS's "helpful"
        // text substitutions that would otherwise mangle XML.
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.font = Self.editorFont
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 8)

        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        if textView.string != text {
            textView.string = text
            Self.highlight(storage: textView.textStorage)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // External update (e.g. "Revert" button restored the saved
        // bytes). Only re-set the string if it actually differs —
        // setting it every render would clobber the selection.
        if textView.string != text {
            // Suppress the textDidChange that will fire as a result
            // so we don't bounce the binding back to itself.
            context.coordinator.skipNextEditEcho = true
            textView.string = text
            Self.highlight(storage: textView.textStorage)
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: XMLEditor
        weak var textView: NSTextView?
        var skipNextEditEcho = false

        init(parent: XMLEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let updated = textView.string
            if let storage = textView.textStorage {
                XMLEditor.highlight(storage: storage)
            }
            if skipNextEditEcho {
                skipNextEditEcho = false
                return
            }
            // Bind back to SwiftUI. The state-update has to hop to
            // the next runloop tick so we don't re-enter the
            // current event dispatch.
            DispatchQueue.main.async { [parent] in
                if parent.text != updated {
                    parent.text = updated
                }
            }
        }
    }

    // MARK: Highlighting

    /// Re-apply syntax coloring across the entire text storage.
    /// Re-runs on every edit — fine for `.mobileconfig`-sized
    /// files; if perf ever bites we can scope to the edited
    /// paragraph range.
    static func highlight(storage: NSTextStorage?) {
        guard let storage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        defer { storage.endEditing() }

        // Reset to neutral so a previous pass's colors don't
        // linger after the user deletes the construct that
        // produced them.
        storage.setAttributes([
            .font: editorFont,
            .foregroundColor: NSColor.labelColor
        ], range: fullRange)

        let text = storage.string
        let nsText = text as NSString

        // Order matters: paint comments first (they wrap
        // strings and tag-shaped text), then strings (they may
        // sit inside tag attribute values), then tags.
        apply(regex: commentRegex, color: commentColor, in: nsText, on: storage)
        apply(regex: stringRegex, color: stringColor, in: nsText, on: storage)
        apply(regex: tagRegex, color: tagColor, in: nsText, on: storage)
    }

    private static func apply(
        regex: NSRegularExpression,
        color: NSColor,
        in nsText: NSString,
        on storage: NSTextStorage
    ) {
        let range = NSRange(location: 0, length: nsText.length)
        regex.enumerateMatches(in: nsText as String, options: [], range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    // MARK: Tokens

    /// `<!-- … -->` spanning any number of lines. Non-greedy so
    /// adjacent comments don't merge into one giant match.
    private static let commentRegex = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->"#,
        options: []
    )

    /// `"…"` — XML attribute values. Stops at the closing quote
    /// or a newline so a single dropped quote doesn't paint the
    /// rest of the file red.
    private static let stringRegex = try! NSRegularExpression(
        pattern: #""[^"\n]*""#,
        options: []
    )

    /// Any full XML tag including its attributes — `<tag>`,
    /// `<tag attr="value">`, `</tag>`, `<tag/>`, etc. The string
    /// regex above pre-colors attribute values, so the residual
    /// tag color covers the brackets + tag name + attribute keys.
    private static let tagRegex = try! NSRegularExpression(
        pattern: #"</?[A-Za-z!?][^>]*>"#,
        options: []
    )

    // MARK: Theme

    private static let editorFont: NSFont = {
        NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }()

    /// Semantic colors — they auto-adjust for light/dark mode and
    /// honor the user's accent if a future theme picker plugs in.
    private static let tagColor = NSColor.systemBlue
    private static let stringColor = NSColor.systemRed
    private static let commentColor = NSColor.systemGreen
}
