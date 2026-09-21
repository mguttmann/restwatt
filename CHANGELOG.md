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
- Native tooltip on mouseover with charge level, remaining Wh, current draw, time left
  at current draw, smoothed time left with observation time and confidence, macOS's own
  estimate, and the top three processes.
- Click menu with the same details, the top five processes, the version and
  `Quit Restwatt`.
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
