import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
        MobileConfigValidator.validate(
            store.currentXML(for: record),
            schema: store.payloadSchema
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statusStrip
            if !issues.isEmpty {
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
        HStack(spacing: 10) {
            Text(record.listLabel)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if isDirty {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
            Spacer(minLength: 12)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([record.fileURL])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Reveal in Finder")
            openWithMenu
            Button {
                store.revertDraft(for: record)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Revert unsaved changes")
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
        .padding(.vertical, 8)
    }

    // MARK: Open With menu

    /// Offer to open the profile in a dedicated editor. Detects each
    /// candidate's installed bundle URL when the menu opens and either
    /// hands the file to that app via `NSWorkspace` or, when the app is
    /// missing, deep-links to its download page. An "Other…" entry
    /// falls through to a standard NSOpenPanel chooser so the user can
    /// pick any installed app the system suggests for `.mobileconfig`.
    private var openWithMenu: some View {
        Menu {
            let imazing = Self.installedApp(bundleIDs: [
                "com.DigiDNA.iMazingProfileEditorMac",
                "com.DigiDNA.iMazingProfileEditor",
                "com.dynamic-lynx.imazing-profile-editor",
                "com.imazing.profileeditor"
            ])
            let lowProfile = Self.installedApp(bundleIDs: [
                "com.ninxsoft.lowprofile",
                "com.ninxsoft.LowProfile",
                "nz.co.ninxsoft.LowProfile"
            ])

            if let imazing {
                Button("Open in iMazing Profile Editor") {
                    open(in: imazing)
                }
            } else {
                Button("Get iMazing Profile Editor…") {
                    if let url = URL(string: "https://imazing.com/profile-editor") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            if let lowProfile {
                Button("Open in Low Profile") {
                    open(in: lowProfile)
                }
            } else {
                Button("Get Low Profile…") {
                    if let url = URL(string: "https://github.com/ninxsoft/LowProfile") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Divider()
            Button("Other Application…") { chooseAndOpen() }
        } label: {
            Label("Open With", systemImage: "arrow.up.forward.app")
        }
        .fixedSize()
        .help("Open this .mobileconfig in iMazing Profile Editor, Low Profile, or another app")
    }

    private func open(in appURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [record.fileURL],
            withApplicationAt: appURL,
            configuration: configuration
        )
    }

    private func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.title = "Choose Application"
        if panel.runModal() == .OK, let appURL = panel.url {
            open(in: appURL)
        }
    }

    /// Walk a list of plausible bundle IDs and return the first one the
    /// system can resolve to an installed app. Different distributions
    /// of iMazing Profile Editor and Low Profile have shipped under
    /// slightly different bundle IDs over time; trying a small list is
    /// more robust than hardcoding one.
    private static func installedApp(bundleIDs: [String]) -> URL? {
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        return nil
    }

    // MARK: Status strip

    private var statusStrip: some View {
        let errors = issues.filter { $0.severity == .error }.count
        let warnings = issues.filter { $0.severity == .warning }.count
        return HStack(spacing: 8) {
            statusIcon(errors: errors, warnings: warnings)
            statusText(errors: errors, warnings: warnings)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
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

    // MARK: Issue list — always visible when issues exist

    private var issueList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(issues, id: \.id) { issue in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: issue.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                        .imageScale(.small)
                        .frame(width: 14)
                    Text(issue.displayMessage)
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
