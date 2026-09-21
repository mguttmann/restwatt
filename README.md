# Restwatt

A small, native macOS menu bar app that shows how much power your Mac is drawing from
its battery right now, how long the battery will last at that rate, and which of your
processes are burning the most energy. The estimate starts from the current draw and
gets steadier the longer the app runs.

Pure Swift on AppKit, IOKit and libproc. No Electron, no web view, no dependencies, no
network, nothing written to disk.

## What it shows

**Menu bar title** while discharging: the current draw in watts and the smoothed time
to empty as `h:mm`, for example `7.9 W  8:12`. Until the first gauge reading arrives it
shows `--:--`. While charging the title reads `Charging` plus macOS's own time to full
when the gauge knows it; on AC power without charging it reads `On AC` (with the
percentage once the battery is full). Without a battery it reads `No battery`.

**Mouseover** on the item shows a native tooltip with the details:

```
Restwatt
Battery 95 %, 63.0 Wh remaining
Drawing 7.1 W now
Time left at current draw: 8:49
Time left, smoothed (42 min observed, confidence high): 8:40
macOS estimate: 7:46
Top processes (your processes, CPU energy only, estimate):
  com.apple.WebKit.WebContent  0.02 W
  Restwatt  0.01 W
  Terminal  0.01 W
  Visible total 0.04 W over 3 processes, unaccounted 7.10 W
```

The tooltip text is refreshed on every sample. Whether macOS actually displays it
while you hover over the menu bar item has not been verified by an automated test;
please open an issue if it does not appear for you.

**Click** on the item opens a menu with the same lines, the top five processes, the
version number and `Quit Restwatt`. The menu is rebuilt from the latest sample each
time it opens.

## How the estimate works

Restwatt reads the battery gauge (`AppleSmartBattery` in the IOKit registry) every
30 seconds (`Sampling.interval` in `Sources/RestwattCore/BatteryMonitor.swift`). From
each reading it derives:

- **Draw in watts**: the gauge's own `BatteryPower` figure. If that figure disagrees
  with voltage times amperage by more than 10 %, voltage times amperage wins.
- **Remaining energy in Wh**: remaining charge (mAh) times the present voltage. It is
  deliberately not derived from the percentage, because the gauge's full-charge
  capacity drifts between readings.
- **Time left at current draw**: remaining Wh divided by the current draw. This is the
  "if it keeps drawing like right now" figure.

The **smoothed** time left uses an adaptive exponentially weighted moving average of
the draw:

1. The first sample is taken as is, so the first estimate equals the current-draw one.
2. Every later sample moves the smoothed draw by a fraction that depends on a time
   constant. The time constant is half the observation window so far, clamped between
   60 seconds and 1800 seconds (30 minutes). Early on, the estimate follows the draw
   closely; after half an hour a single noisy gauge reading barely moves it, while a
   lasting change in your workload still shows up within a few multiples of 30 minutes.
3. A **confidence** level is shown next to it: `low` below 5 minutes of observation,
   `medium` below 30 minutes, `high` from 30 minutes on.

Duplicate gauge readings (same `UpdateTime`) are not fed into the estimator, so polling
more often than the gauge refreshes does not distort the average. Plugging in resets the
estimator; unplugging starts it fresh. Nothing is persisted: the estimate lives for one
session of the app.

Below a draw of 0.1 W no time to empty is shown. Times above 5999 minutes are shown as
`> 99 h`.

### What it cannot know

- The gauge decides when it updates. On the Mac Restwatt was developed on, all gauge
  values changed together about once a minute, so the "current draw" is always the
  gauge's latest average, never an instantaneous reading.
- Restwatt cannot see the future. Both figures assume the draw stays as it is (current)
  or as it has been on average (smoothed). Opening a video call will invalidate either.
- macOS keeps its own time-to-empty estimators, and they disagree with each other. The
  tooltip shows the one `pmset -g batt` shows, labelled `macOS estimate`, for comparison.
- The **process list is a partial picture and an estimate**. It ranks the processes your
  user account may inspect by the kernel's per-process CPU energy counter
  (`ri_energy_nj` from `proc_pid_rusage`), aggregated by process name, as average watts
  over the last interval. Root and system processes, the display, the GPU and the rest
  of the SoC are invisible to an unprivileged app. The `Visible total` and the
  `unaccounted` remainder make that gap explicit; on the Mac Restwatt was developed
  on, the visible processes accounted for well under a watt of the several watts the
  battery delivered. If no process reported measurable energy over the last interval,
  the list says so instead of listing anything.

## Requirements

