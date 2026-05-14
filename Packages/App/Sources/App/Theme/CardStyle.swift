import SwiftUI

/// Unified surface styling.
///
/// CimianAdmin uses subtle but distinct elevation between the window
/// chrome, panels, and rows. macOS 26's Liquid Glass containers are
/// the right idea but `.regularMaterial` over `.regularMaterial`
/// produces visible banding (the vertical-line bug). We instead use:
/// - flat `controlBackgroundColor` fill (works in light and dark)
/// - 0.5pt hairline border that flips polarity by colour scheme
///   (dark-mode borders use a *lighter* tint, light-mode darker, so
///   the card edge reads against the backdrop instead of vanishing)
/// - drop shadow scaled by colour scheme — black-on-dark shadows are
///   invisible, so dark mode leans on a stronger top-edge highlight
///   instead.
///
/// Apply with `.cardStyle()` for elevated surfaces or `.panelStyle()`
/// for inset rows that share a parent card's elevation.
extension View {
    /// Elevated card with shadow. Use as the top-level container for a
    /// section (Identity, Catalogs, Git history, etc.).
    func cardStyle(padding: CGFloat = 16, cornerRadius: CGFloat = 10) -> some View {
        modifier(CardStyleModifier(padding: padding, cornerRadius: cornerRadius))
    }

    /// Inset row inside a card — flat fill, no shadow.
    func panelStyle(padding: CGFloat = 10, cornerRadius: CGFloat = 6) -> some View {
        modifier(PanelStyleModifier(padding: padding, cornerRadius: cornerRadius))
    }
}

private struct CardStyleModifier: ViewModifier {
    let padding: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(padding)
            .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
            // Dark mode: bright top-edge highlight gives the card a
            // visible upper rim that reads as elevation in the absence
            // of a usable drop shadow.
            .overlay {
                if colorScheme == .dark {
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.10),
                                    Color.white.opacity(0.02),
                                    Color.black.opacity(0.30),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                } else {
                    shape.strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5)
                }
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.05),
                radius: colorScheme == .dark ? 4 : 4,
                x: 0,
                y: colorScheme == .dark ? 1 : 1
            )
    }
}

private struct PanelStyleModifier: ViewModifier {
    let padding: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(padding)
            .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(
                shape.strokeBorder(
                    Color(colorScheme == .dark ? .white : .black).opacity(0.06),
                    lineWidth: 0.5
                )
            )
    }
}

/// Section header for the cardStyle layout. Shown above a `.cardStyle()`
/// container; uses a smaller secondary-coloured label so the card title
/// reads as a sub-heading, not a window title.
struct CardSectionHeader: View {
    let title: String
    var trailingControl: AnyView?

    init(_ title: String, @ViewBuilder trailing: () -> some View = { EmptyView() }) {
        self.title = title
        self.trailingControl = AnyView(trailing())
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
            trailingControl
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}
