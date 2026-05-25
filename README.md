# MunkiStudio

**MunkiStudio — package, import, edit, lint, commit, deploy.**

A modern macOS admin app for [Munki](https://github.com/munki/munki) software-distribution
repositories. Swift 6.2+ / SwiftUI / macOS 26 (Tahoe), with first-class YAML and
git support — including built-in Git, linting, and a growing set of GitOps and
QA workflows.

## Status

Pre-alpha — scaffold in place; see `/Users/rod/.claude/plans/this-brand-new-git-dapper-shell.md`
for the design plan.

## Architecture

A single Swift package with three module targets:

```
Sources/
  Core/    # Pure-Swift domain layer (models, service protocols, predicate)
  Infra/   # Yams, SwiftGit2, SwiftData mirror, file I/O, makecatalogs shell
  App/     # SwiftUI app target (MunkiStudio executable; consumes Core + Infra)
Tests/     # CoreTests, InfraTests
```

## Highlights

- **Munki 7** repo format (FileRepo backend in v1; S3/Git plugin protocol scaffolded).
- **YAML + plist** round-trip matching the format work in
  [munki#1261](https://github.com/munki/munki/pull/1261) — extension is preserved
  on save; key order is normalized; script keys emit as `|` literal block scalars.
  Comments are not preserved across round-trip in v1.
- **SwiftData index** of the on-disk repo for fast search and cross-references;
  the plist/YAML file is always the source of truth.
- **Git commit composer** built on libgit2 (reads) + shelled `git` (writes), so
  hooks, signing, SSH-agent and Keychain credentials all work.
- **Testing tab** — adapted from Cimian's `quality/` system. Per-package
  schema check, script lint, optional `munkipkg` build + artifact validation,
  ephemeral install testing in a Tart macOS VM (install / `installs[]` /
  uninstall), and a repo-local checklist that round-trips between
  `.munkistudio/testing-checklist.json` and a Markdown view for PR review.
  Enable under **Settings → Features → Testing**. See `docs/testing-tab.md`.

## License

Apache 2.0.
