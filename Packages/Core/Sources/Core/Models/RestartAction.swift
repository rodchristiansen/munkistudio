import Foundation

/// `RestartAction` is unusual in the pkginfo schema in that the key itself is
/// capitalized (PascalCase), as are its values. We preserve that on disk via an
/// explicit CodingKey on the enclosing model.
public enum RestartAction: String, Sendable, Hashable, Codable, CaseIterable {
    case none = "None"
    case requireLogout = "RequireLogout"
    case requireRestart = "RequireRestart"
    case requireShutdown = "RequireShutdown"
    case recommendRestart = "RecommendRestart"
}
