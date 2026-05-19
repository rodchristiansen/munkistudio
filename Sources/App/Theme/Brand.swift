import SwiftUI

extension Color {
    /// MunkiStudio's signature cardboard-brown brand color. Applied as
    /// the app-wide tint so prominent buttons, selection highlights, and
    /// accented glyphs all carry the package-box identity.
    static let munkiStudioBrand = Color(red: 0.65, green: 0.47, blue: 0.30)

    /// Slightly darker variant for shadows / strokes where the base brand
    /// hue would wash out against materials.
    static let munkiStudioBrandDeep = Color(red: 0.45, green: 0.30, blue: 0.16)
}
