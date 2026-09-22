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
- Click menu with the same rows, the top five processes, the settings section (below),
  the version and `Quit Restwatt`. Information lines are enabled items without an
  action, so they are drawn in the normal label colour instead of the disabled grey.
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
- One 30-second sampling timer; no network. The only file written is the settings file
  under Application Support, and only when a toggle changes.
- Settings section in the click menu (headings `Power` and `Sync`, checkmark items),
  replacing two hand-run shell scripts. `Keep awake`, `Keep display awake` and
  `Keep disk awake` hold IOKit power assertions (`PreventUserIdleSystemSleep`,
  `PreventUserIdleDisplaySleep`, `PreventDiskIdle`) in Restwatt's own process: no
  privileges, released when toggled off and with the process; the choice is remembered and
  re-acquired at launch. `Stay awake with the lid closed` writes the system-wide `pmset`
  awake profile (`disablesleep 1`) as administrator and, when turned off, a fixed saver
  profile; it tries the non-interactive `sudo -n` first, call by call, and tells sudo
  refusing to run without a password (exit status 1 with sudo's `a password is required`
  or `a terminal is required` on stderr) apart from `pmset` itself failing as root. A
  sudo-side failure (exit status 1 with a line sudo prefixed `sudo:` on stderr, the denial
  included) opens the native administrator dialog, one per profile and only for the calls
  sudo did not get to run; when that dialog is declined the toggle names the `sudo -n`
  command line that actually ran, its message and the dialog's answer. A `pmset` failure
  (its own `pmset:` message, an empty stderr or any other exit status) stops the profile at
  that call, opens no dialog, re-runs nothing and shows the failing command line, exit
  status and message under the toggle; a command that fails without a message is shown as
  `<command> exit <status>` once, with nothing repeated. It runs nothing but `pmset` with
  constant arguments as root, and never creates, edits or recommends a password-free sudo
  rule.
  `iCloud Drive` and `iCloud Photos` are switched with `launchctl bootstrap`, `kickstart`
  and `bootout` in the `gui/<uid>` domain, `OneDrive` is launched hidden through
  LaunchServices (its primary bundle identifier first, with the reason for that one shown
  when every identifier fails) and asked to quit; these are immediate actions, nothing is
  stored for them. Every checkmark shows the state read from the system when the menu opens and after
  each click, never a stored intention; a failed action leaves the checkmark as observed
  with the reason under the item.
- Safety of the persistent setting: the menu warns under the toggle that it is
  system-wide, needs administrator rights and is restored when Restwatt quits. Restwatt
  records that it is turning `disablesleep 1` on BEFORE `pmset` runs as root (write-ahead);
  when the settings file cannot be saved, the awake profile is not written and the toggle
  says `not written, the settings file could not be saved`. It writes the saver profile
  back at quit, and at launch when the record says on and `pmset -g` still shows
  `SleepDisabled 1` (the gap a crash, `kill` or Force Quit leaves, since those skip the
  quit step). A record that is on while `pmset -g` shows `SleepDisabled 0` (the write never
  landed, or somebody else reset it) is dropped quietly, at launch and after a click; a
  record that is on while `pmset -g` cannot be read stays for the quit reconcile. The
  record written ahead of a click also follows the outcome of that write, not only the
  later reading: when no call of the awake profile ran as root (dialog cancelled, sudo
  denied and the dialog declined, or the first call refused), the record is dropped at
  once, whether or not `pmset -g` can be read afterwards, so quitting Restwatt writes
  nothing then; when at least one call landed, the record stays and quit or the next
  launch writes the saver profile. Every settings action runs on its own: a failure records
  its reason on its toggle and never skips the rest, so the launch reset cannot be starved by a refused power assertion, and
  a remembered assertion the system refuses at launch keeps its stored choice, shows off
  with the reason and is tried again at the next launch; clicking that refused item clears
  the stored choice instead of retrying, so the settings file can be cleaned from the menu,
  and the next click turns it on again. When `pmset -g` cannot be read, turning the
  lid-closed toggle on is refused with `not written while SleepDisabled could not be read`,
  the reason shown once under the item; turning it off while Restwatt's record says on still writes the saver
  profile. A `SleepDisabled 1` set outside Restwatt is left alone and shown as
  `set outside Restwatt`. Sync is not touched at launch or quit, so sync turned off stays
  off until it is turned on again.
- Settings file `~/Library/Application Support/Restwatt/settings.json` holding the three
  awake choices and the "armed by Restwatt" flag, written atomically and only on change; a
  missing or unreadable file means everything off. This deliberately lifts the earlier
  "nothing persisted, no preferences" stance; the README privacy section documents it.
- `RestwattCore` additions behind protocols with test doubles: settings model, fixed
  argument vectors for `pmset`, `launchctl`, `sudo` and `osascript`, parsers for `pmset -g`
  and `launchctl print`, reconcile decisions and coordinator. The tests pin the exact
  commands of the replaced scripts; repository checks require the README to name the
  settings file and quote every `pmset` call, and no source file to name a shell. A
  refused IOKit power assertion is reported with its `IOReturn` as unsigned hex
  (`e00002bc`), not as a negative number.
- `RestwattCore` library with hardware-free unit tests, including repository consistency
  checks (version, sampling interval in the README, no em or en dashes).
- `make app` and `scripts/make-app.sh` assembling an ad-hoc signed `dist/Restwatt.app`
  from the SwiftPM release product, version taken from `VERSION`.
- GitHub Actions CI on `macos-latest` and `macos-15`: `swift build`, `swift test`,
  `make app`, bundle verification; no secrets; the checkout action is pinned by commit SHA.

[Unreleased]: https://github.com/mguttmann/restwatt/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mguttmann/restwatt/releases/tag/v0.1.0
