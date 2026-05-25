# Testing tab — design notes

Living document for the Testing pane. Captures what we ported from Cimian's `quality/` system, what changes for Munki/macOS, and the runtime architecture for isolated install testing.

## Status at a glance

| Phase | Scope | Status |
|---|---|---|
| A | Schema check, script lint, repo-local checklist (JSON + Markdown view), autofix v1 | **Shipped** |
| B | Build via `munkipkg`, artifact validation (`pkgutil --check-signature` etc.) | **Shipped** |
| C | `TestEnvironment` protocol, Tart + Host runners, install / installs[] / uninstall steps | **Shipped (spike)** — requires Tart + a configured base image at runtime |
| D | Bulk "Validate all", JSON results export under `.munkistudio/testing-results/` | **Shipped** |

Lives end-to-end behind **Settings → Features → Testing**: enable the tab, pick an install environment, set a tester name. Checklist and results files land under `.munkistudio/` for the team to commit.

---

## 1 · What we are porting from Cimian

Source of truth: `AzDevOps/Devices/Cimian/quality/` and its in-progress C# port in `fleetmate-windows` (`FleetMate.Core/Services/Devices/QaService.cs`, `Models/Devices/QaModels.cs`, `FleetMate.CLI/Commands/Devices/QaCommand.cs`).

### Cimian's PowerShell shape (year-old, needs upgrades)

```
quality/
├── control.ps1          # entry point — -Package / -Category / -Fix / -Next / -Mark
├── checklist.md         # tracked pass / fail / warn list with timestamp + tester
├── guide.md             # human guide to the 7-step validation
├── ideas.md             # autofix ideas backlog
├── autofix/             # YAML flag placement, PowerShell formatting fixes
├── common/              # shared helpers (Quality-Helpers, Test-Helpers, …)
├── lint/                # YAML structure + PkgsInfo + enhanced linting tests
├── systems/             # build consistency, deployment installers, install tests
├── test/                # installer-script tests, real script execution
└── unit/                # package build, prerequisites
```

The 7-step validation per package (from `guide.md`):

1. Build-config check (build-info.yaml present, parses, required fields)
2. PowerShell script + YAML lint (PSScriptAnalyzer, smart-flag rules, field order)
3. Package build (`cimipkg.exe`)
4. Build artifact validation (`.nupkg` present, size sane)
5. Deployment consistency (source vs `deployment/pkgsinfo`, version drift)
6. Installation test (real install via `installer.exe`, pre/post scripts, `installs[]` check, cleanup)
7. Uninstall test (MSI / EXE / script paths)

### What is already in C# in fleetmate-windows

`QaService.cs` (2k LOC) ports most of `control.ps1`:

- `PackageLocation` discovery across `./packages`, `./installers`, `./deployment/pkgsinfo`, including versioned packages (Maya/2024 style).
- `PkgInfoManifest` + `InstallerInfo` + `InstallsItem` + `UninstallerItem` parsed from YAML with `YamlDotNet`.
- `QaStepResult` / `QaResult` shape with `Total/Passed/Failed`, `Duration`, severities.
- `QaOptions` mirrors the PS switches (`DryRun`, `Fix`, `InstallOnly`, `UninstallFirst`, `Category`).
- `RunInstallOnlyWorkflowAsync`, `RunUninstallStepAsync`, `RunInstallationStepAsync` — the step orchestration.
- `BulkOperationResult` for the repkg-all / cimiimport-all bulk modes.
- `InstallerTypeCheckResult` for the `-CheckInstallerType` lint.

`QaCommand.cs` is the CLI surface; `QaModels.cs` is the data shape we will recreate in Swift.

### What does NOT carry over verbatim

- **`cimipkg.exe` and `installer.exe`** are Cimian-specific. Munki's equivalents are `munki-pkg` / `makepkg` (already handled by MunkiStudio's Build tab) and macOS `installer(8)` / `managedsoftwareupdate`.
- **`.nupkg`** packaging. Munki ships `.pkg` and `.dmg`. The build-artifact check becomes "does the `.pkg` exist and is it signed."
- **PowerShell linting**. Munki scripts are shell / Python / Bash. We already have `ScriptLinter` in MunkiStudio — reuse it.
- **Smart flag management** for MSI/EXE. Not applicable to macOS installers.
- **Chocolatey hooks** (`chocolateyBeforeInstall.ps1`). Munki has its own pre/postinstall slots already lintable.

---

## 2 · Mapping into MunkiStudio

The app is three Swift packages (`Core` / `Infra` / `App`). New work follows the same shape — protocol in `Core/Services`, concrete in `Infra`, section view in `App/Features`, registered on `AppServices`, reached through `RepositoryStore`. The ROADMAP already approved this.

### New `Core/Services/QAService.swift`

Mirrors the FleetMate C# shape, ported to Swift:

