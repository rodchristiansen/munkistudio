import Foundation

/// Entry in `items_to_copy[]` — used with `installer_type: copy_from_dmg` to
/// describe a file/directory to copy from a mounted DMG.
public struct ItemToCopy: Sendable, Hashable, Codable {
    public var sourceItem: String
    public var destinationPath: String?
    public var destinationItem: String?
    public var user: String?
    public var group: String?
    public var mode: String?
    public var preservedAttributes: [String]?

    public init(
        sourceItem: String,
        destinationPath: String? = nil,
        destinationItem: String? = nil,
        user: String? = nil,
        group: String? = nil,
        mode: String? = nil,
        preservedAttributes: [String]? = nil
    ) {
        self.sourceItem = sourceItem
        self.destinationPath = destinationPath
        self.destinationItem = destinationItem
        self.user = user
        self.group = group
        self.mode = mode
        self.preservedAttributes = preservedAttributes
    }

    enum CodingKeys: String, CodingKey {
        case sourceItem = "source_item"
        case destinationPath = "destination_path"
        case destinationItem = "destination_item"
        case user
        case group
        case mode
        case preservedAttributes = "preserved_attributes"
    }
}
