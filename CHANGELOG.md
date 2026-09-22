# Changelog

All notable changes to Restwatt are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The version lives in the `VERSION` file.

## [Unreleased]

## [0.1.0] - 2026-09-21

### Added

- Menu bar item (no Dock icon) showing the current battery draw in watts and the
  smoothed time to empty as `h:mm`; `Charging`, `On AC` and `No battery` states.
- Hover popover on mouseover (no click needed) with charge level, remaining Wh, current
  draw, time left at current draw, smoothed time left with observation time and
  confidence, macOS's own estimate, and the top three processes, laid out as label/value
  rows in the normal label colour with monospaced digits; the current draw and both
  time-left values are emphasised. The popover does not take focus, closes when the
  pointer leaves it and when the menu opens, and is rebuilt from the latest sample.
  Hover detection uses a global mouse-moved monitor with a hit test against the item's
  current frame (`PointerRegionTracker` in `RestwattCore`, unit-tested), because the menu
  bar item is system-hosted and a tracking area on it never fires. The monitor observes the
  pointer position only and stores nothing; it is removed when the app terminates.
- Click menu with the same rows, the top five processes, the version and
  `Quit Restwatt`. Information lines are enabled items without an action, so they are
  drawn in the normal label colour instead of the disabled grey.
- Adaptive time-to-empty estimator: starts from the current draw and smooths with a time
  constant that grows with the observation window (60 s to 1800 s), with a low, medium
  or high confidence level. Resets when the Mac is plugged in.
- Per-process energy ranking of the user's own processes from the kernel's
  `ri_energy_nj` counter, aggregated by process name and labelled as a partial estimate,
  with visible total and unaccounted remainder.
- Battery reading from the `AppleSmartBattery` IOKit registry entry, deduplicated by
  gauge `UpdateTime`; immediate re-sample on power source changes. A charge percentage
  outside 0 to 100 is treated as unreadable, because the gauge key semantics were only
  verified on Apple silicon.
- One 30-second sampling timer; no network, no files written.
- `RestwattCore` library with hardware-free unit tests, including repository consistency
  checks (version, sampling interval in the README, no em or en dashes).
- `make app` and `scripts/make-app.sh` assembling an ad-hoc signed `dist/Restwatt.app`
  from the SwiftPM release product, version taken from `VERSION`.
- GitHub Actions CI on `macos-latest` and `macos-15`: `swift build`, `swift test`,
  `make app`, bundle verification; no secrets; the checkout action is pinned by commit SHA.

[Unreleased]: https://github.com/mguttmann/restwatt/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mguttmann/restwatt/releases/tag/v0.1.0