```
protocol QAService {
    func locate(_ packageName: String) -> PackageLocation?
    func validate(_ pkginfo: URL) async -> ValidationResult           // schema + lint
    func build(_ project: BuildProject) async throws -> BuildArtifact // via existing MunkipkgService
    func install(_ pkg: BuildArtifact, in: TestEnvironment) async throws -> InstallResult
    func verify(_ result: InstallResult, against: [InstallsEntry]) -> VerifyResult
    func uninstall(_ pkg: BuildArtifact, in: TestEnvironment) async throws -> UninstallResult
    func autofix(_ pkginfo: URL, dryRun: Bool) async throws -> [AutofixChange]
    func checklist() -> ChecklistStore
}

struct QAResult {
    let packageName: String
    let location: PackageLocation
    let steps: [QAStepResult]    // each step: name, success, severity, duration, output
    let startedAt: Date
    let finishedAt: Date
    var passRate: Double { … }
}
```

The step list per package (Munki-flavored):

| # | Step | Source |
|---|------|--------|
| 1 | Pkginfo schema check | existing `MunkiYamlRules` / `MunkiPlistRules` + snapshot `loadErrors` |
| 2 | Script lint | existing `ScriptLinter` |
| 3 | Build (`munki-pkg`) | existing `MunkipkgService` |
| 4 | Build artifact check (`.pkg`, signed, size) | new |
| 5 | Catalog/manifest cross-check | new (does it land in the catalogs it claims?) |
| 6 | Install test in isolated env | new — VM runner, see §3 |
| 7 | `installs[]` verification | new — read filesystem state inside guest |
| 8 | Uninstall test | new |

### New full-width pane `App/Features/Testing/`

Following the Build/Clean/Promoter precedent (`prefersFullWidth: true` in `SidebarSection`):

```
Sources/App/Features/Testing/
├── TestingView.swift             # full-width pane
├── TestingViewModel.swift        # @MainActor, observes QAService
├── Components/
│   ├── ChecklistColumn.swift     # left: tracked checklist (pass / warn / fail / untested)
│   ├── StepTimeline.swift        # middle: per-package step-by-step result
│   └── DetailInspector.swift     # right: output / errors / diff (for autofix)
└── Environment/
    ├── EnvironmentPicker.swift   # "host", "ephemeral VM", "named VM"
    └── EnvironmentManager.swift  # lifecycle of named VMs
```

`SidebarSection` adds `case testing = "Testing"`, full-width, icon `checkmark.seal`.

### Settings

A new "Testing" pane in `Settings`:

