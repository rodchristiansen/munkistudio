import Foundation

/// Snapshots emitted by the scanner describe all active workers, not just the
/// last app to finish. This keeps a slow lookup from looking like a stuck app.
public struct CVEScanProgress: Decodable, Sendable {
    public let phase: String
    public let completed: Int
    public let total: Int
    public let active: [Lookup]

    public struct Lookup: Decodable, Sendable {
        public let name: String
        public let page: Int
        public let attempt: Int
        public let status: String
        public let detail: String?
    }

    public static func parse(_ line: String) -> CVEScanProgress? {
        let prefix = "CVE_PROGRESS "
        guard line.hasPrefix(prefix),
              let value = try? JSONDecoder().decode(Self.self, from: Data(line.dropFirst(prefix.count).utf8)),
              ["querying", "assessing", "saving"].contains(value.phase),
              value.total >= 0, value.completed >= 0, value.completed <= value.total,
              value.active.allSatisfy({ !$0.name.isEmpty && $0.page > 0 && (1...3).contains($0.attempt) })
        else { return nil }
        return value
    }

    public var summary: String {
        let count = "\(completed)/\(total) apps checked"
        switch phase {
        case "assessing": return count + " · Assessing advisory and version evidence…"
        case "saving": return count + " · Saving the updated report…"
        default:
            if active.isEmpty {
                return count + (completed == total ? " · Finishing lookups…" : " · Starting lookups…")
            }
            return count + " · " + active.map { lookup in
                let action = lookup.status == "retrying" ? "Retrying" : "Checking"
                let detail = lookup.detail.map { ", \($0)" } ?? ""
                return "\(action) \(lookup.name) (page \(lookup.page), attempt \(lookup.attempt)/3\(detail))"
            }.joined(separator: "; ")
        }
    }
}
