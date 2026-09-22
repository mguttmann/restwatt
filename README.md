# Restwatt

A small, native macOS menu bar app that shows how much power your Mac is drawing from
its battery right now, how long the battery will last at that rate, and which of your
processes are burning the most energy. While the battery charges it shows the charging
power and its own time to full instead. Both estimates start from the current value and
get steadier the longer the app runs. Its click menu also carries a few settings: keep
the Mac, its display or its disk awake while Restwatt runs, keep the Mac awake with the
lid closed, and start or stop iCloud Drive, iCloud Photos and OneDrive syncing.

Pure Swift on AppKit, IOKit and libproc. No Electron, no web view, no dependencies, no
network. The one file it writes is its settings file (see "What it can do" and "Privacy").

## What it shows

**Menu bar title** while the battery is draining: the current draw in watts and the
smoothed time to empty as `h:mm`, for example `7.9 W  8:12`. Until the first gauge
reading arrives it shows `--:--`. The state is decided by the direction of the energy
flow through the battery, not by whether something is plugged in:

- Energy leaves the battery and no external source is connected: `7.9 W  8:12`.
- Energy leaves the battery although an external source is connected (a power bank or a
  small adapter that delivers less than the Mac uses): the same figures plus the marker
  `weak source`, for example `2.3 W  27:47  weak source`. The watts are what the battery
  still supplies on top of the source, not the whole system draw.
- Energy enters the battery: `Charging` plus Restwatt's own smoothed time to full, for
  example `Charging  0:22`; just `Charging` until the first estimate exists.
- An external source is connected and the net flow is inside a small dead band around
  zero: `On AC`, or `On AC  100 %` once the gauge reports the battery as fully charged.
- The source was just plugged in or unplugged and the gauge has not caught up yet: only
  the charge level, for example `95 %` (see "Which state is shown" below).

Without a battery it reads `No battery`.

**Mouseover** on the item opens a popover with the details, without a click. It appears
after a short delay while the pointer rests on the item and closes shortly after the
pointer leaves both the item and the popover (the delays are the `showDelay` and
`hideDelay` constants in `Sources/RestwattApp/StatusItemController.swift`). The popover
is a two-column label/value grid in the normal label colour, so it follows a light or
dark menu bar; the numbers use monospaced digits, and the three figures to read at a
glance, the current draw and both time-left values, are set larger and bolder:

```
Battery                          95 %, 63.0 Wh
Drawing now                              7.1 W
Time left at current draw                 8:49
Time left, smoothed                       8:12
Smoothing        42 min observed, confidence high
macOS estimate                            7:46

Top processes (your processes, CPU energy only, estimate)
Discord Helper (Renderer) (2 processes)  0.42 W
com.apple.WebKit.WebContent              0.02 W
Restwatt                                 0.01 W
Visible total    0.63 W over 105 processes, unaccounted 6.51 W
```

With a weak source the same rows appear, `Drawing now` being what the battery still
supplies, followed by a `Power source` row that says `connected, but it delivers less
than the Mac uses`. While charging the rows are `Charging at`, `Time to full at current
power`, `Time to full, smoothed` with the same `Smoothing` note, and `macOS estimate`
for the gauge's own time to full (or `not yet available` when the gauge does not know
one):

```
Battery                          75 %, 51.7 Wh
Charging at                             49.1 W
Time to full at current power             0:22
Time to full, smoothed                    0:22
Smoothing         0 min observed, confidence low
macOS estimate                            0:50
Source rating                             96 W
```

`Source rating` is the rated power of the connected source as the gauge reports it
(`AdapterDetails.Watts`); the row appears in every state with a source connected, except
while the source is changing, and is omitted when the gauge does not report a rating. On
AC power inside the dead band a single `Power` row says `On AC, fully charged` or
`On AC, not charging`; while the source is changing it says `power source changed,
waiting for the gauge`. Before the first estimate the time row reads `waiting for the
first gauge reading`.

The popover does not take focus away from the app you are working in and is rebuilt from
the latest sample whenever it is shown or a new sample arrives while it is visible. It
closes when the click menu opens. The menu bar item is hosted by the system, not by a
window the app owns, so Restwatt cannot be told directly when the pointer enters it.
Instead it watches pointer movement system-wide and checks each position against the
item's current frame; only the resulting enter and leave transitions drive the popover.
The rows and the enter/leave logic (`PointerRegionTracker`) come from the unit-tested
`RestwattCore` layer; showing and hiding the popover itself is AppKit code without an
automated test, so please open an issue if the popover does not appear or does not go
away for you.

