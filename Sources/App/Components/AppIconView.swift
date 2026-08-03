import SwiftUI
import AppKit

/// The app's own icon, for the places that stand for MunkiStudio itself —
/// the welcome step and the empty-state hero — rather than for a package.
///
/// Always the light rendering. Icon Composer generates light, dark and
/// tinted variants from `resources/MunkiStudio.icon`, and `NSImage`
/// resolves which one to use at *draw* time from the ambient appearance.
/// Inside the wizard that produced a black-backed icon sitting on a white
/// sheet, because the sheet's own surface is light regardless of the
/// system setting. Drawing under an explicit aqua appearance pins the
/// light variant.
///
/// Falls back to the package symbol when there is no icon to load, which
/// is the case for unbundled `swift run` builds with no `Assets.car`.
struct AppIconView: View {
    var size: CGFloat

    var body: some View {
        if let icon = AppIcon.light(size: size) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: size * 0.72, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.munkiStudioBrand)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// Renders and caches the light rendering of the application icon.
@MainActor
private enum AppIcon {
    private static var cache: [CGFloat: NSImage] = [:]

    /// The icon straight out of the asset catalog, by `CFBundleIconName`.
    ///
    /// This is the one that carries the `NSAppearanceNameAqua` and
    /// `NSAppearanceNameDarkAqua` variants and so responds to the drawing
    /// appearance. `NSImage.applicationIconName` resolves to the flattened
    /// `.icns`, which has a single baked-in rendering — that is why the
    /// icon came out dark on a light sheet.
    private static func catalogIcon() -> NSImage? {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String
        else { return nil }
        return NSImage(named: name)
    }

    /// The app icon drawn under the aqua appearance at `size` points.
    /// `nil` when the process has no application icon to draw.
    static func light(size: CGFloat) -> NSImage? {
        if let cached = cache[size] { return cached }
        guard let source = catalogIcon() ?? NSImage(named: NSImage.applicationIconName) else {
            return nil
        }

        // Rasterise at the display's scale so the icon stays crisp — the
        // hero draws it well above the 128pt representations in the icns.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = Int((size * scale).rounded())
        guard pixels > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        if let aqua = NSAppearance(named: .aqua) {
            aqua.performAsCurrentDrawingAppearance {
                source.draw(in: bounds)
            }
        } else {
            source.draw(in: bounds)
        }
        NSGraphicsContext.restoreGraphicsState()

        let rendered = NSImage(size: NSSize(width: size, height: size))
        rendered.addRepresentation(rep)
        cache[size] = rendered
        return rendered
    }
}
