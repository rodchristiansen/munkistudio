import SwiftUI

/// Placeholder kept to preserve existing routing. The Git pane is a
/// single, full-width view (see ``GitView``) rather than the standard
/// list+detail split, so the detail column is always empty.
struct GitDetailView: View {
    var body: some View {
        Color.clear
    }
}