**Click** on the item opens a menu with the same rows, the top five processes, the
settings section described under "What it can do", the version number and
`Quit Restwatt`. The information lines are drawn in the normal label
colour (they are enabled menu items without an action; selecting one only closes the
menu). The menu is rebuilt from the latest sample each time it opens, and Cmd-Q inside
the menu quits.

## What it can do

The click menu ends with a settings section: two headings with checkmark items under
them. It replaces two shell scripts that used to switch the same things by hand. Every
checkmark shows the state Restwatt reads from the system when the menu opens and again
after each click (the assertion it holds, `pmset -g`, `launchctl print`, the running
applications), never a stored intention: a click that did not take effect leaves the
checkmark where it was and puts the reason in an indented line under the item.

```
Power
    [x] Keep awake
    [ ] Keep display awake
    [ ] Keep disk awake
    [x] Stay awake with the lid closed
        system-wide, needs administrator, restored when Restwatt quits
Sync
    [x] iCloud Drive  running
    [x] iCloud Photos  idle, starts on demand
    [ ] OneDrive  not running
```

**Keep awake**, **Keep display awake** and **Keep disk awake** are process-scoped. Each
holds one IOKit power assertion in Restwatt's own process (`PreventUserIdleSystemSleep`,
`PreventUserIdleDisplaySleep`, `PreventDiskIdle`, the mechanism `caffeinate` uses),
needs no privileges, and appears in `pmset -g assertions` as `Restwatt: Keep awake` and
so on while it is held. Turning a toggle off releases the assertion; quitting or killing
Restwatt releases every assertion with the process, so these three cannot outlive the
app. The choice is remembered in the settings file and re-acquired at the next launch.
If the system refuses one of them at launch, that toggle shows off with the reason under
it, the other remembered toggles are acquired all the same, and the choice stays in the
file: the checkmark follows what Restwatt holds, the file keeps what you chose, and the
next launch tries again without a click. Turning the toggle off is what changes the file;
a refused click from off changes nothing, so no file appears for it.
`Keep awake` prevents idle sleep only: closing the lid still puts the Mac to sleep. If
you run a LaunchAgent of your own that keeps `caffeinate -d` alive, `Keep display awake`
is redundant with it; Restwatt leaves such an agent alone and neither loads nor unloads
it.

**Stay awake with the lid closed** is different: it is a system setting, it needs
administrator rights, and it survives the app. Turning it on runs

```
pmset -a sleep 0 displaysleep 0 disksleep 0 hibernatemode 0 standby 0 disablesleep 1
```

and turning it off runs, in this order,

```
pmset -a disablesleep 0
pmset -b displaysleep 2 sleep 10 disksleep 10 hibernatemode 3 standby 1
pmset -c displaysleep 10 sleep 30 disksleep 10 hibernatemode 3 standby 1
pmset -a standbydelaylow 10800 standbydelayhigh 86400
```

The "off" values are one chosen saver profile (the one the replaced script wrote), not a
captured factory default and not whatever your Mac had before: Restwatt does not save or
restore earlier `pmset` values. Both command lines are constants in `RestwattCore` and
the unit tests pin them word for word, so the text above cannot drift from the code. To
run `pmset` as root, Restwatt tries `sudo -n pmset ...` for each call of the profile in
turn, which succeeds only when sudo needs no password for your account and fails at once
otherwise. Restwatt tells the two ways a call can fail apart: sudo refusing to run
without a password (`sudo -n` exits with status 1 and reports `a password is required` or
`a terminal is required` on its own stderr) is a denial; any other failure is `pmset`
itself, which ran as root and refused its arguments, for example a key this hardware does
not support. Only a denial opens the native macOS administrator dialog (`osascript`,
`do shell script ... with administrator privileges`), once per profile and only for the
calls sudo did not get to run, chained into that single dialog; the calls that already
succeeded are not run again. A `pmset` failure stops the profile at that call, opens no
dialog, re-runs nothing, and puts the failing command line, its exit status and its own
message under the toggle; the calls before it stay applied. Nothing but `pmset` with these
fixed arguments ever runs with administrator rights, no command line is built from user
data, and Restwatt never creates, edits or recommends a rule that lets sudo skip the
password. Cancelling the dialog, or any other failure, leaves the checkmark off, as
observed, with the reason under the item. The denial texts are sudo's documented wording;
the unit tests pin them, a live denial was not recorded during development.

