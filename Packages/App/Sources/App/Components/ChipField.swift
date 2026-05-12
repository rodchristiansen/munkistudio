import SwiftUI

/// Compact multi-value editor. Each value renders as a removable chip;
/// a single text field at the bottom commits a new entry on Return. Used
/// for catalogs, managed installs, blocking applications, architectures.
struct ChipField: View {
    @Binding var values: [String]
    var placeholder: String = "Add value"

    @State private var pending: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !values.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        HStack(spacing: 4) {
                            Text(value).lineLimit(1)
                            Button {
                                values.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(.regularMaterial, in: .capsule)
                    }
                }
            }
            HStack {
                TextField(placeholder, text: $pending)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit() }
                Button("Add", action: commit)
                    .disabled(pending.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func commit() {
        let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        values.append(trimmed)
        pending = ""
    }
}

/// Minimal flow layout — wraps children left-to-right and onto a new line
/// when the row width is exceeded. SwiftUI's `Layout` protocol lets us do
/// this without a third-party dep.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                maxRowWidth = max(maxRowWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, rowWidth - spacing)
        return CGSize(width: maxRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
