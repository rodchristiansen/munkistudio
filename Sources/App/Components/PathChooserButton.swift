import SwiftUI
import UniformTypeIdentifiers

/// A "Choose…" button that drives a SwiftUI `.fileImporter` and writes
/// the picked path into the bound `String`. Replaces the previous
/// `NSOpenPanel` helpers scattered through Settings / Onboarding etc.
///
/// Two flavours:
/// - ``folder()``  — single-folder picker
/// - ``file(types:)`` — single-file picker scoped to a type list
struct PathChooserButton: View {
    enum Kind {
        case folder
        case file(allowedContentTypes: [UTType])
    }

    let title: String
    let kind: Kind
    @Binding var path: String

    @State private var presented = false

    init(_ title: String = "Choose\u{2026}", kind: Kind, path: Binding<String>) {
        self.title = title
        self.kind = kind
        self._path = path
    }

    /// Convenience for a single-folder picker.
    static func folder(_ title: String = "Choose\u{2026}", path: Binding<String>) -> PathChooserButton {
        PathChooserButton(title, kind: .folder, path: path)
    }

    /// Convenience for a single-file picker scoped to `types`.
    static func file(
        _ title: String = "Choose\u{2026}",
        types: [UTType],
        path: Binding<String>
    ) -> PathChooserButton {
        PathChooserButton(title, kind: .file(allowedContentTypes: types), path: path)
    }

    var body: some View {
        Button(title) { presented = true }
            .fileImporter(
                isPresented: $presented,
                allowedContentTypes: contentTypes,
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    path = url.path
                }
            }
    }

    private var contentTypes: [UTType] {
        switch kind {
        case .folder: [.folder]
        case .file(let types): types
        }
    }
}