- macOS 14 or newer (declared once in `Package.swift` and in the app's
  `LSMinimumSystemVersion`).
- A Mac with a built-in battery. On a desktop Mac the item shows `No battery`.
- To build: Xcode 16 or newer (Swift 6.0 toolchain). No third-party packages.

## Build and install

```sh
make app            # swift build -c release, assembles dist/Restwatt.app, ad-hoc signs it
make run            # builds and opens the app
make install        # copies dist/Restwatt.app to /Applications
```

`make app` calls `scripts/make-app.sh`, which writes only below `.build/` and `dist/`,
fills `packaging/Info.plist.template` with the version from the `VERSION` file, sets
`LSUIElement` (no Dock icon) and signs the bundle ad hoc. There is no Developer ID
signature and no notarization: Gatekeeper may ask you to confirm the first launch
(right-click the app, choose Open, or allow it under System Settings > Privacy &
Security).

Quit the app from its menu (`Quit Restwatt`). There is no login item; add it to your
Login Items in System Settings yourself if you want it at startup.

## Footprint

Sampling happens on one timer with a fixed interval of 30 seconds; there is no
background work between ticks. Measured with `ps -o %cpu,rss,cputime` on the assembled
0.1.0 bundle running idle on an Apple silicon MacBook while discharging: `%cpu` reported
0.0 in every 30-second sample over a 6-minute window, the process accumulated about
0.8 s of CPU time over 70 minutes of running, and resident memory stayed at about
46 MB. That is one measurement on one machine, not a guarantee.

## Privacy

- No network access, no telemetry, no analytics, no crash reporting.
- Nothing is written to disk. There is no preferences file and no history.
- From the battery registry entry only these keys are read: `UpdateTime`, `Voltage`,
  `Amperage`, `CurrentCapacity`, `IsCharging`, `ExternalConnected`, `FullyCharged`,
  `AvgTimeToEmpty`, `AvgTimeToFull` and, inside `BatteryData`, `BatteryPower`,
  `RemainingCapacity`, `FullChargeCapacity`, `DesignCapacity`. From IOPowerSources only
  the time-to-empty estimate is read. Serial numbers and manufacturer data are not read,
  logged or shown.
- From processes only the pid, the name and the rusage counters are read.

## Repository layout

```
Package.swift                      SwiftPM manifest: tools 6.0, macOS 14, no dependencies
VERSION                            the one place the version lives (Semantic Versioning)
Sources/RestwattCore/              pure logic, no AppKit or IOKit, unit-tested
  BatterySnapshot.swift            data model, PowerState, reader protocols
  PowerMath.swift                  draw, remaining Wh, minutes to empty
  TimeToEmptyEstimator.swift       adaptive EWMA and confidence
  ProcessEnergyRanker.swift        per-process energy deltas, aggregation by name
  BatteryMonitor.swift             one tick: read, dedupe, estimate, rank; Sampling.interval
  Formatting.swift                 every user-visible string
Sources/RestwattApp/               the menu bar app
  main.swift                       NSApplication bootstrap, accessory activation policy
  AppDelegate.swift                timer, power-source notification, wiring
  StatusItemController.swift       NSStatusItem title, tooltip, click menu
  IOKitBatteryReader.swift         AppleSmartBattery registry and IOPowerSources
  LibprocProcessReader.swift       proc_listallpids and proc_pid_rusage (RUSAGE_INFO_V6)
Tests/RestwattCoreTests/           XCTest suite; runs without a battery or privileges
packaging/Info.plist.template      bundle metadata, version filled in from VERSION
scripts/make-app.sh                assembles and ad-hoc signs dist/Restwatt.app
Makefile                           build, test, app, run, install, clean
.github/workflows/ci.yml           swift build, swift test, make app on macOS runners
CHANGELOG.md                       Keep a Changelog
CLAUDE.md                          binding conventions for contributors and agents
```

## Development

```sh
swift build
swift test
```

`RestwattCore` has no AppKit or IOKit import; hardware and process access sit behind the
`BatteryReading`, `ProcessReading` and `ClockReading` protocols with test doubles, so the
tests run on any Mac and on CI. The suite pins the menu bar and tooltip strings, the
estimator behaviour (including a test that fails when the time constant is not adaptive),
the ranker's handling of pid reuse, and a few repository invariants: `VERSION` matches the
latest CHANGELOG release, this README states the sampling interval, and no file contains
an em dash or en dash.

CI runs on GitHub Actions (`macos-latest` and `macos-15`, the lower edge for
`swift-tools-version: 6.0`) on every push and pull request and needs no secrets.

## License

MIT, see `LICENSE`.
