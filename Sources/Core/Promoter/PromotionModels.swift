import Foundation

/// One pkginfo that is currently sitting in a `promoteFrom` catalog set
/// for some rule — i.e. a candidate the promoter is tracking. The candidate
/// is eligible to move once the aging window elapses; the user can also
/// promote it early or defer it manually from the Promoter tab.
public struct PromotionCandidate: Sendable, Hashable, Identifiable {
    public var pkginfoURL: URL
    public var pkgName: String
    public var version: String?
    public var currentCatalogs: [String]
    public var targetCatalogs: [String]
    public var ruleName: String
    public var lastEditDate: Date
    public var requiredDays: Int

    public var id: URL { pkginfoURL }

    public init(
        pkginfoURL: URL,
        pkgName: String,
        version: String?,
        currentCatalogs: [String],
        targetCatalogs: [String],
        ruleName: String,
        lastEditDate: Date,
        requiredDays: Int
    ) {
        self.pkginfoURL = pkginfoURL
        self.pkgName = pkgName
        self.version = version
        self.currentCatalogs = currentCatalogs
        self.targetCatalogs = targetCatalogs
        self.ruleName = ruleName
        self.lastEditDate = lastEditDate
        self.requiredDays = requiredDays
    }

    /// Moment the candidate is first eligible for automatic promotion.
    public var eligibleAt: Date {
        Calendar.current.date(byAdding: .day, value: requiredDays, to: lastEditDate) ?? lastEditDate
    }

    public func isEligible(on referenceDate: Date = Date()) -> Bool {
        referenceDate >= eligibleAt
    }

    /// Whole days from `referenceDate` until eligibility. Negative means
    /// already eligible — the UI clamps that to 0 for display.
    public func daysRemaining(on referenceDate: Date = Date()) -> Int {
        let days = Calendar.current.dateComponents([.day], from: referenceDate, to: eligibleAt).day ?? 0
        return days
    }
}

/// One AutoPkg import event — a freshly added pkginfo file from a
/// recipe run. Sourced from `AutoPkg import` git commits over the
/// pkgsinfo subtree.
public struct AutoPkgImport: Sendable, Hashable, Identifiable {
    public var commitHash: String
    public var date: Date
    public var pkgName: String
    public var version: String?
    public var pkginfoURL: URL?
    public var catalogs: [String]

    public var id: String { commitHash + "::" + (pkginfoURL?.path ?? pkgName) }

    public init(
        commitHash: String,
        date: Date,
        pkgName: String,
        version: String?,
        pkginfoURL: URL?,
        catalogs: [String]
    ) {
        self.commitHash = commitHash
        self.date = date
        self.pkgName = pkgName
        self.version = version
        self.pkginfoURL = pkginfoURL
        self.catalogs = catalogs
    }
}

/// One promoter run, derived from a `Promoter: …` git commit over the
/// pkgsinfo subtree. The `affected` list is the pkginfo files touched
/// by that commit.
public struct PromotionHistoryEntry: Sendable, Hashable, Identifiable {
    public var commitHash: String
    public var date: Date
    public var subject: String
    public var affected: [URL]

    public var id: String { commitHash }

    public init(
        commitHash: String,
        date: Date,
        subject: String,
        affected: [URL]
    ) {
        self.commitHash = commitHash
        self.date = date
        self.subject = subject
        self.affected = affected
    }
}

/// Everything the Promoter tab needs to render. Loaded as a unit by
/// ``PromoterService.snapshot(in:deploymentRoot:)`` so the UI can show
/// all three panes from a single async refresh.
public struct PromoterSnapshot: Sendable {
    public var config: PromoterConfig
    public var imports: [AutoPkgImport]
    public var candidates: [PromotionCandidate]
    public var history: [PromotionHistoryEntry]

    public init(
        config: PromoterConfig,
        imports: [AutoPkgImport],
        candidates: [PromotionCandidate],
        history: [PromotionHistoryEntry]
    ) {
        self.config = config
        self.imports = imports
        self.candidates = candidates
        self.history = history
    }

    public static let empty = PromoterSnapshot(
        config: PromoterConfig(rules: []),
        imports: [],
        candidates: [],
        history: []
    )
}
