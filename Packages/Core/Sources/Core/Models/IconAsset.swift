import Foundation

/// A `.png` (occasionally `.icns`) file under `icons/` in the repo. The
/// SHA256 hash is what makecatalogs writes into `_icon_hashes.plist`; clients
/// use it to short-circuit downloads when their cached copy already matches.
public struct IconAsset: Sendable, Hashable {
    public var filename: String
    public var sha256: String?
    public var byteSize: Int?

    public init(filename: String, sha256: String? = nil, byteSize: Int? = nil) {
        self.filename = filename
        self.sha256 = sha256
        self.byteSize = byteSize
    }
}
