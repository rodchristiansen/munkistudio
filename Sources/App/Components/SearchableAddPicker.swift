import SwiftUI

/// `+ Add …` row that opens a popover with a search field and a
/// filtered list of valid options. Used by the manifest item list
/// editors so admins can find an entry in a 1,200-row repo by typing,
/// instead of scrolling a Menu.
///
/// `availableNames` is the unfiltered set; rows the caller has already
/// added should be excluded by the caller before passing them in.
struct SearchableAddPicker: View {
    let placeholder: String
    let availableNames: [String]
    let onAdd: (String) -> Void

    @State private var isOpen = false
    @State private var query: String = ""
    @FocusState private var queryFocused: Bool

    private var matches: [String] {
        guard !query.isEmpty else { return availableNames }
        let q = query.lowercased()
        return availableNames.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        // Two-part row: a tight `+` Button on the left anchors the
        // popover, then a clickable text label that also opens the
        // popover so the whole row still feels actionable. Anchoring
        // to the small `+` keeps the popover from appearing in the
        // middle of the page.
        HStack(spacing: 6) {
            Button {
                isOpen = true
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(availableNames.isEmpty)
            .popover(
                isPresented: $isOpen,
                attachmentAnchor: .point(.bottomLeading),
                arrowEdge: .top
            ) {
                popoverBody
            }
            Button {
                isOpen = true
            } label: {
                Text(placeholder)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(availableNames.isEmpty)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    private var popoverBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onSubmit { commitFirstMatch() }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            Divider()
            // Scrollable list of matches. Capped so the popover doesn't
            // grow to fullscreen on a thousand-package repo.
            ScrollView {
                LazyVStack(spacing: 0) {
                    if matches.isEmpty {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        ForEach(matches, id: \.self) { name in
                            Button {
                                onAdd(name)
                                isOpen = false
                                query = ""
                            } label: {
                                Text(name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 320)
        .onAppear { queryFocused = true }
    }

    private func commitFirstMatch() {
        guard let first = matches.first else { return }
        onAdd(first)
        isOpen = false
        query = ""
    }
}
