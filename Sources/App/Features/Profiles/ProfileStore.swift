import Foundation
import Observation
import Core
import Infra

/// State for the Profiles tab. Independent of `RepositoryStore` because
/// the profiles directory is configured separately from the open Munki
/// repo. Lives at the app scope so navigating away and back preserves
/// drafts and selection.
@Observable
@MainActor
final class ProfileStore {
    /// Loaded profile records, sorted by path.
    var records: [ProfileRecord] = []

    /// Selected record's `fileURL`. Nil shows the empty detail state.
    var selectedID: URL?

    /// In-progress XML edits keyed by file URL. Removed when the user
    /// reverts the draft to match the saved bytes.
    var drafts: [URL: String] = [:]

    /// Folder paths currently expanded in the tree (relative to the
    /// profiles directory).
    var expandedPaths: Set<String> = []

    /// Surfaces the last lifecycle error (create / rename / duplicate /
    /// delete) as an alert in the list view.
    var actionError: String?

    /// Surfaces the last save error from the detail view.
    var saveError: String?

    var loadState: LoadState = .idle

    let service: any ProfileService

    init(service: any ProfileService = FileProfileService()) {
        self.service = service
    }

    // MARK: Loading

    func reload(directory: URL?) async {
        guard let directory else {
            records = []
            loadState = .idle
            return
        }
        loadState = .loading
        do {
            let loaded = try await service.load(in: directory)
            records = loaded
            loadState = .ready
            // Drop drafts whose file no longer exists.
            let urls = Set(loaded.map(\.fileURL))
            drafts = drafts.filter { urls.contains($0.key) }
            if let selectedID, !urls.contains(selectedID) {
                self.selectedID = nil
            }
        } catch {
            records = []
            loadState = .failed(message: error.localizedDescription)
        }
    }

    // MARK: Drafts

    func currentXML(for record: ProfileRecord) -> String {
        drafts[record.fileURL] ?? record.xmlString
    }

    func setDraftXML(_ xml: String, for record: ProfileRecord) {
        if xml == record.xmlString {
            drafts.removeValue(forKey: record.fileURL)
        } else {
            drafts[record.fileURL] = xml
        }
    }

    func revertDraft(for record: ProfileRecord) {
        drafts.removeValue(forKey: record.fileURL)
    }

    var dirtyCount: Int { drafts.count }

    // MARK: Save

    func save(_ record: ProfileRecord) async {
        let xml = currentXML(for: record)
        do {
            let updated = try await service.save(record, xmlString: xml)
            replace(record, with: updated)
            drafts.removeValue(forKey: record.fileURL)
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: Lifecycle

    @discardableResult
    func create(named name: String, directory: URL) async -> ProfileRecord? {
        do {
            let record = try await service.create(named: name, in: directory)
            records.append(record)
            records.sort { lhs, rhs in
                lhs.fileURL.path.localizedCaseInsensitiveCompare(rhs.fileURL.path) == .orderedAscending
            }
            selectedID = record.fileURL
            return record
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func rename(_ record: ProfileRecord, to newName: String, directory: URL) async -> ProfileRecord? {
        do {
            let updated = try await service.rename(record, to: newName, in: directory)
            replace(record, with: updated)
            if selectedID == record.fileURL {
                selectedID = updated.fileURL
            }
            return updated
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func duplicate(_ record: ProfileRecord, as newName: String, directory: URL) async -> ProfileRecord? {
        do {
            let copy = try await service.duplicate(record, as: newName, in: directory)
            records.append(copy)
            records.sort { lhs, rhs in
                lhs.fileURL.path.localizedCaseInsensitiveCompare(rhs.fileURL.path) == .orderedAscending
            }
            selectedID = copy.fileURL
            return copy
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    func delete(_ record: ProfileRecord) async {
        do {
            try await service.delete(record)
            records.removeAll { $0.fileURL == record.fileURL }
            drafts.removeValue(forKey: record.fileURL)
            if selectedID == record.fileURL {
                selectedID = nil
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: Helpers

    private func replace(_ old: ProfileRecord, with new: ProfileRecord) {
        if let index = records.firstIndex(where: { $0.fileURL == old.fileURL }) {
            records[index] = new
        } else {
            records.append(new)
        }
        records.sort { lhs, rhs in
            lhs.fileURL.path.localizedCaseInsensitiveCompare(rhs.fileURL.path) == .orderedAscending
        }
        if old.fileURL != new.fileURL, let xml = drafts.removeValue(forKey: old.fileURL) {
            drafts[new.fileURL] = xml
        }
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(message: String)
    }
}