Two safety facts, stated plainly:

1. **The lid-closed setting outlives the app, so Restwatt takes it back.** The menu says
   so under the toggle. The record comes first: when you turn the toggle on, Restwatt
   writes "armed by Restwatt" into its settings file before `pmset` runs as root, and if
   that file cannot be saved the awake profile is not written at all and the toggle says
   so (`not written, the settings file could not be saved`). So there is never a
   `disablesleep 1` of Restwatt's without a record of it, whatever happens in between.
   When Restwatt quits normally (`Quit Restwatt` or Cmd-Q) while it had turned the setting
   on, it writes the saver profile first (on a Mac where sudo asks for a password that is
   one administrator dialog at quit; cancelling it leaves the setting on, and Restwatt
   keeps the record, so it still owes the reset). A crash, a `kill` or a Force Quit skips
   that quit step: the Mac stays unable to sleep until Restwatt runs again, and the reset
   happens at that next launch. At every launch Restwatt reads its record and `pmset -g`
   and handles the four combinations: record on and `SleepDisabled 1` is Restwatt's own
   setting, so it writes the saver profile then; record on and `SleepDisabled 0` means
   the write never landed (the record was saved, then the dialog was cancelled or the
   app died before `pmset` ran) or somebody else already reset it, so the record is
   dropped quietly with no write; no record and `SleepDisabled 1` is somebody else's
   setting and is left alone; no record and `SleepDisabled 0` is nothing to do. The same
   quiet drop happens after a click whose write did not land, so a cancelled dialog does
   not leave a stale record behind. That launch write does not depend on anything else
   Restwatt does at launch; a power assertion the system refuses to re-acquire does not
   skip it. When the record is on but `pmset -g` cannot be read, the record stays and the
   quit reconcile tries again.
   Restwatt only ever takes back what it set itself. A `SleepDisabled 1` that another
   tool or script set is left alone and shown as on with the note `set outside
   Restwatt`; turning that toggle off by hand writes the saver profile all the same. The
   record, not the last writer, decides: if you turn the toggle on in Restwatt and then
   run your own `pmset` script on top, Restwatt still writes the saver profile at quit.
   So the toggle effectively means "while Restwatt runs"; for a Mac that stays awake
   without Restwatt, use `pmset` yourself.
2. **Sync off stays off until something turns it on.** `iCloud Drive` (`com.apple.bird`)
   and `iCloud Photos` (`com.apple.cloudphotod`) are switched with `launchctl bootstrap`
   plus `kickstart` and with `launchctl bootout` in your login session domain
   (`gui/<uid>`); `OneDrive` is started hidden and without activating it through
   LaunchServices (what `open -gja OneDrive` does) and stopped by the quit request the
   running application receives. These are immediate actions on the running system.
   Restwatt does not store the sync choice and does not touch sync at launch or quit, so
   once Restwatt is gone the services stay in whatever state they were left in. The
   menu shows that state to the right of each item (`running`, `idle, starts on demand`,
   `off`, `not running`), read from `launchctl print` and the list of running
   applications. To get sync back, click the item again or run `launchctl bootstrap`
   yourself; launchd is also expected to load the two system agents again at the next
   login, but that comes from the `launchctl` manual and was not measured. `bootout`
   does not disable a service, so a reboot or re-login does not keep sync off either.

A few practical notes. Starting OneDrive and asking it to quit both return before the
application has finished, so right after the click the checkmark can still show the old
state; it is read again when the menu opens next. Whether a `launchctl` call succeeded is
judged by the state read back afterwards, not by its exit code (the exit codes appear in
the reason line only when the target state was not reached). If the settings file cannot
be written, the action still happens and a line at the bottom of the section says
`settings could not be saved` with the reason; the one exception is turning `Stay awake
with the lid closed` on, which needs its record saved first and is refused otherwise
(see safety fact 1). If `pmset -g` cannot be read, the lid-closed toggle shows off with
`could not read pmset` and the reason, and nothing is written at launch. Clicking it in
that state refuses to write the awake profile (`not written, could not read pmset` plus
the reason), because a setting written blind could never be switched off from the menu
again; only when Restwatt's own record says it turned the setting on does the click write
the saver profile, the safe direction. If OneDrive cannot be started under any of its
bundle identifiers, the reason shown is the one for the primary identifier
(`com.microsoft.OneDrive-mac`), not the last fallback's. The privileged path, the
`launchctl` switching and the OneDrive control were tested against doubles that pin the
exact commands and simulate the resulting system state; they were not exercised against a
live system during development, and clicking the items is not automated. Please open an
issue if a toggle misbehaves on your Mac.

