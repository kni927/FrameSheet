# TASK: Bundle Identifier Change + Version Sync + Consistent Dev Signing

## Goal

Change the bundle identifier from `com.gemini.FrameSheet` (leftover
from the Antigravity-based initial build) to `com.kni.FrameSheet`, fix
`CFBundleShortVersionString`/`CFBundleVersion` to actually track git
tags going forward (currently stuck at 2.0.0 despite v2.1.0–v2.3.0
having shipped), and switch debug builds to always sign with the
Developer ID certificate (same identity as release builds), so TCC
grants survive rebuilds. Notarization stays release-only.

No functional/behavior changes. Docs/config/build-script only.

## Part 1 — Bundle identifier

- Find every occurrence of `com.gemini.FrameSheet` in the repo (Info.plist
  or equivalent, `build.sh`, entitlements, any codesign/notarization
  scripts, README, docs) and change to `com.kni.FrameSheet`.
- If notarization/codesign steps reference the bundle ID explicitly
  (e.g. keychain profile lookups, `xcrun notarytool` invocations),
  update those too — note in the report if notarization credentials
  need to be re-registered under the new ID (that part is manual, on
  Master's Apple Developer account — flag it, don't attempt it).
- Note in `docs/DEV_LOG.md`: changing bundle ID means
  `~/Library/Preferences/com.gemini.FrameSheet.plist` is orphaned —
  existing installs lose their persisted Phase 2 settings on first
  launch of the new build. This is expected and acceptable (pre-public-
  release housekeeping); do not attempt migration.

## Part 2 — Version sync

- Set `CFBundleShortVersionString` to `2.3.0` (matching the current
  `v2.3.0` git tag) and `CFBundleVersion` (build number) to a sane
  value — check what convention (if any) existing tags/commits imply;
  if none, use a simple monotonic integer and document the starting
  point.
- Update `build.sh` (or add a small step) so future builds pull the
  version from the latest git tag automatically (e.g.
  `git describe --tags --abbrev=0`), rather than requiring a manual
  Info.plist edit per release. Document the mechanism in
  `docs/task-workflow.md` or wherever the release procedure is
  recorded, so the next Phase's release step includes it by
  construction.
- Verify: `./build.sh`, then check the built app's Finder "Get Info"
  version (or `mdls -name kMDItemVersion` / `defaults read .../Info
  CFBundleShortVersionString`) shows `2.3.0`.

## Part 3 — Consistent Developer ID signing for debug builds

- Update `build.sh` so debug/dev builds sign with the same Developer
  ID Application certificate used for releases (`codesign --sign
  "Developer ID Application: ..." --options runtime`), instead of
  ad-hoc/no signing. Read the identity from an existing convention if
  one exists (e.g. an env var or config already used by the release
  path); if none exists, introduce one and document it rather than
  hardcoding the identity string in two places.
- **Do not notarize debug builds** — notarization stays a release-only
  step (per the existing release procedure). Only the signing identity
  becomes consistent between debug and release; the notarization
  ticket/stapling does not.
- Confirm this doesn't conflict with the existing `~/Applications`
  debug-install rule (Homebrew/LaunchServices conflict avoidance) —
  the signing identity change and the install-location rule are
  orthogonal; both should hold simultaneously.
- Document in `docs/DEV_LOG.md` and `docs/DECISIONS.md`: why debug
  builds now sign with Developer ID (TCC grants tied to bundle ID +
  code signature; ad-hoc/unsigned builds invalidate grants like
  Accessibility/Files-and-Folders on every rebuild — same class of
  issue as EnterRemap's Accessibility API, applicable to FrameSheet
  mainly for folder-scoped file access).

### Part 3 verification

- Two consecutive debug builds (`./build.sh` run twice, no source
  changes needed) produce the same signing identity
  (`codesign -dv` shows identical "Authority" chain both times).
- If practical to check locally: grant a TCC permission (e.g. Files
  and Folders for a test folder) to the debug build, rebuild, confirm
  the grant is retained rather than re-prompted. If not practical to
  verify in this environment, note it as unverified in the report
  rather than skipping silently.
- Existing codesign/notarization release script still produces a
  notarized, stapled release build — this task must not regress that
  path.

## Verification

- `./build.sh` succeeds, no new warnings.
- Built app's bundle ID is `com.kni.FrameSheet` (check via `mdls` or
  `codesign -dv --verbose=4`).
- Built app's version shows `2.3.0` in Finder Get Info.
- Render harness (30 items) + smoke suite (36 items) pass unchanged —
  this task shouldn't touch decode/render logic at all.
- Fresh launch on a clean (or renamed-aside) preferences state
  confirms the app starts cleanly with defaults under the new bundle
  ID (no crash reading absent prefs).

## Wrap-up

- `docs/DECISIONS.md`: record the bundle ID change and the version-
  from-tag build mechanism.
- `docs/DEV_LOG.md` entry.
- Archive this task to `docs/tasks/`.
- After merge to `main`: tag `v2.3.1` (patch — housekeeping only, no
  behavior change). Release notes: bundle identifier changed to
  `com.kni.FrameSheet`; build now syncs app version from git tag; debug
  builds now sign with Developer ID (notarization remains release-only).

## Constraints

- No Swift logic/decode/render changes.
- Follow `AGENTS.md` / `CLAUDE.md`. Branch off current `main`
  (`v2.3.0`).
- Keep Parts 1–3 as separate commits (bundle ID, version sync,
  signing) even though they land in one PR/tag.
