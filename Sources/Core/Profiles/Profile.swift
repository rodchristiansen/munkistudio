import Foundation

/// Parsed top-level metadata for a `.mobileconfig` profile. The on-disk
/// XML is preserved verbatim in `ProfileRecord.xmlString`; this struct
/// just surfaces the fields the list view needs.
public struct Profile: Sendable, Hashable {
    public var identifier: String?
    public var uuid: String?
    public var displayName: String?
    public var organization: String?
    public var profileType: String?
    public var version: Int?
    public var payloadCount: Int

    public init(
        identifier: String? = nil,
        uuid: String? = nil,
        displayName: String? = nil,
        organization: String? = nil,
        profileType: String? = nil,
        version: Int? = nil,
        payloadCount: Int = 0
    ) {
        self.identifier = identifier
        self.uuid = uuid
        self.displayName = displayName
        self.organization = organization
        self.profileType = profileType
        self.version = version
        self.payloadCount = payloadCount
    }
}

/// A profile on disk — the raw XML string, the parsed metadata, and the
/// file URL. The list view shows the parsed metadata; the editor edits
/// the XML directly.
public struct ProfileRecord: Sendable, Hashable, Identifiable {
    public var profile: Profile
    public var fileURL: URL
    public var xmlString: String
    public var createdAt: Date?
    public var modifiedAt: Date?
    /// PKCS#7 signing state for the file as it sits on disk —
    /// `.unsigned` for plain-XML profiles, `.signed(signers:)` when
    /// the file is wrapped in a CMS envelope. Detected once at load
    /// time and reused on every render.
    public var signature: ProfileSignature

    public var id: URL { fileURL }

    /// `displayName` if set; otherwise the file name without extension.
    public var listLabel: String {
        if let displayName = profile.displayName, !displayName.isEmpty {
            return displayName
        }
        return fileURL.deletingPathExtension().lastPathComponent
    }

    public init(
        profile: Profile,
        fileURL: URL,
        xmlString: String,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        signature: ProfileSignature = .unsigned
    ) {
        self.profile = profile
        self.fileURL = fileURL
        self.xmlString = xmlString
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.signature = signature
    }
}