## How the estimate works

Restwatt reads the battery gauge (`AppleSmartBattery` in the IOKit registry) every
30 seconds (`Sampling.interval` in `Sources/RestwattCore/BatteryMonitor.swift`). From
each reading it derives:

- **Draw in watts**: the gauge's own `BatteryPower` figure. If that figure disagrees
  with voltage times amperage by more than 10 %, voltage times amperage wins.
- **Remaining energy in Wh**: remaining charge (mAh) times the present voltage. It is
  deliberately not derived from the percentage, because the gauge's full-charge
  capacity drifts between readings.
- **Missing energy in Wh**: full-charge capacity minus remaining charge, times the
  present voltage, never below zero (the full-charge capacity can briefly sit below the
  remaining charge while it drifts).
- **Time left at current draw**: remaining Wh divided by the current draw. This is the
  "if it keeps drawing like right now" figure.
- **Time to full at current power**: missing Wh divided by the current charging power,
  the same figure in the other direction.

The **smoothed** time uses an adaptive exponentially weighted moving average of the
power flowing through the battery. One estimator serves both directions: while the
battery drains it is fed with the draw and the remaining energy, while it charges with
the charging power and the missing energy.

1. The first sample is taken as is, so the first estimate equals the one at current power.
2. Every later sample moves the smoothed power by a fraction that depends on a time
   constant. The time constant is half the observation window so far, clamped between
   60 seconds and 1800 seconds (30 minutes). Early on, the estimate follows the power
   closely; after half an hour a single noisy gauge reading barely moves it, while a
   lasting change in your workload still shows up within a few multiples of 30 minutes.
3. A **confidence** level is shown next to it: `low` below 5 minutes of observation,
   `medium` below 30 minutes, `high` from 30 minutes on.

Duplicate gauge readings (same `UpdateTime`) are not fed into the estimator, so polling
more often than the gauge refreshes does not distort the average. The smoothing restarts
whenever the shown state changes: when the direction of the flow flips between draining
and charging, when a weak source is plugged into a Mac running on battery (the draw
changes meaning from "whole system" to "what the source does not cover"), and around a
plug or unplug event. Nothing about the estimate is persisted: it lives for one session
of the app (the settings are the one thing Restwatt stores, see "What it can do").

Below a power of 0.1 W no time is shown in either direction. Times above 5999 minutes
are shown as `> 99 h`.

### Which state is shown

With no external source connected the battery is draining, whatever the sign of the
gauge's current. With a source connected the net flow decides: a battery draw of 0.5 W
or more means `weak source` draining, a charging power of 0.5 W or more means charging,
anything in between is `On AC` and claims no power and no time. The dead band exists so
that a trickle around zero cannot flip the display back and forth; there is no further
hysteresis. The gauge's `IsCharging` flag does not override the sign, because a source
that delivers less than the Mac uses can leave the battery draining while the flags say
otherwise.

Plugging in or unplugging triggers an immediate re-sample, but the gauge's current and
power figures only change together with its `UpdateTime`, which can be up to a gauge
refresh later. A reading whose `ExternalConnected` flag flipped while its `UpdateTime`
stayed the same provably predates the change, so Restwatt shows only the charge level
(`95 %`, row `power source changed, waiting for the gauge`) until the gauge moves on,
instead of a stale direction (a fresh charger shown as `weak source`, or a negative draw
right after unplugging). A flip that arrives together with a new `UpdateTime` is trusted
as is.

### What it cannot know

- The gauge decides when it updates. On the Mac Restwatt was developed on, all gauge
  values changed together about once a minute, so the "current draw" is always the
  gauge's latest average, never an instantaneous reading.
- Restwatt cannot see the future. Both figures assume the draw stays as it is (current)
  or as it has been on average (smoothed). Opening a video call will invalidate either.
- macOS keeps its own time-to-empty estimators, and they disagree with each other. The
  details show the one `pmset -g batt` shows, labelled `macOS estimate`, for comparison.
  While charging the same row shows the gauge's own `AvgTimeToFull`, when it knows one.
