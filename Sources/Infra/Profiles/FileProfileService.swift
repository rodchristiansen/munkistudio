import Foundation
import Core

/// File-backed `ProfileService`. Walks a directory recursively for
/// `.mobileconfig` files, parses each as a plist, and surfaces the
/// top-level metadata. Saves write the raw XML provided by the editor —
/// the validator runs separately and never gates a save.
public struct FileProfileService: ProfileService {
    public init() {}

    // MARK: Load

    public func load(in directory: URL) async throws -> [ProfileRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        let urls = try discoverMobileConfigs(in: directory)
        var records: [ProfileRecord] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let xml = String(decoding: data, as: UTF8.self)
                let signature = ProfileSignatureDetector.detect(data: data)
                let profile = Self.parseProfile(from: data) ?? Profile()
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                records.append(ProfileRecord(
                    profile: profile,
                    fileURL: url,
                    xmlString: xml,
                    createdAt: attrs?[.creationDate] as? Date,
                    modifiedAt: attrs?[.modificationDate] as? Date,
                    signature: signature
                ))
            } catch {
                // Unreadable files still appear — empty content lets the
                // editor surface the underlying I/O issue.
                records.append(ProfileRecord(
                    profile: Profile(),
                    fileURL: url,
                    xmlString: ""
                ))
            }
        }
        records.sort { lhs, rhs in
            lhs.fileURL.path.localizedCaseInsensitiveCompare(rhs.fileURL.path) == .orderedAscending
        }
        return records
    }

    /// Recursively enumerate `.mobileconfig` files under `directory`.
    private func discoverMobileConfigs(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "mobileconfig" else { continue }
            let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegularFile else { continue }
            results.append(url)
        }
        return results
    }

    // MARK: Parse

    /// Extract top-level profile metadata from raw .mobileconfig data.
    /// Returns `nil` if the file doesn't parse as a plist dictionary —
    /// the caller substitutes an empty `Profile` so the file still
    /// shows up in the list.
    public static func parseProfile(from data: Data) -> Profile? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any] else {
            return nil
        }
        let payloads = (dict["PayloadContent"] as? [[String: Any]]) ?? []
        return Profile(
            identifier: dict["PayloadIdentifier"] as? String,
            uuid: dict["PayloadUUID"] as? String,
            displayName: dict["PayloadDisplayName"] as? String,
            organization: dict["PayloadOrganization"] as? String,
            profileType: dict["PayloadType"] as? String,
            version: dict["PayloadVersion"] as? Int,
            payloadCount: payloads.count
        )
    }

    // MARK: Save

    public func save(_ record: ProfileRecord, xmlString: String) async throws -> ProfileRecord {
        guard let data = xmlString.data(using: .utf8) else {
            throw ProfileError.encodingFailed
        }
        try AtomicWrite.write(data, to: record.fileURL)
        let profile = Self.parseProfile(from: data) ?? record.profile
        let attrs = try? FileManager.default.attributesOfItem(atPath: record.fileURL.path)
        return ProfileRecord(
            profile: profile,
            fileURL: record.fileURL,
            xmlString: xmlString,
            createdAt: record.createdAt ?? attrs?[.creationDate] as? Date,
            modifiedAt: attrs?[.modificationDate] as? Date ?? Date()
        )
    }

    // MARK: Create / Rename / Duplicate / Delete

    public func create(named name: String, in directory: URL) async throws -> ProfileRecord {
        let url = try targetURL(forName: name, in: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            throw ProfileError.alreadyExists(url)
        }
        let displayName = url.deletingPathExtension().lastPathComponent
        let xml = Self.starterXML(displayName: displayName)
        let data = Data(xml.utf8)
        try AtomicWrite.write(data, to: url)
        let profile = Self.parseProfile(from: data) ?? Profile(displayName: displayName)
        return ProfileRecord(
            profile: profile,
            fileURL: url,
            xmlString: xml,
            createdAt: Date(),
            modifiedAt: Date()
        )
    }

    public func rename(
        _ record: ProfileRecord,
        to newName: String,
        in directory: URL
    ) async throws -> ProfileRecord {
        let destination = try targetURL(forName: newName, in: directory)
        if destination == record.fileURL { return record }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw ProfileError.alreadyExists(destination)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: record.fileURL, to: destination)
        let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
        return ProfileRecord(
            profile: record.profile,
            fileURL: destination,
            xmlString: record.xmlString,
            createdAt: record.createdAt,
            modifiedAt: attrs?[.modificationDate] as? Date
        )
    }

    public func duplicate(
        _ record: ProfileRecord,
        as newName: String,
        in directory: URL
    ) async throws -> ProfileRecord {
        let destination = try targetURL(forName: newName, in: directory)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw ProfileError.alreadyExists(destination)
        }
        let regenerated = Self.regenerateIdentity(xml: record.xmlString, newDisplayName: destination.deletingPathExtension().lastPathComponent)
        let data = Data(regenerated.utf8)
        try AtomicWrite.write(data, to: destination)
        let profile = Self.parseProfile(from: data) ?? record.profile
        return ProfileRecord(
            profile: profile,
            fileURL: destination,
            xmlString: regenerated,
            createdAt: Date(),
            modifiedAt: Date()
        )
    }

    public func delete(_ record: ProfileRecord) async throws {
        try FileManager.default.removeItem(at: record.fileURL)
    }

    // MARK: Helpers

    /// Resolve a `name` (which may contain slashes for nesting) into a
    /// destination URL inside `directory`. The `.mobileconfig` extension
    /// is appended if missing. Slashes in any individual component are
    /// rejected — they would break the path resolution.
    private func targetURL(forName name: String, in directory: URL) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileError.invalidName(name) }
        let segments = trimmed.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { throw ProfileError.invalidName(name) }
        for segment in segments where segment.isEmpty {
            throw ProfileError.invalidName(name)
        }
        var url = directory
        for (index, segment) in segments.enumerated() {
            if index == segments.count - 1 {
                let withExt = segment.hasSuffix(".mobileconfig") ? segment : segment + ".mobileconfig"
                url.append(path: withExt)
            } else {
                url.append(path: segment)
            }
        }
        return url
    }

    /// Replace the top-level PayloadUUID and PayloadIdentifier inside an
    /// existing profile XML so a duplicate doesn't collide with the
    /// original. Falls back to the input verbatim if the regeneration
    /// can't be applied cleanly (malformed XML).
    public static func regenerateIdentity(xml: String, newDisplayName: String) -> String {
        guard let data = xml.data(using: .utf8),
              var object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return xml
        }
        let newUUID = UUID().uuidString
        object["PayloadUUID"] = newUUID
        if let oldIdentifier = object["PayloadIdentifier"] as? String, !oldIdentifier.isEmpty {
            object["PayloadIdentifier"] = oldIdentifier + ".copy-" + newUUID.prefix(8)
        } else {
            object["PayloadIdentifier"] = "com.munkistudio.profile.\(newUUID.prefix(8))"
        }
        object["PayloadDisplayName"] = newDisplayName
        guard let xmlData = try? PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        ) else {
            return xml
        }
        return String(decoding: xmlData, as: UTF8.self)
    }

    /// Render the starter body for a new profile. Built from the
    /// embedded `MainProfileTemplate` — annotated example payloads,
    /// matched UUIDs, and the user's name substituted into both the
    /// outer PayloadDisplayName and the inner identifier scheme — so
    /// new profiles arrive as a teaching artifact rather than an
    /// empty Configuration dict.
    public static func starterXML(displayName: String) -> String {
        MainProfileTemplate.rendered(forName: displayName)
    }
}

public enum ProfileError: Error, LocalizedError {
    case alreadyExists(URL)
    case invalidName(String)
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let url):
            return "A profile already exists at \(url.path)."
        case .invalidName(let name):
            return "\"\(name)\" isn't a valid profile name."
        case .encodingFailed:
            return "Couldn't encode the profile body as UTF-8."
        }
    }
}
