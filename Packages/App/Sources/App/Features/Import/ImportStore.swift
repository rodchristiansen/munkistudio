import Foundation
import Observation
import Core

/// All wizard + batch-queue state for the Import section. Drives
/// `ImportView` and `ImportWizardView` exclusively; nothing outside this
/// directory should reach in here.
///
/// State machine, top-level:
/// - `mode == .idle` — drop zone + (optional) batch queue.
/// - `mode == .wizard(installerURL)` — 4-step wizard for a single file.
/// - `mode == .running` — munkiimport is executing for either a single
///    wizard save or one row of the batch queue.
///
/// Cancelling out of the wizard / clearing the queue returns to `.idle`.
@Observable
final class ImportStore {
    enum Mode: Equatable {
        case idle
        case wizard(URL)
        case running
    }

    enum WizardStep: Int, CaseIterable, Equatable {
        case review = 1
        case editMetadata = 2
        case scripts = 3
        case locationAndReview = 4

        var label: String {
            switch self {
            case .review: "Step 1 of 4 · Review"
            case .editMetadata: "Step 2 of 4 · Edit metadata"
            case .scripts: "Step 3 of 4 · Scripts"
            case .locationAndReview: "Step 4 of 4 · Location and review"
            }
        }

        var advanceLabel: String {
            self == .locationAndReview ? "Save" : "Continue"
        }
    }

    /// One row in the multi-file batch queue. Mirrors
    /// `ImportViewModel.QueueItem` from CimianStudio.
    @Observable
    final class QueueItem: Identifiable {
        let id = UUID()
        let installerURL: URL
        var status: Status
        var statusText: String

        init(installerURL: URL) {
            self.installerURL = installerURL
            self.status = .pending
            self.statusText = "Queued"
        }

        var fileName: String { installerURL.lastPathComponent }

        enum Status: Equatable {
            case pending
            case inProgress
            case done
            case error
        }
    }

    // MARK: Top-level mode

    var mode: Mode = .idle

    // MARK: Wizard state

    var step: WizardStep = .review
    /// Metadata as extracted from the file (Step 1, read-only display).
    var extracted: InstallerMetadata = .empty
    /// Metadata as edited by the user (Step 2 onward). Initialised from
    /// `extracted` when entering Step 2, then carried forward.
    var edited: InstallerMetadata = .empty
    /// The matched existing pkginfo with the same `name`, if any. Drives
    /// the Step-1 template banner.
    var templateMatch: PkginfoRecord?
    /// Whether the user chose to inherit catalogs / scripts / blocking
    /// apps from the matched template.
    var useTemplate: Bool = false
    /// Repo subdirectory under both `pkgs/` and `pkgsinfo/`. Defaults to
    /// the template's subdirectory if one was matched, otherwise empty.
    var subdirectory: String = ""
    /// Catalogs chosen for the import (chip picker in Step 2).
    var catalogs: [String] = []
    /// Blocking apps (chip picker in Step 2).
    var blockingApplications: [String] = []
    /// Architecture selection ("arm64", "x86_64", or "arm64,x86_64").
    /// Empty means "let munkiimport autodetect."
    var architectureSelection: ArchitectureSelection = .unspecified
    var unattendedInstall: Bool = false
    var unattendedUninstall: Bool = false
    /// Minimum / maximum macOS version and minimum Munki version. Empty
    /// strings mean "don't pass the flag."
    var minimumOSVersion: String = ""
    var maximumOSVersion: String = ""
    var minimumMunkiVersion: String = ""
    /// Ask munkiimport to extract an icon out of the installer.
    var extractIcon: Bool = false
    /// Explicit icon override (.icns / .png). `nil` means none.
    var iconPath: URL?
    /// Six script slots — `nil` means "omit this slot." When the user
    /// types into an editor we hold the body here; on Save we write each
    /// non-empty slot to a temp file and hand the path to munkiimport.
    var scripts: [ScriptSlot: String] = [:]

    enum ArchitectureSelection: String, CaseIterable, Identifiable {
        case unspecified
        case appleSilicon
        case intel
        case both

        var id: String { rawValue }
        var label: String {
            switch self {
            case .unspecified: "Autodetect"
            case .appleSilicon: "Apple silicon (arm64)"
            case .intel: "Intel (x86_64)"
            case .both: "Universal (arm64 + x86_64)"
            }
        }

        var values: [String] {
            switch self {
            case .unspecified: []
            case .appleSilicon: ["arm64"]
            case .intel: ["x86_64"]
            case .both: ["arm64", "x86_64"]
            }
        }

        static func from(_ archs: [String]) -> ArchitectureSelection {
            let set = Set(archs)
            if set.isEmpty { return .unspecified }
            if set == ["arm64"] { return .appleSilicon }
            if set == ["x86_64"] { return .intel }
            if set == ["arm64", "x86_64"] { return .both }
            return .unspecified
        }
    }

