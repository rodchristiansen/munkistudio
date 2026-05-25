import Foundation
import Core

/// File-backed `TestingService` implementation. Phase A: schema
/// validation from the in-memory snapshot + script lint over each script
/// slot in the pkginfo + a JSON checklist persisted under
/// `<repo>/.munkistudio/testing-checklist.json`.
public struct FileTestingService: TestingService {

    public init() {}

    // MARK: - Validation

    public func validate(
        _ record: PkginfoRecord,
        in snapshot: RepositorySnapshot
    ) async -> TestingResult {
        let started = Date()
        var steps: [TestingStepResult] = []

        steps.append(schemaStep(for: record, in: snapshot))
        steps.append(scriptLintStep(for: record))

        let finished = Date()
        return TestingResult(
            packageName: record.pkginfo.name,
            pkginfoURL: record.fileURL,
            steps: steps,
            startedAt: started,
            finishedAt: finished
        )
    }

    private func schemaStep(
        for record: PkginfoRecord,
        in snapshot: RepositorySnapshot
    ) -> TestingStepResult {
        let started = Date()
        let pkginfo = record.pkginfo
        var messages: [String] = []
        var severity: TestingStepResult.Severity = .success

        let loadError = snapshot.loadErrors.first { $0.fileURL == record.fileURL }
        if let loadError {
            messages.append("Parser: \(loadError.message)")
            severity = .error
        }

        if pkginfo.name.trimmingCharacters(in: .whitespaces).isEmpty {
            messages.append("Missing required field: name")
            severity = max(severity, .error)
        }
        if (pkginfo.version ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            messages.append("Missing required field: version")
            severity = max(severity, .error)
        }
        if let catalogs = pkginfo.catalogs, catalogs.isEmpty {
            messages.append("Catalogs array present but empty")
            severity = max(severity, .warning)
        } else if pkginfo.catalogs == nil {
            messages.append("No catalogs declared")
            severity = max(severity, .warning)
        }

        // Catalog membership — anything claimed should exist in the repo's
        // catalog projection. A typo here means the package never appears
        // on a client.
        let knownCatalogs = Set(snapshot.catalogs.map(\.name))
        for claimed in pkginfo.catalogs ?? [] {
            if !knownCatalogs.contains(claimed) {
                messages.append("Catalog '\(claimed)' is not declared by any other pkginfo")
                severity = max(severity, .warning)
            }
        }

        if let archs = pkginfo.supportedArchitectures {
            if Set(archs).count != archs.count {
                messages.append("Duplicate entries in supported_architectures")
                severity = max(severity, .warning)
            }
        }

        if messages.isEmpty {
            messages.append("Required fields present, catalogs known, architectures OK.")
        }

        return TestingStepResult(
            kind: .schema,
            title: "Schema check",
            success: severity != .error,
            severity: severity,
            messages: messages,
            duration: Date().timeIntervalSince(started)
        )
    }

