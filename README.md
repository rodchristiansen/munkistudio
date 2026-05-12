# MunkiAdmin

A modern macOS admin app for [Munki](https://github.com/munki/munki) software-distribution
repositories. Swift 6.2+ / SwiftUI / macOS 26 (Tahoe), with first-class YAML and
git support.

This is a ground-up rewrite of the original [hjuutilainen/munkiadmin](https://github.com/hjuutilainen/munkiadmin),
keeping behavioral fidelity with Munki's on-disk plist/YAML formats while
reimagining the UX around modern admin workflows.

## Status

Pre-alpha — scaffold in place; see `/Users/rod/.claude/plans/this-brand-new-git-dapper-shell.md`
for the design plan.

## Architecture

```
Packages/
  Core/    # Pure-Swift domain layer (models, service protocols, predicate)
  Infra/   # Yams, SwiftGit2, SwiftData mirror, file I/O, makecatalogs shell
MunkiAdmin/  # SwiftUI app target (Xcode project consumes Core + Infra)
```

## Highlights

- **Munki 7** repo format (FileRepo backend in v1; S3/Git plugin protocol scaffolded).
- **YAML + plist** round-trip matching the format work in
  [munki#1261](https://github.com/munki/munki/pull/1261) and
  [munkiadmin#225](https://github.com/hjuutilainen/munkiadmin/pull/225) — extension
  is preserved on save; key order is normalized; script keys emit as `|` literal
  block scalars. Comments are not preserved across round-trip in v1.
- **SwiftData index** of the on-disk repo for fast search and cross-references;
  the plist/YAML file is always the source of truth.
- **Git commit composer** built on libgit2 (reads) + shelled `git` (writes), so
  hooks, signing, SSH-agent and Keychain credentials all work.

## License

Apache 2.0 — same as the original MunkiAdmin.
