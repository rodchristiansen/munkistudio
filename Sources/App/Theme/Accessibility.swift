import SwiftUI

/// Helpers and notes for our accessibility baseline.
///
/// The app's text generally uses `Font` semantic styles (`.body`,
/// `.callout`, `.caption`, `.headline`) which scale automatically with
/// the user's Dynamic Type setting. The few decorative glyphs that
/// previously hard-coded a point size now use `@ScaledMetric` so they
/// also resize.
///
/// What still needs attention as we grow:
/// - Custom focusable views (the Git pane's `.onKeyPress` host) should
///   keep an `.accessibilityElement(children: .contain)` wrapper so
///   VoiceOver can announce them coherently.
/// - Icons that *carry* meaning (status letter in the Git Files panel,
///   the branch chevron) need `.accessibilityLabel` rather than just
///   `.help`.
/// - Forms with two-column layouts collapse to single column under
///   accessibility sizes via `ViewThatFits`; verify the collapse
///   threshold doesn't strand controls.
enum AccessibilityBaseline {}

extension View {
    /// Convenience for marking a row as a single accessibility element
    /// with combined children — used by tree rows so VoiceOver reads
    /// the chevron + folder + count + name as one phrase.
    func combinedAccessibilityElement(_ label: String) -> some View {
        self
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
    }
}
