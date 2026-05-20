import Foundation

/// Read / write `.mobileconfig` profiles in a user-chosen directory. The
/// directory is independent of the open Munki repository — profiles are
/// often stored next to or outside the Munki repo, and the user
/// configures the path in Settings → Features.
public protocol ProfileService: Sendable {
    /// Walk `directory` recursively and load every `.mobileconfig`. A
    /// file that fails to parse still appears in the returned list with
    /// `profile == Profile()` (all-nil metadata) so the editor can show
    /// it and the user can fix the XML by hand.
    func load(in directory: URL) async throws -> [ProfileRecord]

    /// Persist a profile's current XML to its `fileURL`. Writes are
    /// atomic — readers either see the previous version or the new one.
    func save(_ record: ProfileRecord, xmlString: String) async throws -> ProfileRecord

    /// Create a new profile in `directory` with a name like
    /// `subdir/MyProfile`. Slashes nest into subdirectories. The body
    /// is a minimal Configuration profile stub.
    func create(named name: String, in directory: URL) async throws -> ProfileRecord

    /// Rename a profile. Slashes in `newName` move it between
    /// subdirectories.
    func rename(_ record: ProfileRecord, to newName: String, in directory: URL) async throws -> ProfileRecord

    /// Duplicate a profile's XML under a new name. Identifier and UUID
    /// inside the copy are regenerated so the duplicate is a distinct
    /// profile rather than a collision.
    func duplicate(_ record: ProfileRecord, as newName: String, in directory: URL) async throws -> ProfileRecord

    func delete(_ record: ProfileRecord) async throws
}
