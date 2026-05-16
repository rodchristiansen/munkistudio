import SwiftUI
import Core

/// A commit context-menu action awaiting confirmation / input.
enum CommitAction: Identifiable {
    case addTag(GitCommit)
    case createBranch(GitCommit)
    case checkout(GitCommit)
    case cherryPick(GitCommit)
    case revert(GitCommit)
    case merge(GitCommit)
    case rebase(GitCommit)
    case reset(GitCommit)

    var commit: GitCommit {
        switch self {
        case .addTag(let c), .createBranch(let c), .checkout(let c),
             .cherryPick(let c), .revert(let c), .merge(let c),
             .rebase(let c), .reset(let c):
            return c
        }
    }

    var id: String {
        switch self {
        case .addTag: "tag-\(commit.sha)"
        case .createBranch: "branch-\(commit.sha)"
        case .checkout: "checkout-\(commit.sha)"
        case .cherryPick: "pick-\(commit.sha)"
        case .revert: "revert-\(commit.sha)"
        case .merge: "merge-\(commit.sha)"
        case .rebase: "rebase-\(commit.sha)"
        case .reset: "reset-\(commit.sha)"
        }
    }
}

/// What the sheet hands back once the user confirms.
enum CommitActionRequest {
    case addTag(commit: GitCommit, name: String, message: String)
    case createBranch(commit: GitCommit, name: String)
    case checkout(GitCommit)
    case cherryPick(GitCommit)
    case revert(GitCommit)
    case merge(GitCommit)
    case rebase(GitCommit)
    case reset(commit: GitCommit, mode: GitResetMode)
}

/// Confirmation / input sheet for a commit context-menu action.
struct GitCommitActionSheet: View {
    let action: CommitAction
    let currentBranch: String?
    let perform: (CommitActionRequest) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tagName = ""
    @State private var tagMessage = ""
    @State private var branchName = ""
    @State private var resetMode: GitResetMode = .soft
    @State private var running = false

    private var branch: String { currentBranch ?? "the current branch" }
    private var shortSHA: String { String(action.commit.sha.prefix(8)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button(confirmLabel, role: isDestructive ? .destructive : nil) {
                    guard let request else { return }
                    Task {
                        running = true
                        await perform(request)
                        running = false
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm || running)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch action {
        case .addTag:
            Text("Tag commit \(shortSHA).")
                .font(.callout).foregroundStyle(.secondary)
            field("Tag name", "v1.0.0", $tagName)
            field("Message (optional — annotated tag)", "Release notes…", $tagMessage)
        case .createBranch:
            Text("Create a branch pointing at commit \(shortSHA).")
                .font(.callout).foregroundStyle(.secondary)
            field("Branch name", "feature/my-change", $branchName)
        case .checkout:
            Text("Check out commit \(shortSHA). This detaches HEAD — you won't be on a branch.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .cherryPick:
            Text("Apply commit \(shortSHA) on top of \(branch).")
                .font(.callout).foregroundStyle(.secondary)
        case .revert:
            Text("Create a new commit that undoes \(shortSHA).")
                .font(.callout).foregroundStyle(.secondary)
        case .merge:
            Text("Merge commit \(shortSHA) into \(branch).")
                .font(.callout).foregroundStyle(.secondary)
        case .rebase:
            Text("Replay \(branch)'s commits on top of \(shortSHA).")
                .font(.callout).foregroundStyle(.secondary)
        case .reset:
            Text("Reset \(branch) to commit \(shortSHA).")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Mode", selection: $resetMode) {
                Text("Soft — keep all changes, move HEAD only").tag(GitResetMode.soft)
                Text("Mixed — keep working tree, reset the index").tag(GitResetMode.mixed)
                Text("Hard — discard all uncommitted changes").tag(GitResetMode.hard)
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private var title: String {
        switch action {
        case .addTag: "Add Tag"
        case .createBranch: "Create Branch"
        case .checkout: "Checkout Commit"
        case .cherryPick: "Cherry-Pick Commit"
        case .revert: "Revert Commit"
        case .merge: "Merge into \(branch)"
        case .rebase: "Rebase \(branch)"
        case .reset: "Reset \(branch)"
        }
    }

    private var confirmLabel: String {
        switch action {
        case .addTag: "Add Tag"
        case .createBranch: "Create"
        case .checkout: "Checkout"
        case .cherryPick: "Cherry-Pick"
        case .revert: "Revert"
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .reset: "Reset"
        }
    }

    private var isDestructive: Bool {
        switch action {
        case .reset, .rebase: true
        default: false
        }
    }

    private var canConfirm: Bool {
        switch action {
        case .addTag: !tagName.trimmingCharacters(in: .whitespaces).isEmpty
        case .createBranch: !branchName.trimmingCharacters(in: .whitespaces).isEmpty
        default: true
        }
    }

    private var request: CommitActionRequest? {
        switch action {
        case .addTag(let c):
            .addTag(commit: c,
                    name: tagName.trimmingCharacters(in: .whitespaces),
                    message: tagMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        case .createBranch(let c):
            .createBranch(commit: c, name: branchName.trimmingCharacters(in: .whitespaces))
        case .checkout(let c): .checkout(c)
        case .cherryPick(let c): .cherryPick(c)
        case .revert(let c): .revert(c)
        case .merge(let c): .merge(c)
        case .rebase(let c): .rebase(c)
        case .reset(let c): .reset(commit: c, mode: resetMode)
        }
    }
}