- VM backend (Tart; auto-detected, install hint if missing)
- VM image (path or registry ref)
- Snapshot policy (`fresh-per-run` / `keep-last`)
- Parallelism (1–N)
- Tester name (for checklist attribution, mirrors Cimian's `by Nelson` / `by Rod`)

---

## 3 · Isolated install testing — the VM runner

The hard, valuable part. We want to install a real Munki package against a clean, throwaway macOS environment, run the `installs[]` assertions, capture logs, tear down — and do that in parallel across a batch.

### Why `apple/container` is not enough on its own

Confirmed against current docs: `apple/container` (the Apple Containerization framework, shipping with macOS 26) spins up lightweight **Linux** VMs to run OCI containers. There is no macOS-guest mode. It is great for:

- Linux-side adjuncts — running `autopkg` recipes, `makecatalogs` in a sandbox, Python static-analysis stacks, pre-commit linters.
- Reproducible CI-style steps where the workload happens to be Linux.

It is **not** the install-test runtime for `.pkg` / `.dmg` payloads. Those need a macOS guest.

### macOS-guest backend: Tart

**Decision: Tart** (`cirruslabs/tart`). Wraps Virtualization.framework, CLI-first, OCI-registry image distribution (`tart pull ghcr.io/cirruslabs/macos-sequoia-base:latest`), APFS-clone snapshots in seconds. Battle-tested in Cirrus CI. OSS, still active under OpenAI ownership.

Alternatives considered and rejected:

- **Virtualization.framework direct** — same hypervisor, but we'd own IPSW restore, disk lifecycle, and snapshot plumbing ourselves. Not worth the maintenance unless Tart goes away.
- **UTM** — QEMU under the hood. Strong GUI, broad arch support (Windows, x86), but weak CLI/scripting story. Wrong shape for batched ephemeral tests.
- **lume / curie** — smaller communities, same VZ wrapping. Watch but don't bet.

Apple's licensing still caps macOS guests at **2 concurrent VMs per Apple Silicon host**. Parallelism above 2 needs a small fleet of Macs (Orchard-style) — out of scope for v1.

### Runner architecture (Phase C spike)

```
QAService
   └── TestEnvironment (protocol)
         ├── HostEnvironment        // run on the admin's Mac (NOT recommended; smoke only)
         ├── TartEnvironment        // spin/clone/snapshot/destroy via tart CLI
         └── ContainerEnvironment   // apple/container — Linux-only adjunct checks
```

`TartEnvironment` workflow per package:

1. `tart clone base-vm test-<uuid>` (APFS clone — seconds)
2. `tart run test-<uuid> --no-graphics --dir=repo:./repo` (mount the Munki repo read-only)
3. SSH in (`tart ip`), copy the `.pkg`, run `sudo installer -pkg … -target /`
4. Walk `installs[]` — for each entry, `stat`/`mdls`/`pkgutil --pkg-info` to verify path + version
5. Capture `/var/log/install.log`, `/Library/Managed Installs/Logs/ManagedSoftwareUpdate.log`
6. Optional uninstall pass (`pkgutil --forget` + manual cleanup, or `managedsoftwareupdate --remove`)
7. `tart delete test-<uuid>`

Streamed output uses the same `AsyncThrowingStream` pattern as `MakecatalogsRunner` / `MunkiimportRunner`.

### The `apple/container` adjunct

Keep it on the table for **Phase A** static checks that benefit from a Linux sandbox:

- Schema validation in a hermetic Python environment.
- `autopkg` recipe runs (autopkg itself is macOS-only, but recipe-syntax linting is portable).
- Future: ReportMate test-fixture generation.

Implementation note: `apple/container` is Swift-native (Apple's repo), so we can call it from MunkiStudio without an extra runtime.

---

## 4 · Autofix layer

Cimian's `autofix/` is two PS scripts today: `Fix-PowerShellFormatting.ps1` and `Fix-YamlFlagPlacement.ps1`. The `ideas.md` backlog is rich (version normalization, missing required fields, field ordering, manifest sync, README generation).

For Munki, the high-value autofixes are:

1. **Pkginfo key ordering** — MunkiAdmin's canonical order. (Have the rule already; need an "apply" pass.)
2. **Missing-required-field stubs** — `developer`, `category`, `description`, `unattended_install`.
3. **Catalog membership normalization** — dedupe, alphabetize, validate against repo catalogs.
4. **Architecture list normalization** — `["x86_64", "arm64"]` ordering and case.
5. **Script slot fixes** — shebang, `set -euo pipefail`, executable bit (we already lint this).
6. **`installs[]` regeneration** — re-run `makepkginfo --file` against the built `.pkg` and merge.

Each autofix is a `AutofixRule` returning a `[AutofixChange]` (path, before, after, severity), surfaced as a diff in `DetailInspector` before the user accepts.

---

## 5 · Checklist / team tracking

Cimian's `checklist.md` is a plain Markdown table with `[x] ✅ Package vX.Y.Z - last tested 2025-09-08 by Nelson`. Simple and effective.

Munki port: `<repo>/.munkistudio/testing-checklist.json` (so it diff-reviews cleanly and round-trips):

```json
{
  "items": [
    {
      "package": "Firefox",
      "version": "138.0.1",
      "status": "pass",
      "testedAt": "2026-05-24T12:30:00Z",
      "tester": "Rod",
      "notes": "Installed cleanly in ephemeral Tart VM; installs[] all verified."
    }
  ]
}
```

Cimian's `-Next` workflow — "hand me the next untested package" — maps to a toolbar button in the Testing pane: **Next untested →** picks the next item, queues it, opens its step timeline.

---

## 6 · Phasing

Aligns with the ROADMAP entry:

- **Phase A — Static + checklist (M).** Schema + script lint (reuse), autofix v1 (top-3 rules), checklist store with Markdown round-trip. No VMs yet. **Ships value immediately.**
- **Phase B — Build integration (M).** Wire the Build tab's `MunkipkgService` into Steps 3–4. Catalog/manifest cross-check. Still host-only.
- **Phase C — Ephemeral install testing (L, spike first).** `TartEnvironment` for a single package, then parallel up to the 2-VM cap. Optional `apple/container` adjunct for Linux-side checks.
- **Phase D — Bulk runs + scheduling (M).** Test-all-in-catalog, nightly runs, JSON export, ReportMate hook.

---

## 7 · Open questions

1. **Tart dependency policy.** Bundle? Detect? Document install path in onboarding? Lean: detect via `which tart`, surface install hint in Settings if missing — same pattern we use for `munki-pkg` and `iconimporter`.
2. **macOS guest base image.** Build our own with Munki preinstalled, or pull a fresh `macos-sequoia-base` and install Munki on first boot? Preinstalled is faster per test but stale faster — likely "preinstalled + auto-update Munki on snapshot refresh."
3. **Where do test artifacts live?** Per-run log dir vs single rolling DB. Match Clean tab's history pattern.
4. **`managedsoftwareupdate` vs raw `installer`.** The former exercises the full Munki path (catalogs, manifests, `installs[]`); the latter is a smoke test. Default to `managedsoftwareupdate` so we test what we ship.
5. **Signing / notarization checks.** Probably a separate static step rather than an install step.
6. **The 2-VM Apple licensing cap.** v1 sequential, document the cap, queue UI handles it gracefully.

---

## 8 · References

- Cimian quality system: `AzDevOps/Devices/Cimian/quality/`
- C# port (in-progress): `AzDevOps/Devices/Cimian/quality/fleetmate/FleetMate.Core/Services/Devices/QaService.cs`
- FleetMate GitHub mirror: <https://github.com/fleetmate-hq/fleetmate-windows>
- Apple Containerization: <https://github.com/apple/container>
- Tart: <https://github.com/cirruslabs/tart>
- MunkiStudio ROADMAP item #6 in `../../ROADMAP.md`
