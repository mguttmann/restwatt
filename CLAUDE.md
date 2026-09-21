# CLAUDE.md

Restwatt is a small native macOS menu bar app written in Swift. It shows how much
power the Mac is drawing from its battery right now, estimates how long the battery
will last at that rate (refining the estimate the longer it runs), and lists the
processes that consume the most energy. It must stay lightweight: no Electron, no
web views, no background work beyond a slow sampling timer.

## Binding conventions

- Language: everything in this repository is English: code, identifiers, comments,
  commit messages, README, CHANGELOG, docs.
- Toolchain: Swift Package Manager only (`Package.swift` at the root, `swift build`,
  `swift test`). No `.xcodeproj` or `.xcworkspace` is checked in. The app bundle
  (`Restwatt.app`) is assembled from the SwiftPM product by a checked-in script or
  Makefile target, with `LSUIElement` set so the app has no Dock icon. Ad-hoc code
  signing only; Developer ID signing and notarization are out of scope.
- Deployment target: the minimum macOS version is declared once in `Package.swift`
  and stated in the README. Do not use APIs newer than that target without an
  availability check. The code must also compile on the GitHub Actions macOS runner
  used by CI, not only on the newest local Xcode.
- Dependencies: none by default. A third-party package needs a written justification
  in the spec or pull request and must be pinned.
- Architecture: pure logic (power math, the time-to-empty estimator, formatting)
  lives in a library target with no AppKit or IOKit import and is unit-tested.
  Hardware and process access sits behind protocols with test doubles, so
  `swift test` runs without a battery and without privileges.
- Testing: `swift test` must pass on every change. Tests assert behavior on
  realistic sample data; no mocks of mocks. New estimator behavior needs a test
  that fails on the previous implementation.
- Footprint: sampling runs on a timer, never in a tight loop; document the interval.
  Measure idle CPU usage before claiming it is low. No performance or accuracy
  numbers in docs that no measurement or test backs.
- Privacy: no network access, no telemetry, no analytics. Any persisted data (for
  example learned discharge history) lives under
  `~/Library/Application Support/Restwatt/` and is documented in the README.
- Versioning: Semantic Versioning. The version string lives in exactly one place in
  the repository and is referenced from there. Every user-visible change gets a
  `CHANGELOG.md` entry in Keep a Changelog format.
- Commits: Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`, `test:`, `ci:`),
  imperative subject line of at most 72 characters. Automated agents never commit,
  push or tag.
- Text: no em dashes or en dashes anywhere (code comments, docs, commit messages).
  Use hyphens, commas or a new sentence instead.
- CI: GitHub Actions builds and runs `swift test` on a macOS runner on every push
  and pull request. The workflow must not need secrets.
- Layout: the README documents the repository layout. Keep it in sync when the
  structure changes.