- **The time to full is linear.** Restwatt divides the missing energy by the smoothed
  charging power and knows nothing about the charge curve: near a full charge the
  charger reduces the current and the last part takes longer than the arithmetic
  suggests. So while the power is still high, Restwatt's figure is shorter than macOS's
  (in the measured 96 W reading in the test suite, 0:22 next to the gauge's 0:50); it
  catches up as the power falls, because the smoothing follows it. Both figures are
  shown so you can compare.
- **Weak sources were not measured.** The charging path was verified against a gauge
  reading taken on a 96 W USB-C charger. The `weak source`, slow-charge and near-zero
  states are covered by synthetic unit-test fixtures only; nobody had a power bank or a
  small adapter at hand. The design relies on the sign of the gauge's current and on
  `ExternalConnected` being set while a source is connected, not on the flags, but that
  the gauge behaves that way on a weak source is an expectation, not a measurement.
  `AdapterDetails.Watts` may be absent on a source that does not negotiate USB-C PD; the
  `Source rating` row is then simply omitted.
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
- An Apple silicon Mac with a built-in battery. The meaning of the battery gauge keys
  (`CurrentCapacity` as a percentage, the `BatteryData` dictionary) was only verified on
  Apple silicon; on an Intel Mac the app is expected to show `No battery` rather than
  wrong numbers. On a desktop Mac the item shows `No battery`.
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

Quit the app from its menu (`Quit Restwatt`). Quitting also takes back `Stay awake with
the lid closed` if Restwatt had turned it on (see "What it can do"); on a Mac where sudo
asks for a password that shows the administrator dialog once. There is no login item; add
it to your Login Items in System Settings yourself if you want it at startup.

## Footprint

Sampling happens on one timer with a fixed interval of 30 seconds; there is no
background work between ticks. Measured with `ps -o %cpu,rss,cputime` on the assembled
0.1.0 bundle running idle on an Apple silicon MacBook while discharging: `%cpu` reported
0.0 in every 30-second sample over a 6-minute window, the process accumulated about
0.8 s of CPU time over 70 minutes of running, and resident memory stayed at about
46 MB. That is one measurement on one machine, not a guarantee.

## Privacy

- No network access, no telemetry, no analytics, no crash reporting.
- The only file Restwatt writes is `~/Library/Application Support/Restwatt/settings.json`,
  and only when a setting changes. "Nothing is written" holds for the launch path: a
  launch that touches nothing leaves no file behind. A click does write it, and turning
  `Stay awake with the lid closed` on writes it before `pmset` runs (the record comes
  first, see "What it can do"). The file holds the on/off choice of the three
  `Keep ... awake` toggles and the flag that Restwatt itself turned on `Stay awake with
  the lid closed`; a missing or unreadable file means everything off. Nothing else is
  stored: no history, no sync choice, no measurement. Deleting the file resets the
  settings; do it while `Stay awake with the lid closed` is off. Deleting it while the
  toggle is on loses the record: the setting stays on the Mac, the next launch treats the
  `SleepDisabled 1` as set outside Restwatt and takes nothing back, and quitting writes
  nothing either; turn the toggle off by hand in the menu or run the saver `pmset` calls
  yourself.
- Restwatt changes the system only when you click a setting, plus the two safety writes
  described under "What it can do" (the saver profile at quit and at launch, only when
  Restwatt itself had turned the lid-closed setting on). It runs `pmset` as administrator
  for that toggle, `launchctl bootstrap`, `kickstart` and `bootout` in your own login
  session domain for iCloud Drive and iCloud Photos, and launches or asks OneDrive to quit
  through LaunchServices. Nothing else runs with administrator rights. Restwatt itself
  starts no shell: it launches `sudo`, `pmset`, `launchctl` and `osascript` directly with
  fixed argument lists. The one place a shell runs is the administrator dialog, where
  macOS itself executes the fixed `pmset` line through its script runner (`osascript`,
  `do shell script ... with administrator privileges`); that line reaches the dialog only
  after sudo refused to run without a password, and it carries only the `pmset` calls not
  yet applied. Every token of that line is checked against a fixed alphabet before it is
  used, and every command line is built from constants in the source.
- From the battery registry entry only these keys are used: `UpdateTime`, `Voltage`,
  `Amperage`, `CurrentCapacity`, `IsCharging`, `ExternalConnected`, `FullyCharged`,
  `AvgTimeToEmpty`, `AvgTimeToFull`, inside `BatteryData` the keys `BatteryPower`,
  `RemainingCapacity`, `FullChargeCapacity`, `DesignCapacity`, and inside
  `AdapterDetails` only `Watts` (the rated power of the connected source). From
  IOPowerSources only the time-to-empty estimate is read. Serial numbers and
  manufacturer data are not read, logged or shown.
- From processes only the pid, the name and the rusage counters are read.
- Restwatt watches pointer movement system-wide only to notice when the pointer rests on
  its menu bar item. It looks at the pointer position alone, not at clicks, keys or the
  windows underneath, and stores nothing.

## Repository layout

```
Package.swift                      SwiftPM manifest: tools 6.0, macOS 14, no dependencies
VERSION                            the one place the version lives (Semantic Versioning)
Sources/RestwattCore/              pure logic, no AppKit or IOKit, unit-tested
  BatterySnapshot.swift            data model, PowerState from the net flow, reader protocols
  PowerMath.swift                  draw, remaining and missing Wh, dead band, minutes
  EnergyFlowEstimator.swift        adaptive EWMA and confidence, draining and charging
  ProcessEnergyRanker.swift        per-process energy deltas, aggregation by name
  BatteryMonitor.swift             one tick: read, settle, dedupe, estimate, rank; Sampling.interval
  Formatting.swift                 every user-visible string
  PointerRegionTracker.swift       pointer enter/leave transitions for the menu bar item
  DetailRow.swift                  label/value rows for the popover and the menu
  PowerSettings.swift              settings model, sync services, stored settings, JSON codec
  SystemCommands.swift             fixed pmset, launchctl, sudo and osascript argument vectors
  SystemStateParser.swift          parsers for pmset -g and launchctl print
  SettingsReconciler.swift         stored fact vs observed state -> actions (launch, quit, click)
  SettingsCoordinator.swift        runs the actions behind protocols, owns the settings snapshot
  SettingsRow.swift                the settings section rows of the click menu
Sources/RestwattApp/               the menu bar app
  main.swift                       NSApplication bootstrap, accessory activation policy
  AppDelegate.swift                timer, power-source notification, settings reconcile, wiring
  StatusItemController.swift       NSStatusItem title, pointer monitor, popover, menu with settings
  DetailPopover.swift              NSPopover with the detail rows in a two-column grid
  IOKitBatteryReader.swift         AppleSmartBattery registry and IOPowerSources
  LibprocProcessReader.swift       proc_listallpids and proc_pid_rusage (RUSAGE_INFO_V6)
  IOKitPowerAssertions.swift       IOPMAssertionCreateWithName and IOPMAssertionRelease
  ProcessCommandRunner.swift       Process with a fixed executable and arguments, no shell
  WorkspaceApplicationController.swift  NSWorkspace launch and NSRunningApplication quit request
  FileSettingsStore.swift          settings.json under Application Support, atomic writes
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

`RestwattCore` has no AppKit or IOKit import; hardware, process and system access sit
behind the `BatteryReading`, `ProcessReading`, `ClockReading`, `PowerAssertionHolding`,
`CommandRunning`, `SettingsStoring` and `ApplicationControlling` protocols with test
doubles, so the tests run on any Mac and on CI, launch no process and write nothing
outside memory. The suite pins the menu bar strings and detail rows of
every power state (and that the rows carry the same figures as the plain text lines),
the state decision on the net flow including both edges of the dead band, the settling
after a plug or unplug event, the estimator behaviour in both directions (including a
test that fails when the time constant is not adaptive), the fixtures being one measured
96 W charger reading plus clearly marked synthetic weak-source readings,
the ranker's handling of pid reuse, the pointer enter/leave transitions behind the hover
popover, the settings section (the exact `pmset`, `launchctl`, `sudo` and `osascript`
argument vectors of the two scripts it replaces, the `pmset -g` and `launchctl print`
parsers against measured output, the reconcile decisions at launch, quit and click, the
coordinator against a scripted double of the system, and the menu rows), and a few
repository invariants: `VERSION` matches the latest CHANGELOG release, this README states
the sampling interval, names the settings file and quotes every `pmset` call the app can
run, no source file names a shell or a password-free sudo rule, and no file contains an
em dash or en dash.

CI runs on GitHub Actions (`macos-latest` and `macos-15`, the lower edge for
`swift-tools-version: 6.0`) on every push and pull request and needs no secrets.

## License

MIT, see `LICENSE`.
