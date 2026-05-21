import SwiftUI
import Core

/// Tower-style status badge: a filled, color-coded rectangle with a
/// single bold uppercase letter inside (M, A, D, R, ?, !). Replaces the
/// previous plain colored letter in the working-tree file list.
struct GitStatusChip: View {
    let kind: GitStatusEntry.Kind
    var staged: Bool = false

    var body: some View {
        Text(letter)
            .font(.caption2.bold().monospaced())
            .foregroundStyle(Color.white)
            .frame(width: 18, height: 16)
            .background(background, in: .rect(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            )
            .accessibilityLabel(accessibilityLabel)
    }

    private var letter: String {
        switch kind {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "?"
        case .ignored: "!"
        case .conflicted: "U"
        }
    }

    private var background: Color {
        switch kind {
        case .modified: Color(red: 0.18, green: 0.49, blue: 0.95)   // blue
        case .added: Color(red: 0.18, green: 0.66, blue: 0.31)      // green
        case .deleted: Color(red: 0.87, green: 0.30, blue: 0.27)    // red
        case .renamed: Color(red: 0.45, green: 0.36, blue: 0.85)    // purple
        case .copied: Color(red: 0.20, green: 0.62, blue: 0.70)     // teal
        case .untracked: Color(red: 0.55, green: 0.59, blue: 0.65)  // gray
        case .ignored: Color(red: 0.75, green: 0.75, blue: 0.78)
        case .conflicted: Color(red: 0.93, green: 0.55, blue: 0.18) // orange
        }
    }

    private var accessibilityLabel: String {
        let base: String
        switch kind {
        case .modified: base = "Modified"
        case .added: base = "Added"
        case .deleted: base = "Deleted"
        case .renamed: base = "Renamed"
        case .copied: base = "Copied"
        case .untracked: base = "Untracked"
        case .ignored: base = "Ignored"
        case .conflicted: base = "Conflicted"
        }
        return staged ? "Staged \(base.lowercased())" : base
    }
}

/// File-kind glyph next to the filename — the small icon Tower shows
/// before the path. Distinguishes folders / yaml / plist / profile /
/// script / image at a glance.
struct GitFileGlyph: View {
    let relativePath: String

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .imageScale(.small)
            .frame(width: 14)
    }

    private var ext: String {
        (relativePath as NSString).pathExtension.lowercased()
    }

    private var symbol: String {
        if relativePath.hasSuffix("/") { return "folder.fill" }
        switch ext {
        case "yaml", "yml": return "doc.text"
        case "plist": return "doc.badge.gearshape"
        case "mobileconfig": return "person.crop.rectangle.badge.plus"
        case "pkg": return "shippingbox"
        case "sh", "py", "rb", "bash", "zsh": return "terminal"
        case "md", "txt", "rtf": return "doc.text"
        case "json": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "tiff", "icns", "icon": return "photo"
        default: return "doc"
        }
    }

    private var tint: Color {
        switch ext {
        case "yaml", "yml", "json": return .blue
        case "plist": return .indigo
        case "mobileconfig": return .purple
        case "pkg": return Color(red: 0.85, green: 0.55, blue: 0.10)
        case "sh", "py", "rb", "bash", "zsh": return .green
        case "png", "jpg", "jpeg", "gif", "tiff", "icns", "icon": return .pink
        default: return .secondary
        }
    }
}