    enum ScriptSlot: String, CaseIterable, Identifiable, Hashable {
        case preinstall, postinstall, preuninstall, postuninstall
        case installCheck = "installcheck"
        case uninstallCheck = "uninstallcheck"
        case versionScript = "version"

        var id: String { rawValue }
        var tabLabel: String {
            switch self {
            case .preinstall: "Pre-install"
            case .postinstall: "Post-install"
            case .preuninstall: "Pre-uninstall"
            case .postuninstall: "Post-uninstall"
            case .installCheck: "Install check"
            case .uninstallCheck: "Uninstall check"
            case .versionScript: "Version"
            }
        }
    }

    // MARK: Batch queue

    var queue: [QueueItem] = []
    /// Default catalog applied to every queued file when the user clicks
    /// Process queue. Maps to `--catalog`.
    var batchCatalog: String = ""
    /// Default subdirectory applied to every queued file.
    var batchSubdirectory: String = ""

    // MARK: Live output

    /// Stdout / stderr lines collected during a run. Append-only.
    var output: String = ""
    /// Last outcome the runner returned. `nil` while running.
    var lastOutcome: MunkiimportOutcome?
    /// User-visible status text in the bottom infobar of Step 4.
    var statusBanner: StatusBanner?

    struct StatusBanner: Equatable {
        var severity: Severity
        var title: String
        var message: String

        enum Severity { case info, success, warning, error }
    }

    // MARK: Drop / pick entry point

    /// Single file → enter wizard. Multi-file (or any drop while a queue
    /// already exists) → enqueue. Mirrors `HandleSelectedFilesAsync` in
    /// CimianStudio.
    func handle(droppedURLs urls: [URL]) {
        let supported = urls.filter { Self.isSupported(installer: $0) }
        guard !supported.isEmpty else { return }
        if supported.count == 1 && queue.isEmpty {
            enterWizard(installerURL: supported[0])
            return
        }
        let known = Set(queue.map(\.installerURL.path))
        for url in supported where !known.contains(url.path) {
            queue.append(QueueItem(installerURL: url))
        }
    }

