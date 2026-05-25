import SwiftUI
import AppKit
import Core

/// `NSViewRepresentable` wrapping `NSTextView` so we get:
/// - real internal scrolling (SwiftUI's `TextEditor` plus a separate
///   highlight overlay can't share scroll position — bug Rod hit on
///   the 95-line install_check script).
/// - language-aware attribute runs painted directly into the text
///   storage. No second view layer to keep in sync.
/// - a line-number gutter via `NSRulerView`.
/// - macOS's built-in find bar (Cmd-F) for free.
struct HighlightedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var language: ScriptLanguage
    var showsLineNumbers: Bool = true
    var isEditable: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // Solid background. When this was transparent, the NSScrollView's
        // content-clip and the line-number ruler boundary painted vertical
        // hair lines that bled out through the parent SwiftUI background
        // (the "vertical lines through the whole window" bug).
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        if showsLineNumbers {
            let ruler = LineNumberRulerView(textView: textView)
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        }

        textView.string = text
        context.coordinator.applyHighlighting(textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selected.location, text.utf16.count),
                length: 0
            ))
        }
        context.coordinator.applyHighlighting(textView: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightedTextEditor

        init(_ parent: HighlightedTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            applyHighlighting(textView: textView)
            // Nudge the ruler to redraw when line count changes.
            (textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.invalidateRulerThickness()
        }

        func applyHighlighting(textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let source = textView.string
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(
                [
                    .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ],
                range: fullRange
            )
            ScriptHighlighter.paint(
                storage: storage,
                source: source,
                language: parent.language
            )
            storage.endEditing()
        }
    }
}

/// Paints colour runs onto an `NSTextStorage`. Mirrors the SwiftUI
/// `SyntaxHighlighter` but writes directly to AppKit attributes so the
/// `NSTextView` shows them without a second layer.
enum ScriptHighlighter {
    static func paint(storage: NSTextStorage, source: String, language: ScriptLanguage) {
        guard language != .plainText else { return }
        if let prefix = language.lineCommentPrefix {
            paintComments(storage: storage, source: source, prefix: prefix)
        }
        paintStrings(storage: storage, source: source)
        paintKeywords(storage: storage, source: source, keywords: language.keywords)
        paintNumbers(storage: storage, source: source)
    }

    private static func paintComments(storage: NSTextStorage, source: String, prefix: String) {
        let pattern = NSRegularExpression.escapedPattern(for: prefix) + ".*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
        let nsRange = NSRange(location: 0, length: storage.length)
        regex.enumerateMatches(in: source, options: [], range: nsRange) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
        }
    }

    private static func paintStrings(storage: NSTextStorage, source: String) {
        let patterns = [#""(?:\\.|[^"\\])*""#, #"'(?:\\.|[^'\\])*'"#]
        let color = NSColor(calibratedRed: 0.72, green: 0.55, blue: 0.30, alpha: 1)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(location: 0, length: storage.length)
            regex.enumerateMatches(in: source, options: [], range: nsRange) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
    }

    private static func paintKeywords(storage: NSTextStorage, source: String, keywords: [String]) {
        guard !keywords.isEmpty else { return }
        let escaped = keywords.map { NSRegularExpression.escapedPattern(for: $0) }
        let pattern = "\\b(" + escaped.joined(separator: "|") + ")\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let color = NSColor(calibratedRed: 0.55, green: 0.40, blue: 0.85, alpha: 1)
        let nsRange = NSRange(location: 0, length: storage.length)
        regex.enumerateMatches(in: source, options: [], range: nsRange) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private static func paintNumbers(storage: NSTextStorage, source: String) {
        guard let regex = try? NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#) else { return }
        let color = NSColor(calibratedRed: 0.42, green: 0.62, blue: 0.95, alpha: 1)
        let nsRange = NSRange(location: 0, length: storage.length)
        regex.enumerateMatches(in: source, options: [], range: nsRange) { match, _, _ in
            guard let match else { return }
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

/// Minimal line-number gutter for `NSTextView`. Tracks the visible
/// rect on every layout and draws one number per laid-out line. Good
/// enough for our 95-line scripts.
final class LineNumberRulerView: NSRulerView {
    private weak var ownerTextView: NSTextView?

    init(textView: NSTextView) {
        self.ownerTextView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 36
        // Redraw when the text changes or the view scrolls.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(invalidateAll),
            name: NSText.didChangeNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(invalidateAll),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
        textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    @objc private func invalidateAll() {
        needsDisplay = true
    }

    func invalidateRulerThickness() {
        guard let textView = ownerTextView else { return }
        let lineCount = max(1, textView.string.split(separator: "\n", omittingEmptySubsequences: false).count)
        let width = max(36, CGFloat(String(lineCount).count) * 8 + 16)
        if abs(ruleThickness - width) > 0.5 {
            ruleThickness = width
        }
        invalidateAll()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Paint the ruler with the same background as the text view so
        // there's no visible seam between gutter and document.
        NSColor.textBackgroundColor.setFill()
        rect.fill()

        guard let textView = ownerTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let nsString = textView.string as NSString

        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 2, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        // Walk every line containing a visible glyph.
        let rulerWidth = self.ruleThickness
        var lineIndex = 1

        nsString.enumerateSubstrings(
            in: NSRange(location: 0, length: nsString.length),
            options: [.byLines, .substringNotRequired]
        ) { _, substringRange, _, stop in
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: substringRange.location)
            if glyphIndex >= glyphRange.location {
                let lineRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphIndex,
                    effectiveRange: nil
                )
                let y = lineRect.minY + textView.textContainerInset.height - visible.minY
                let text = "\(lineIndex)" as NSString
                let size = text.size(withAttributes: attributes)
                let x = rulerWidth - size.width - 6
                text.draw(at: NSPoint(x: x, y: y + 1), withAttributes: attributes)
            }
            if glyphIndex > glyphRange.location + glyphRange.length {
                stop.pointee = true
            }
            lineIndex += 1
        }
    }
}
