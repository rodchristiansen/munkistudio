import SwiftUI
import Core

/// Right column of the Profiles tab — monospaced XML editor with a
/// status strip above. The strip shows a one-line valid / N issues
/// summary; clicking the chevron expands the per-issue list with line
/// and column numbers. The XML uses the full pane width so users have
/// room to read deep payloads.
struct ProfileDetailView: View {
    @Environment(ProfileStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let record = selectedRecord {
            ProfileEditor(record: record).id(record.id)
        } else if settings.profilesDirectoryPath.trimmingCharacters(in: .whitespaces).isEmpty {
            // Suppress the "No profile selected" message in this case —
            // it competes with the left-column empty state and confuses
            // the user. Just show a neutral background.
            Color.clear
        } else {
            ContentUnavailableView(
                "No profile selected",
                systemImage: "doc.text",
                description: Text("Pick a profile from the list to view and edit its XML.")
            )
        }
    }

    private var selectedRecord: ProfileRecord? {
        guard let url = store.selectedID else { return nil }
        return store.records.first { $0.fileURL == url }
    }
}

private struct ProfileEditor: View {
    @Environment(ProfileStore.self) private var store
    let record: ProfileRecord

    @State private var issuesExpanded = false

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var xmlBinding: Binding<String> {
        Binding(
            get: { store.currentXML(for: record) },
            set: { store.setDraftXML($0, for: record) }
        )
    }

    private var isDirty: Bool {
        store.drafts[record.fileURL] != nil
    }

    private var issues: [MobileConfigValidator.ValidationIssue] {
        MobileConfigValidator.validate(store.currentXML(for: record))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statusStrip
            if issuesExpanded && !issues.isEmpty {
                Divider()
                issueList
            }
            Divider()
            editor
        }
        .alert("Save Failed", isPresented: saveErrorPresented) {
            Button("OK", role: .cancel) { store.saveError = nil }
        } message: {
            Text(store.saveError ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.listLabel)
                        .font(.title3.weight(.semibold))
                    if isDirty {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                            .help("Unsaved changes")
                    }
                }
                if let identifier = record.profile.identifier {
                    Text(identifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let modifiedAt = record.modifiedAt {
                Text(Self.timestampFormatter.string(from: modifiedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([record.fileURL])
            } label: {
                Label("Reveal", systemImage: "magnifyingglass")
            }
            .help("Reveal in Finder")
            Button {
                store.revertDraft(for: record)
            } label: {
                Label("Revert", systemImage: "arrow.uturn.backward")
            }
            .disabled(!isDirty)
            Button {
                Task { await store.save(record) }
            } label: {
                Label("Save", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!isDirty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Status strip

    private var statusStrip: some View {
        let errors = issues.filter { $0.severity == .error }.count
        let warnings = issues.filter { $0.severity == .warning }.count
        return Button {
            if !issues.isEmpty { issuesExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                statusIcon(errors: errors, warnings: warnings)
                statusText(errors: errors, warnings: warnings)
                if !issues.isEmpty {
                    Text(issuesExpanded ? "hide details" : "show details")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !issues.isEmpty {
                    Image(systemName: issuesExpanded ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(issues.isEmpty)
    }

    @ViewBuilder
    private func statusIcon(errors: Int, warnings: Int) -> some View {
        if errors == 0 && warnings == 0 {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        } else if errors > 0 {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func statusText(errors: Int, warnings: Int) -> some View {
        if errors == 0 && warnings == 0 {
            Text("Valid").font(.callout.weight(.medium))
        } else if errors > 0 {
            HStack(spacing: 6) {
                Text("\(errors) error\(errors == 1 ? "" : "s")")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
                if warnings > 0 {
                    Text("· \(warnings) warning\(warnings == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("\(warnings) warning\(warnings == 1 ? "" : "s")")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
        }
    }

    // MARK: Issue list (expanded)

    private var issueList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: issue.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                        .imageScale(.small)
                        .frame(width: 16)
                    Text(issue.displayMessage)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                if index < issues.count - 1 { Divider().padding(.leading, 16) }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    // MARK: Editor

    private var editor: some View {
        TextEditor(text: xmlBinding)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .padding(10)
    }

    private var saveErrorPresented: Binding<Bool> {
        Binding(
            get: { store.saveError != nil },
            set: { if !$0 { store.saveError = nil } }
        )
    }
}