    private static func isSupported(installer url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "pkg", "mpkg", "dmg", "app", "iso", "zip": true
        default: false
        }
    }

    // MARK: Wizard transitions

    func enterWizard(installerURL: URL) {
        let extracted = InstallerMetadataExtractor.extract(from: installerURL)
        self.extracted = extracted
        self.edited = extracted
        self.architectureSelection = ArchitectureSelection.from(extracted.supportedArchitectures)
        self.scripts = [:]
        self.useTemplate = false
        self.templateMatch = nil
        self.subdirectory = ""
        self.catalogs = []
        self.blockingApplications = []
        self.unattendedInstall = false
        self.unattendedUninstall = false
        self.minimumOSVersion = ""
        self.maximumOSVersion = ""
        self.minimumMunkiVersion = ""
        self.extractIcon = false
        self.iconPath = nil
        self.statusBanner = nil
        self.output = ""
        self.lastOutcome = nil
        self.step = .review
        self.mode = .wizard(installerURL)
    }

    func applyTemplate(_ record: PkginfoRecord, in repository: MunkiRepository) {
        templateMatch = record
        useTemplate = true
        // Inherit catalogs / blocking apps / scripts. Architecture stays
        // whatever the filename-detection picked.
        catalogs = record.pkginfo.catalogs ?? []
        blockingApplications = (record.pkginfo.blockingApplications ?? []).map(\.rawValue)
        unattendedInstall = record.pkginfo.unattendedInstall ?? false
        unattendedUninstall = record.pkginfo.unattendedUninstall ?? false
        minimumOSVersion = record.pkginfo.minimumOSVersion ?? ""
        maximumOSVersion = record.pkginfo.maximumOSVersion ?? ""
        minimumMunkiVersion = record.pkginfo.minimumMunkiVersion ?? ""
        if edited.developer.isEmpty, let dev = record.pkginfo.developer { edited.developer = dev }
        if edited.category.isEmpty, let cat = record.pkginfo.category { edited.category = cat }
        if edited.description.isEmpty, let desc = record.pkginfo.description { edited.description = desc }
        if edited.displayName.isEmpty || edited.displayName == edited.name,
           let dn = record.pkginfo.displayName { edited.displayName = dn }
        scripts[.preinstall] = record.pkginfo.preinstallScript
        scripts[.postinstall] = record.pkginfo.postinstallScript
        scripts[.preuninstall] = record.pkginfo.preuninstallScript
        scripts[.postuninstall] = record.pkginfo.postuninstallScript
        scripts[.installCheck] = record.pkginfo.installcheckScript
        scripts[.uninstallCheck] = record.pkginfo.uninstallcheckScript
        // Carry the template's relative location into the subdir field so
        // the new pkginfo lands next to its predecessor by default.
        let pkgsInfo = repository.pkgsinfoURL.path
        let dir = record.fileURL.deletingLastPathComponent().path
        if dir.hasPrefix(pkgsInfo) {
            let relative = String(dir.dropFirst(pkgsInfo.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            subdirectory = relative
        }
    }

    func startFresh() {
        useTemplate = false
        catalogs = []
        blockingApplications = []
        scripts = [:]
        subdirectory = ""
        unattendedInstall = false
        unattendedUninstall = false
        minimumOSVersion = ""
        maximumOSVersion = ""
        minimumMunkiVersion = ""
    }

    func resetToIdle() {
        mode = .idle
        step = .review
        extracted = .empty
        edited = .empty
        templateMatch = nil
        useTemplate = false
        subdirectory = ""
        catalogs = []
        blockingApplications = []
        architectureSelection = .unspecified
        unattendedInstall = false
        unattendedUninstall = false
        minimumOSVersion = ""
        maximumOSVersion = ""
        minimumMunkiVersion = ""
        extractIcon = false
        iconPath = nil
        scripts = [:]
        output = ""
        lastOutcome = nil
        statusBanner = nil
    }

    func clearQueue() {
        queue.removeAll()
        if case .wizard = mode { return }
        mode = .idle
    }

    // MARK: Compose munkiimport options

    /// Build the option set for the active wizard run. Scripts are
    /// written to temp files by the caller — this method just keeps the
    /// non-script fields together.
    func buildOptions(
        installerURL: URL,
        scriptPaths: [ScriptSlot: URL],
        emitYAML: Bool
    ) -> MunkiimportOptions {
        MunkiimportOptions(
            installerPath: installerURL,
            subdirectory: subdirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            catalogs: catalogs,
            name: edited.name.isEmpty ? nil : edited.name,
            displayName: edited.displayName.isEmpty || edited.displayName == edited.name ? nil : edited.displayName,
            version: edited.version.isEmpty ? nil : edited.version,
            developer: edited.developer.isEmpty ? nil : edited.developer,
            category: edited.category.isEmpty ? nil : edited.category,
            description: edited.description.isEmpty ? nil : edited.description,
            supportedArchitectures: architectureSelection.values,
            unattendedInstall: unattendedInstall,
            unattendedUninstall: unattendedUninstall,
            blockingApplications: blockingApplications,
            minimumOSVersion: minimumOSVersion.isEmpty ? nil : minimumOSVersion,
            maximumOSVersion: maximumOSVersion.isEmpty ? nil : maximumOSVersion,
            minimumMunkiVersion: minimumMunkiVersion.isEmpty ? nil : minimumMunkiVersion,
            preinstallScriptPath: scriptPaths[.preinstall],
            postinstallScriptPath: scriptPaths[.postinstall],
            preuninstallScriptPath: scriptPaths[.preuninstall],
            postuninstallScriptPath: scriptPaths[.postuninstall],
            installCheckScriptPath: scriptPaths[.installCheck],
            uninstallCheckScriptPath: scriptPaths[.uninstallCheck],
            versionScriptPath: scriptPaths[.versionScript],
            emitYAML: emitYAML,
            extractIcon: extractIcon,
            iconPath: iconPath
        )
    }

    /// Per-row option set for the batch queue. Uses the queue defaults
    /// instead of the per-file edits the wizard collects.
    func buildBatchOptions(installerURL: URL, emitYAML: Bool) -> MunkiimportOptions {
        MunkiimportOptions(
            installerPath: installerURL,
            subdirectory: batchSubdirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            catalogs: batchCatalog.isEmpty ? [] : [batchCatalog],
            emitYAML: emitYAML
        )
    }

    // MARK: Script file staging

    /// Write each non-empty script slot to a unique temp file so we can
    /// pass `--preinstall-script <path>` flags to munkiimport. Returns
    /// the mapping plus a clean-up closure the caller invokes after the
    /// run finishes.
    func stageScriptFiles() throws -> (paths: [ScriptSlot: URL], cleanup: @Sendable () -> Void) {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MunkiStudioImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        var paths: [ScriptSlot: URL] = [:]
        for slot in ScriptSlot.allCases {
            guard let body = scripts[slot], !body.isEmpty else { continue }
            let url = tempDir.appending(path: "\(slot.rawValue).sh")
            try body.write(to: url, atomically: true, encoding: .utf8)
            paths[slot] = url
        }
        let cleanup: @Sendable () -> Void = {
            try? FileManager.default.removeItem(at: tempDir)
        }
        return (paths, cleanup)
    }
}
