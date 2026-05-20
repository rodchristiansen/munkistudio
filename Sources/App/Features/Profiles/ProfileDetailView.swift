import SwiftUI
import Core

/// Right column of the Profiles tab — monospaced XML editor with a live
/// validation panel. Save / Revert / Reveal in Finder live in the
/// inline toolbar; per-row destructive actions stay in the list's
/// context menu.
struct ProfileDetailView: View {
    @Environment(ProfileStore.self) private var store

    var body: some View {
        if let record = selectedRecord {
            ProfileEditor(record: record).id(record.id)
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                editorPane
                lintPane
                    .frame(minWidth: 240, idealWidth: 300)
            }
        }
        .alert("Save Failed", isPresented: saveErrorPresented) {
            Button("OK", role: .cancel) { store.saveError = nil }
        } message: {
            Text(store.saveError ?? "")
        }
    }

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
                }
            }
            Spacer()
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

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("XML")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let modifiedAt = record.modifiedAt {
                    Text("Modified " + Self.timestampFormatter.string(from: modifiedAt))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            TextEditor(text: xmlBinding)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                )
                .padding(.bottom, 8)
        }
    }

    private var lintPane: some View {
        let xml = store.currentXML(for: record)
        let issues = MobileConfigValidator.validate(xml)
        let errors = issues.filter { $0.severity == .error }
        let warnings = issues.filter { $0.severity == .warning }
        return VStack(alignment: .leading, spacing: 12) {
            statusHeader(errors: errors.count, warnings: warnings.count)
            metadataCard
            Divider()
            if issues.isEmpty {
                Label("No issues found.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(issues) { issue in
                            issueRow(issue)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func statusHeader(errors: Int, warnings: Int) -> some View {
        HStack(spacing: 8) {
            if errors == 0 && warnings == 0 {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Valid").font(.headline)
            } else if errors > 0 {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                Text("\(errors) error\(errors == 1 ? "" : "s")").font(.headline)
                if warnings > 0 {
                    Text("· \(warnings) warning\(warnings == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(warnings) warning\(warnings == 1 ? "" : "s")").font(.headline)
            }
            Spacer()
        }
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            metadataRow("Identifier", record.profile.identifier)
            metadataRow("UUID", record.profile.uuid)
            metadataRow("Display name", record.profile.displayName)
            metadataRow("Organization", record.profile.organization)
            metadataRow("Type", record.profile.profileType)
            metadataRow("Payloads", "\(record.profile.payloadCount)")
        }
        .font(.caption)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 92, alignment: .trailing)
            Text(value ?? "—")
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func issueRow(_ issue: MobileConfigValidator.ValidationIssue) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: issue.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                .imageScale(.small)
                .padding(.top, 2)
            Text(issue.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var saveErrorPresented: Binding<Bool> {
        Binding(
            get: { store.saveError != nil },
            set: { if !$0 { store.saveError = nil } }
        )
    }
}
