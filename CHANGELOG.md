# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.3] - 2026-10-16

### Changed

- House brand shape pass: README header icon 120, CI template byte-exact
  to the kit.
- Base config ships with formatting off (object formatter value silently
  rewrites authored bytes; formatters stay manual).
- Removed dead CI badge from README (GitHub Actions stopped estate-wide).

## [0.3.2] - 2026-10-11

The published `0.3.1` tarball on npm is immutable and was built from a
revision whose history carried the author's local path (`bin/cli.js`).
This patch release re-ships from the purged history so the registry
carries a clean artifact, plus the fixes below.

### Added

- House `assets/icon.svg` and `assets/signature.svg`.
- `CHANGELOG.md` (Keep a Changelog) and the house `LICENSE` wording.

### Changed

- House CI shape on `.github/workflows/ci.yml`; the real gates
  (`bun test`, `npm run check`) are unchanged.
- Rebuilt `README.md` on the house skeleton; dropped a stale licence
  word from the house footer.

### Fixed

- Installer (`bin/cli.js`): validate every JSONC input before the first
  write; honour `--dry-run` / `--ci` print-only before preflight and in
  `setup --uninstall`; replace files atomically; sweep installer crash
  litter; resolve `OPENCODE_CONFIG_DIR` to an absolute path.
- Removed author machine details from lint comments in `bin/cli.js`.
