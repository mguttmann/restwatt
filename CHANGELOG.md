# Changelog

All notable changes to Restwatt are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The version lives in the `VERSION` file.

## [Unreleased]

## [0.1.0] - 2026-09-21

### Added

- Menu bar item (no Dock icon) showing the current battery draw in watts and the
  smoothed time to empty as `h:mm`. The state follows the net energy flow of the battery,
  not the gauge's flags alone: draining on battery (`7.9 W  8:12`), draining although an
  external source is connected because it delivers less than the Mac uses
  (`2.3 W  27:47  weak source`), charging with Restwatt's own smoothed time to full
  (`Charging  0:22`), `On AC` inside a 0.5 W dead band around zero flow (with the
  percentage once fully charged), the charge level alone while a plug or unplug event
  waits for the next gauge reading, and `No battery`.
- Hover popover on mouseover (no click needed) with charge level, remaining Wh, current
  draw, time left at current draw, smoothed time left with observation time and
  confidence, macOS's own estimate, and the top three processes, laid out as label/value
  rows in the normal label colour with monospaced digits; the current draw and both
  time-left values are emphasised. While charging the rows are `Charging at`, `Time to
  full at current power`, `Time to full, smoothed`, `Smoothing` and `macOS estimate`
  (the gauge's `AvgTimeToFull`); with a weak source a `Power source` row explains that the
  source delivers less than the Mac uses; while the source is changing a `Power` row says
  so. The popover does not take focus, closes when the pointer leaves it and when the
  menu opens, and is rebuilt from the latest sample.
  Hover detection uses a global mouse-moved monitor with a hit test against the item's
  current frame (`PointerRegionTracker` in `RestwattCore`, unit-tested), because the menu
  bar item is system-hosted and a tracking area on it never fires. The monitor observes the
  pointer position only and stores nothing; it is removed when the app terminates.
- Click menu with the same rows, the top five processes, the version and
  `Quit Restwatt`. Information lines are enabled items without an action, so they are
  drawn in the normal label colour instead of the disabled grey.
- Adaptive energy-flow estimator (`EnergyFlowEstimator`) for both directions: time to
  empty from the remaining Wh and the draw, time to full from the missing Wh (full-charge
  minus remaining capacity at the present voltage) and the charging power. Starts from the
  current value and smooths with a time constant that grows with the observation window
  (60 s to 1800 s), with a low, medium or high confidence level. Restarts whenever the
  shown state changes (direction flip, battery-only to weak source, plug or unplug). The
  time to full is linear and knows no charge curve; the gauge's own figure stays visible
  for comparison.
- `Source rating` row with the connected source's rated power from `AdapterDetails.Watts`,
  omitted when no source is connected or the gauge reports no rating. The weak-source,
  slow-charge and near-zero states are covered by synthetic unit-test fixtures only; the
  charging path was verified against a measured 96 W USB-C charger reading.
- Per-process energy ranking of the user's own processes from the kernel's
  `ri_energy_nj` counter, aggregated by process name and labelled as a partial estimate,
  with visible total and unaccounted remainder.
- Battery reading from the `AppleSmartBattery` IOKit registry entry, deduplicated by
  gauge `UpdateTime`; immediate re-sample on power source changes. A reading whose
  `ExternalConnected` flag flipped while its `UpdateTime` stayed the same predates the
  change and is shown as the charge level only until the gauge moves on, so a fresh
  charger is not shown as a weak source and unplugging does not show a negative draw
  when the flip arrives before the gauge's next reading (a flip that arrives together
  with a new reading is trusted as is). A
  charge percentage outside 0 to 100 is treated as unreadable, because the gauge key
  semantics were only verified on Apple silicon.
- One 30-second sampling timer; no network, no files written.
- `RestwattCore` library with hardware-free unit tests, including repository consistency
  checks (version, sampling interval in the README, no em or en dashes).
- `make app` and `scripts/make-app.sh` assembling an ad-hoc signed `dist/Restwatt.app`
  from the SwiftPM release product, version taken from `VERSION`.
- GitHub Actions CI on `macos-latest` and `macos-15`: `swift build`, `swift test`,
  `make app`, bundle verification; no secrets; the checkout action is pinned by commit SHA.

[Unreleased]: https://github.com/mguttmann/restwatt/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mguttmann/restwatt/releases/tag/v0.1.0