    private func scriptLintStep(for record: PkginfoRecord) -> TestingStepResult {
        let started = Date()
        let pkginfo = record.pkginfo

        let slots: [(String, String?)] = [
            ("preinstall_script",     pkginfo.preinstallScript),
            ("postinstall_script",    pkginfo.postinstallScript),
            ("preuninstall_script",   pkginfo.preuninstallScript),
            ("postuninstall_script",  pkginfo.postuninstallScript),
            ("uninstall_script",      pkginfo.uninstallScript),
            ("version_script",        pkginfo.versionScript),
        ]

        var messages: [String] = []
        var severity: TestingStepResult.Severity = .success

        var present = 0
        for (slot, source) in slots {
            guard let source, !source.isEmpty else { continue }
            present += 1
            let language = ScriptLanguage.detect(in: source)
            let warnings = ScriptLinter.warnings(source, language: language)
            for warning in warnings {
                messages.append("\(slot): \(warning)")
                severity = max(severity, .warning)
            }
        }

        if present == 0 {
            messages.append("No scripts in this pkginfo.")
            severity = .info
        } else if messages.isEmpty {
            messages.append("\(present) script\(present == 1 ? "" : "s") clean.")
        }

        return TestingStepResult(
            kind: .scriptLint,
            title: "Script lint",
            success: severity != .error,
            severity: severity,
            messages: messages,
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Phase B steps

    public func validateBuild(
        project: MunkipkgProject,
        munkipkg: any MunkipkgService
    ) async -> TestingStepResult {
        let started = Date()
        var messages: [String] = []
        var severity: TestingStepResult.Severity = .success
        var success = false
        var capturedProduct: URL?

        do {
            for try await event in munkipkg.build(
                project,
                options: MunkipkgBuildOptions(skipImport: true, quiet: true)
            ) {
                switch event {
                case .line(let line):
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        messages.append(trimmed)
                    }
                case .finished(let exitCode, let productURL):
                    capturedProduct = productURL
                    if exitCode == 0, let productURL {
                        success = true
                        messages.append("Built \(productURL.lastPathComponent).")
                    } else {
                        severity = .error
                        messages.append("munkipkg exited \(exitCode).")
                    }
                }
            }
        } catch {
            severity = .error
            messages.append("munkipkg failed: \(error.localizedDescription)")
        }

        // Trim noise: keep the last ~20 lines so the inspector stays
        // readable; full output lives in the Build tab.
        if messages.count > 20 {
            let dropped = messages.count - 20
            messages = ["… \(dropped) earlier lines omitted"] + messages.suffix(20)
        }

        if success, capturedProduct == nil {
            severity = max(severity, .warning)
            messages.append("Build reported success but produced no .pkg URL.")
        }

        return TestingStepResult(
            kind: .build,
            title: "Build (munkipkg)",
            success: success && severity != .error,
            severity: severity,
            messages: messages,
            duration: Date().timeIntervalSince(started)
        )
    }

    public func validateBuildArtifact(
        _ record: PkginfoRecord,
        in repository: MunkiRepository
    ) async -> TestingStepResult {
        let started = Date()
        var messages: [String] = []
        var severity: TestingStepResult.Severity = .success

        guard let relative = record.pkginfo.installerItemLocation,
              !relative.isEmpty
        else {
            return TestingStepResult(
                kind: .buildArtifact,
                title: "Build artifact",
                success: true,
                severity: .info,
                messages: ["pkginfo has no installer_item_location — nothing to check."],
                duration: Date().timeIntervalSince(started)
            )
        }

        let artifactURL = repository.pkgsURL.appending(path: relative)
        let path = artifactURL.path
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else {
            return TestingStepResult(
                kind: .buildArtifact,
                title: "Build artifact",
                success: false,
                severity: .error,
                messages: ["Missing artifact at pkgs/\(relative)."],
                duration: Date().timeIntervalSince(started)
            )
        }

        if let attrs = try? manager.attributesOfItem(atPath: path),
           let size = attrs[.size] as? NSNumber {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            messages.append("Size: \(formatter.string(fromByteCount: size.int64Value)).")
            if size.int64Value == 0 {
                messages.append("Artifact is 0 bytes.")
                severity = .error
            }
        }

        // Signature check — only meaningful for `.pkg`. Skip DMGs.
        if artifactURL.pathExtension.lowercased() == "pkg" {
            let signatureResult = await Self.runPkgutilCheck(path: path)
            messages.append(contentsOf: signatureResult.messages)
            severity = max(severity, signatureResult.severity)
        } else {
            messages.append("Skipping signature check for .\(artifactURL.pathExtension).")
        }

        return TestingStepResult(
            kind: .buildArtifact,
            title: "Build artifact",
            success: severity != .error,
            severity: severity,
            messages: messages,
            duration: Date().timeIntervalSince(started)
        )
    }

    private static func runPkgutilCheck(path: String) async -> (messages: [String], severity: TestingStepResult.Severity) {
        await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
            task.arguments = ["--check-signature", path]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
                task.waitUntilExit()
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                let output = String(decoding: data, as: UTF8.self)
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
                if task.terminationStatus == 0 {
                    continuation.resume(returning: (["Signature: \(summary)"], .success))
                } else {
                    continuation.resume(returning: (["pkgutil exited \(task.terminationStatus): \(summary)"], .warning))
                }
            } catch {
                continuation.resume(returning: (["pkgutil unavailable: \(error.localizedDescription)"], .warning))
            }
        }
    }

    // MARK: - Phase C steps (env-driven)

    public func validateInstall(
        _ record: PkginfoRecord,
        in repository: MunkiRepository,
        environment: any TestEnvironment
    ) async -> TestingStepResult {
        let started = Date()
        var messages: [String] = []
        var severity: TestingStepResult.Severity = .success

        guard let relative = record.pkginfo.installerItemLocation, !relative.isEmpty else {
            return TestingStepResult(
                kind: .install,
                title: "Install",
                success: true,
                severity: .info,
                messages: ["pkginfo has no installer_item_location — nothing to install."],
                duration: Date().timeIntervalSince(started)
            )
        }

        let localURL = repository.pkgsURL.appending(path: relative)
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            return TestingStepResult(
                kind: .install,
                title: "Install",
                success: false,
                severity: .error,
                messages: ["Missing local artifact at pkgs/\(relative)."],
                duration: Date().timeIntervalSince(started)
            )
        }

        // Copy into the guest's /tmp under its original filename.
        let guestPath = "/tmp/\(localURL.lastPathComponent)"
        do {
            try await environment.copyFile(from: localURL, toGuestPath: guestPath)
            messages.append("Copied artifact to \(guestPath).")
        } catch {
            return TestingStepResult(
                kind: .install,
                title: "Install",
                success: false,
                severity: .error,
                messages: ["Couldn't copy artifact into \(environment.displayName): \(error.localizedDescription)"],
                duration: Date().timeIntervalSince(started)
            )
        }

        // Run installer(8). Falls back to a friendly message for .dmg
        // payloads, which need a different flow (mount + drag-copy or
        // installer against an inner .pkg) that v1 doesn't tackle.
        if localURL.pathExtension.lowercased() != "pkg" {
            return TestingStepResult(
                kind: .install,
                title: "Install",
                success: true,
                severity: .warning,
                messages: messages + ["Skipping `.\(localURL.pathExtension)` — only .pkg installs are wired in v1."],
                duration: Date().timeIntervalSince(started)
            )
        }

        do {
            let result = try await environment.runCommand(
                "/usr/bin/sudo",
                arguments: ["/usr/sbin/installer", "-pkg", guestPath, "-target", "/"]
            )
            messages.append("installer exited \(result.exitCode).")
            let tail = Self.tail(of: result.stdout, lines: 6)
            if !tail.isEmpty { messages.append(tail) }
            if !result.success {
                severity = .error
                let errTail = Self.tail(of: result.stderr, lines: 4)
                if !errTail.isEmpty { messages.append(errTail) }
            }
        } catch {
            severity = .error
            messages.append("Install command failed: \(error.localizedDescription)")
        }

        return TestingStepResult(
            kind: .install,
            title: "Install",
            success: severity != .error,
            severity: severity,
            messages: messages,
            duration: Date().timeIntervalSince(started)
        )
    }

    public func validateInstallsArray(
        _ record: PkginfoRecord,
        environment: any TestEnvironment
    ) async -> TestingStepResult {
        let started = Date()
        let installs = record.pkginfo.installs ?? []
        guard !installs.isEmpty else {
            return TestingStepResult(
                kind: .installsCheck,
                title: "installs[] check",
                success: true,
                severity: .info,
                messages: ["pkginfo has no installs[] entries to verify."],
                duration: Date().timeIntervalSince(started)
            )
        }

        var messages: [String] = []
        var severity: TestingStepResult.Severity = .success
        var passed = 0
        var failed = 0
        var mismatched = 0

        for item in installs {
            let outcome = await Self.verifyInstallsEntry(item, in: environment)
            messages.append(outcome.line)
            switch outcome.result {
            case .pass:
                passed += 1
            case .versionMismatch:
                mismatched += 1
                severity = max(severity, .warning)
            case .missing, .error:
                failed += 1
                severity = max(severity, .error)
            }
        }

        var summary = "\(passed) passed, \(failed) missing"
        if mismatched > 0 { summary += ", \(mismatched) version mismatch" }
        messages.insert(summary, at: 0)
        return TestingStepResult(
            kind: .installsCheck,
            title: "installs[] check",
            success: failed == 0,
            severity: severity,
            messages: messages,
            duration: Date().timeIntervalSince(started)
        )
    }

    private enum InstallsCheckResult {
        case pass
        case versionMismatch
        case missing
        case error
    }

    private struct InstallsCheckOutcome {
        var line: String
        var result: InstallsCheckResult
    }

    /// Verify one ``InstallsItem`` against the guest. Defaults to a path
    /// existence check; for `application` / `bundle` types we also
    /// compare CFBundleIdentifier / CFBundleShortVersionString when the
    /// pkginfo provides them — that's the bar Munki actually uses to
    /// decide whether the app is installed.
    private static func verifyInstallsEntry(
        _ item: InstallsItem,
        in environment: any TestEnvironment
    ) async -> InstallsCheckOutcome {
        let path = item.path
        let exists: Bool
        do {
            let probe = try await environment.runCommand("/bin/test", arguments: ["-e", path])
            exists = probe.success
        } catch {
            return InstallsCheckOutcome(
                line: "fail \(path) - \(error.localizedDescription)",
                result: .error
            )
        }
        guard exists else {
            return InstallsCheckOutcome(line: "miss \(path) - missing", result: .missing)
        }

        let type = (item.type ?? "").lowercased()
        let wantsBundleProbe = type == "application" || type == "bundle"
        guard wantsBundleProbe else {
            return InstallsCheckOutcome(line: "pass \(path)", result: .pass)
        }

        // For app/bundle paths, read Info.plist via `defaults read` so we
        // don't depend on Spotlight indexing inside an ephemeral guest.
        let plistPath = "\(path)/Contents/Info"
        var detail: [String] = []
        var status: InstallsCheckResult = .pass

        if let expectedID = item.cfBundleIdentifier, !expectedID.isEmpty {
            let actual = await Self.readDefault(plistPath, key: "CFBundleIdentifier", in: environment)
            if actual == expectedID {
                detail.append("id=\(actual)")
            } else {
                detail.append("id expected=\(expectedID) got=\(actual ?? "<missing>")")
                status = .versionMismatch
            }
        }

        if let expectedVersion = item.cfBundleShortVersionString ?? item.cfBundleVersion,
           !expectedVersion.isEmpty {
            let key = item.cfBundleShortVersionString != nil
                ? "CFBundleShortVersionString" : "CFBundleVersion"
            let actual = await Self.readDefault(plistPath, key: key, in: environment)
            if actual == expectedVersion {
                detail.append("\(key)=\(actual)")
            } else {
                detail.append("\(key) expected=\(expectedVersion) got=\(actual ?? "<missing>")")
                status = .versionMismatch
            }
        }

        let detailString = detail.isEmpty ? "" : " — " + detail.joined(separator: ", ")
        let glyph = status == .pass ? "pass" : "warn"
        return InstallsCheckOutcome(
            line: "\(glyph) \(path)\(detailString)",
            result: status
        )
    }

    /// Read one key from a guest plist via `defaults read`. Returns the
    /// trimmed value on success, `nil` on failure.
    private static func readDefault(
        _ plistPath: String,
        key: String,
        in environment: any TestEnvironment
    ) async -> String? {
        let result = try? await environment.runCommand(
            "/usr/bin/defaults",
            arguments: ["read", plistPath, key]
        )
        guard let result, result.success else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public func validateUninstall(
        _ record: PkginfoRecord,
        environment: any TestEnvironment
    ) async -> TestingStepResult {
        let started = Date()
        let pkginfo = record.pkginfo
        let method = (pkginfo.uninstallMethod ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let script = pkginfo.uninstallScript ?? ""

        // Decide which path to run. Explicit uninstall_method wins; else
        // a present uninstall_script implies uninstall_script.
        let effectiveMethod: UninstallPath
        if method == "uninstall_script" || (method.isEmpty && !script.isEmpty) {
            effectiveMethod = .script
        } else if method == "removepackages" {
            effectiveMethod = .removePackages
        } else if method.isEmpty && script.isEmpty {
            return TestingStepResult(
                kind: .uninstall,
                title: "Uninstall",
                success: true,
                severity: .info,
                messages: ["No uninstall method or uninstall_script configured."],
                duration: Date().timeIntervalSince(started)
            )
        } else {
            return TestingStepResult(
                kind: .uninstall,
                title: "Uninstall",
                success: true,
                severity: .warning,
                messages: ["uninstall_method='\(method)' isn't implemented yet — supported: uninstall_script, removepackages."],
                duration: Date().timeIntervalSince(started)
            )
        }

        switch effectiveMethod {
        case .script:
            return await runScriptUninstall(
                body: script,
                environment: environment,
                startedAt: started
            )
        case .removePackages:
            return await runRemovePackagesUninstall(
                receipts: pkginfo.receipts ?? [],
                environment: environment,
                startedAt: started
            )
        }
    }

    private enum UninstallPath {
        case script
        case removePackages
    }

    private func runScriptUninstall(
        body: String,
        environment: any TestEnvironment,
        startedAt: Date
    ) async -> TestingStepResult {
        let guestScript = "/tmp/munkistudio-uninstall-\(UUID().uuidString.prefix(8)).sh"
        var messages: [String] = []
        var severity: TestingStepResult.Severity = .success

        do {
            try await Self.writeRemoteScript(body, toGuestPath: guestScript, via: environment)
            let result = try await environment.runCommand(
                "/usr/bin/sudo",
                arguments: ["/bin/sh", guestScript]
            )
            messages.append("uninstall_script exited \(result.exitCode).")
            let tail = Self.tail(of: result.stdout, lines: 6)
            if !tail.isEmpty { messages.append(tail) }
            if !result.success {
                severity = .error
                let errTail = Self.tail(of: result.stderr, lines: 4)
                if !errTail.isEmpty { messages.append(errTail) }
            }
        } catch {
            severity = .error
            messages.append("Uninstall failed: \(error.localizedDescription)")
        }

        return TestingStepResult(
            kind: .uninstall,
            title: "Uninstall (uninstall_script)",
            success: severity != .error,
            severity: severity,
            messages: messages,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    /// `uninstall_method: removepackages` — `pkgutil --forget` every
    /// package ID from the pkginfo's `receipts[]`. We don't try to
    /// remove the installed files themselves; that's what `removepackages`
    /// actually does in Munki, but v1 stops at forgetting receipts so
    /// the test stays bounded and reversible.
    private func runRemovePackagesUninstall(
        receipts: [Receipt],
        environment: any TestEnvironment,
        startedAt: Date
    ) async -> TestingStepResult {
        let ids = receipts.compactMap(\.packageid).filter { !$0.isEmpty }
        guard !ids.isEmpty else {
            return TestingStepResult(
                kind: .uninstall,
                title: "Uninstall (removepackages)",
                success: false,
                severity: .error,
                messages: ["uninstall_method='removepackages' but no receipts[] are declared."],
                duration: Date().timeIntervalSince(startedAt)
            )
        }

        var messages: [String] = []
        var severity: TestingStepResult.Severity = .success

        for id in ids {
            do {
                let result = try await environment.runCommand(
                    "/usr/bin/sudo",
                    arguments: ["/usr/sbin/pkgutil", "--forget", id]
                )
                if result.success {
                    messages.append("pass pkgutil --forget \(id)")
                } else {
                    messages.append("fail pkgutil --forget \(id) - exit \(result.exitCode)")
                    severity = max(severity, .error)
                }
            } catch {
                messages.append("fail pkgutil --forget \(id) - \(error.localizedDescription)")
                severity = max(severity, .error)
            }
        }

        messages.insert("\(ids.count) receipt\(ids.count == 1 ? "" : "s") to forget.", at: 0)
        return TestingStepResult(
            kind: .uninstall,
            title: "Uninstall (removepackages)",
            success: severity != .error,
            severity: severity,
            messages: messages,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    // MARK: - Helpers

    /// Drop a script body into the guest via a temp file on the host
    /// (most env backends only know how to copy files, not stream
    /// stdin), then `scp` / copy it across.
    private static func writeRemoteScript(
        _ body: String,
        toGuestPath: String,
        via environment: any TestEnvironment
    ) async throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "munkistudio-script-\(UUID().uuidString).sh")
        try body.data(using: .utf8)?.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await environment.copyFile(from: tempURL, toGuestPath: toGuestPath)
        _ = try? await environment.runCommand("/bin/chmod", arguments: ["+x", toGuestPath])
    }

    /// Trim a multi-line string to the last N lines, prefixed with an
    /// "…" indicator when content was elided.
    private static func tail(of text: String, lines: Int) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard all.count > lines else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let kept = all.suffix(lines).joined(separator: "\n")
        return "… \(all.count - lines) earlier lines omitted\n" + kept
    }

    // MARK: - Autofix

    public func proposeAutofixes(
        for record: PkginfoRecord,
        in snapshot: RepositorySnapshot
    ) async -> AutofixProposal? {
        var pkginfo = record.pkginfo
        var changes: [AutofixChange] = []

        // 1) Dedupe supported_architectures, preserving first-seen order.
        if let archs = pkginfo.supportedArchitectures, Set(archs).count != archs.count {
            var seen: Set<SupportedArchitecture> = []
            var deduped: [SupportedArchitecture] = []
            for arch in archs where !seen.contains(arch) {
                seen.insert(arch)
                deduped.append(arch)
            }
            changes.append(
                AutofixChange(
                    field: "supported_architectures",
                    before: archs.map(\.rawValue).joined(separator: ", "),
                    after: deduped.map(\.rawValue).joined(separator: ", "),
                    rationale: "Removed duplicate entries from supported_architectures."
                )
            )
            pkginfo.supportedArchitectures = deduped
        }

        // 2) Empty catalogs array → nil. Munki defaults to "all catalogs"
        //    when the key is absent; an empty array is a no-op that
        //    confuses readers.
        if let catalogs = pkginfo.catalogs, catalogs.isEmpty {
            changes.append(
                AutofixChange(
                    field: "catalogs",
                    before: "[]",
                    after: "(removed)",
                    rationale: "Removed empty catalogs list — an empty array hides the package from every catalog."
                )
            )
            pkginfo.catalogs = nil
        }

        // 3) Sort catalogs alphabetically (case-insensitive) for stable diffs.
        if let catalogs = pkginfo.catalogs, catalogs.count > 1 {
            let sorted = catalogs.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            if sorted != catalogs {
                changes.append(
                    AutofixChange(
                        field: "catalogs",
                        before: catalogs.joined(separator: ", "),
                        after: sorted.joined(separator: ", "),
                        rationale: "Sorted catalogs alphabetically for stable PR diffs."
                    )
                )
                pkginfo.catalogs = sorted
            }
        }

        guard !changes.isEmpty else { return nil }
        return AutofixProposal(pkginfo: pkginfo, changes: changes)
    }

    // MARK: - Results export

    public func exportResults(
        _ results: [TestingResult],
        in repository: MunkiRepository
    ) async throws -> URL {
        let directory = repository.rootURL
            .appending(path: ".munkistudio")
            .appending(path: "testing-results")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let url = directory.appending(path: "run-\(stamp).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let envelope = TestingRunEnvelope(
            generatedAt: Date(),
            total: results.count,
            passed: results.filter(\.success).count,
            failed: results.filter { !$0.success }.count,
            results: results
        )
        let data = try encoder.encode(envelope)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Checklist

    public func loadChecklist(in repository: MunkiRepository) async throws -> ChecklistStore {
        let url = Self.checklistURL(in: repository)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChecklistStore.self, from: data)
    }

    public func saveChecklist(
        _ store: ChecklistStore,
        in repository: MunkiRepository
    ) async throws {
        let jsonURL = Self.checklistURL(in: repository)
        try FileManager.default.createDirectory(
            at: jsonURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(store)
        try json.write(to: jsonURL, options: .atomic)

        // Markdown view — JSON stays canonical, but the .md round-trips
        // cleanly through `git diff` so reviewers can read the run
        // history without a JSON viewer. Modelled on Cimian's
        // quality/checklist.md.
        let markdown = Self.markdown(for: store)
        let mdURL = Self.checklistMarkdownURL(in: repository)
        try markdown.data(using: .utf8)?.write(to: mdURL, options: .atomic)
    }

    private static func checklistURL(in repository: MunkiRepository) -> URL {
        repository.rootURL
            .appending(path: ".munkistudio")
            .appending(path: "testing-checklist.json")
    }

    private static func checklistMarkdownURL(in repository: MunkiRepository) -> URL {
        repository.rootURL
            .appending(path: ".munkistudio")
            .appending(path: "testing-checklist.md")
    }

    private static func markdown(for store: ChecklistStore) -> String {
        let isoFormatter = ISO8601DateFormatter()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        let totals = ChecklistTotals(store: store)
        var lines: [String] = []
        lines.append("# Testing Checklist")
        lines.append("")
        lines.append("Canonical store: `.munkistudio/testing-checklist.json` (this file is auto-generated).")
        lines.append("")
        lines.append("**\(totals.pass) pass** · **\(totals.warning) warning** · **\(totals.fail) fail** · **\(totals.untested) untested** · total \(totals.total)")
        lines.append("")
        lines.append("| Package | Version | Status | Tester | Tested | Notes |")
        lines.append("|---|---|---|---|---|---|")
        for entry in store.items {
            let symbol: String
            switch entry.status {
            case .untested: symbol = "untested"
            case .pass:     symbol = "pass"
            case .warning:  symbol = "warning"
            case .fail:     symbol = "fail"
            }
            let version = entry.version ?? "—"
            let tester = (entry.tester?.isEmpty == false ? entry.tester! : "—")
            let testedAt: String
            if let date = entry.testedAt {
                testedAt = dateFormatter.string(from: date)
            } else {
                testedAt = "—"
            }
            let notes = (entry.notes ?? "")
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
            lines.append("| \(entry.packageName) | \(version) | \(symbol) | \(tester) | \(testedAt) | \(notes) |")
        }
        lines.append("")
        lines.append("_Last generated \(isoFormatter.string(from: Date()))_")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

/// JSON envelope written by ``FileTestingService/exportResults`` — a
/// stable shape CI / ReportMate / a future CLI can read without
/// reaching into per-result fields directly.
private struct TestingRunEnvelope: Codable {
    var generatedAt: Date
    var total: Int
    var passed: Int
    var failed: Int
    var results: [TestingResult]
}

private struct ChecklistTotals {
    var total: Int = 0
    var pass: Int = 0
    var warning: Int = 0
    var fail: Int = 0
    var untested: Int = 0

    init(store: ChecklistStore) {
        total = store.items.count
        for item in store.items {
            switch item.status {
            case .pass: pass += 1
            case .warning: warning += 1
            case .fail: fail += 1
            case .untested: untested += 1
            }
        }
    }
}

private func max(
    _ lhs: TestingStepResult.Severity,
    _ rhs: TestingStepResult.Severity
) -> TestingStepResult.Severity {
    lhs > rhs ? lhs : rhs
}
