# Lidless

A macOS menu bar app (macOS 14+, Apple Silicon first, Intel supported) that:

1. **Keeps the Mac awake** on demand (IOPMAssertions, no root).
2. **Keeps it fully awake with the lid closed and no external display** (`pmset -a disablesleep 1`), so long Claude Code sessions keep running and stay reachable over the network.
3. **Forces the fans** to max or a chosen RPM while active, and always hands them back to automatic.

It runs outside the App Store (Developer ID + notarisation), because the sandbox would block all of this.

> [!WARNING]
> Lid-closed mode disables all system sleep, and fan control writes directly to the SMC. Both are guarded (see [Safety defaults](#safety-defaults)) and always restored, but **use them at your own risk**. Don't put a running Mac in a bag.

**Status:** early. There's no pre-built download yet, so for now you [build it from source](#build-from-source). It has been tested on an Apple M5 MacBook Pro (Mac17,2, macOS 26): keep-awake, lid-closed mode, fan Max/Auto, and `kill -9` restore. The fan write paths for M1–M4 and Intel are based on how other open-source tools do it, but are **untested**; reports are welcome (see [Contributing](#contributing)).

## Architecture

```
Lidless.app  (SwiftUI MenuBarExtra, LSUIElement)          LidlessHelper  (LaunchDaemon, root)
 ├─ Keep Awake: IOPMAssertion (dies with the app)          ├─ SessionController: owns ALL privileged state
 ├─ reads SMC (fan RPM, temps) – read-only                 ├─ pmset disablesleep / displaysleepnow / sleepnow
 └─ NSXPCConnection ──── heartbeat every 2 s ────────────▶ ├─ SMC fan writes
      (requires helper: anchor apple generic,              ├─ 1 Hz guards: heartbeat, thermal, battery, AC,
       id dev.lidless.helper, team OU)                     │   max session, end condition, fan re-assert
                                                           ├─ state.json (persisted BEFORE every change)
                                                           └─ accepts only: id dev.lidless.Lidless + team OU
```

- **Helper registration:** `SMAppService.daemon(plistName: "dev.lidless.helper.plist")`; the plist lives in `Contents/Library/LaunchDaemons`, the binary in `Contents/MacOS/LidlessHelper`. The user approves it once in System Settings → General → Login Items & Extensions.
- **Signature checks both ways:** `NSXPCConnection.setCodeSigningRequirement` on the helper (per accepted connection) and on the app. The team ID comes from `Config/Signing.xcconfig` → `LidlessTeamID` in both Info.plists, so there's no hard-coded ID in the source.
- **Restore paths.** The helper restores the original `disablesleep` and sets fans to auto when any of these happens:
  - **The XPC connection is invalidated** (app quit, crash, `kill -9`). This is immediate.
  - **Heartbeats stop for 6 s** (the app hung or was suspended). Heartbeats are timed on `CLOCK_UPTIME_RAW`, so system sleep doesn't count as a missed heartbeat.
  - **The helper gets SIGTERM.**
  - **The helper launches and finds `state.json`.** This covers a helper crash: `KeepAlive` relaunches it straight away. It also covers a reboot, because `RunAtLoad` starts it at boot.
  - **System sleep (fans only).** Lid mode deliberately survives a sleep the user asked for.
  - **Logout or power-off.** The app calls `restoreAll` synchronously.
- **Fan control is probed at runtime, not hard-coded.** The code reads the mode key's case, whether `Ftst` exists, and each key's data type from the SMC's own key info. See `Core/Sources/LidlessCore/Fans.swift` for the per-generation notes.

| Platform | Manual | Back to auto |
|---|---|---|
| **M5** (verified on this Mac17,2: `F0md` ui8, no `Ftst`, `flt`) | `F0md=1`, then `F0Tg=<rpm>` | `F0md=0`, `F0Tg=0` |
| **M1–M4** | `F0Md=1`. If rejected (0x82) and `Ftst` exists: `Ftst=1`, retry the mode write for up to ~12 s, then `F0Tg` | Mode `0`, then `Ftst=0` |
| **Intel T2** | `F0Md=1`, then `F0Tg` (`fpe2`) | `F0Md=0` |
| **Intel** | `FS! ` bit, then `F0Tg`, or raise `F0Mn` as a floor | Restore the original `FS! ` or `F0Mn` (both are saved in `state.json`) |

While an override is active, the helper re-checks it every 5 s and re-applies it if the OS has taken the fan back.

## Layout

```
Core/                 Swift package: LidlessCore (SMC, codec, fans, sensors, session logic, XPC protocol),
                      CSMC (C struct + IOKit calls), lidless-smc (read-only CLI), 34 unit tests
App/                  menu bar app
Helper/               daemon main.swift, embedded Info.plist, launchd plist
Config/Signing.xcconfig   signing identity; includes Config/Local.xcconfig (git-ignored) for your Team ID
project.yml           XcodeGen spec → Lidless.xcodeproj
scripts/              build-debug.sh, release.sh (archive → export → notarise → staple → zip/dmg)
docs/                 read-only SMC dump from an M5, TESTING.md
```

## Build from source

### Requirements

- macOS 14 or later, and Xcode 16 or later.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- A **Developer ID Application** certificate from a paid Apple Developer account. A privileged helper registered with `SMAppService` has to be signed, and the app and helper check each other's team ID over XPC.

### Steps

```bash
git clone https://github.com/whyMiso/lidless.git && cd lidless
cp Config/Local.xcconfig.example Config/Local.xcconfig   # put your Team ID in it
scripts/build-debug.sh                                   # → build/DerivedData/Build/Products/Debug/Lidless.app
ditto build/DerivedData/Build/Products/Debug/Lidless.app /Applications/Lidless.app
open /Applications/Lidless.app
```

To find your Team ID, run `security find-identity -v -p codesigning`. It's the 10 characters in parentheses after "Developer ID Application".

**First run.**
1. Click **Install Helper…** in the menu.
2. Approve **Lidless** in System Settings → General → Login Items & Extensions.

Lidless has to live in `/Applications`, because `SMAppService` records the bundle path.

**Uninstall.**
1. In Settings → Helper, click **Uninstall Helper**. This restores everything first.
2. Quit Lidless and delete it from `/Applications`.

**Tests.** Run `(cd Core && swift test)`. They cover the codec, pmset parsing, and every restore and guard path.

**Read-only SMC explorer.** It never writes anything:

```bash
(cd Core && swift run -c release lidless-smc --read-only)   # fans + discovered temperature sensors
(cd Core && swift run -c release lidless-smc --all)         # every key — includes hardware serials, keep it private
```

The helper binary also accepts `--read-only`.

**Release.** Do the one-time `notarytool store-credentials` step described at the top of `scripts/release.sh`, then run `scripts/release.sh`.

**Debug builds only.** You can drive a running Debug build from the shell (`scripts/debug-command.swift fan-max|fan-auto|lid-on|lid-off|status`) and simulate thermal or battery conditions (see `docs/TESTING.md`). Release builds compile neither of these in.

## Safety defaults

- Lid mode works on **battery or AC**. You can restrict it to AC power in Settings → Safety → “Only allow on AC power”.
- On battery it turns off below **20 % battery** (adjustable).
- Sessions are capped at **8 h**.
- **Serious** thermal state sends a notification.
- **Critical** thermal state turns lid mode off, hands fans back to the system, and sleeps the Mac if the lid is closed.
- When the lid closes, the display is turned off.
- "While `claude` is running" ends **2 min** after the last `claude` process exits. Matching is exact and case-sensitive, so the Claude desktop app doesn't count. A node-based `claude` is matched by its argv[0].

The menu bar icon shows the current state:

| Icon | State |
|---|---|
| `eye.slash` | idle |
| `eye` | keeping awake |
| eye with warning badge | lid mode |
| `+ fan` | fans overridden |

## Contributing

Issues and PRs are welcome. The most useful contribution right now is a hardware report from a Mac other than the M5:

1. Run `(cd Core && swift run -c release lidless-smc --read-only)`.
2. Note whether **Max** and **Auto** worked.
3. Open an issue with your model and both results.

**Please don't post `--all` output**, because it contains serial numbers. Before sending a PR, run `swift test` in `Core/`.

## License

[MIT](LICENSE). Provided as-is, without warranty; see the license for details.
