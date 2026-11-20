# Instructions for AI coding agents

If someone gave you this repository and asked you to install Lidless, follow this file. If you're changing the code instead, read the [Developing](#developing) section.

Lidless is a macOS menu bar app with a root helper. It can disable system sleep (`pmset disablesleep`) and write fan speeds to the SMC, so act carefully and keep the person informed.

## Install (normal case)

1. Clone the repository if you haven't already:
   ```bash
   git clone https://github.com/whyMiso/lidless.git && cd lidless
   ```
2. Run the installer:
   ```bash
   scripts/install.sh
   ```
   It is non-interactive and idempotent, so it is safe to re-run. It checks the system, picks a code-signing certificate from the keychain, builds a Release app signed with it, verifies the signatures, copies the app to `/Applications/Lidless.app` and launches it.
3. Relay the "Remaining steps" it prints to the person, word for word. **You cannot do those steps for them.** Installing the helper and allowing it in System Settings are macOS security approvals that the person has to make.

Tell the person before step 2 that it installs an app into `/Applications`, and go ahead once they agree.

## When the installer stops

Each exit code means the person has to do something you can't. Explain it and wait.

| Exit | Meaning | What to tell the person |
|---|---|---|
| 2 | macOS older than 14, or full Xcode missing | Install Xcode from the App Store, then run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` and open Xcode once to accept the license. The command needs their password, so they run it themselves. |
| 3 | No Apple code-signing certificate | A free Apple ID is enough. In Xcode: Settings → Accounts → **+** → sign in, then Manage Certificates → **+** → **Apple Development**. Never ask for or handle their Apple ID or password. |
| 4 | The build failed | Show the `error:` lines it printed and look at `build/install-build.log`. |

If the person has more than one certificate and wants a particular one, run `scripts/install.sh --identity "<exact name from security find-identity -v -p codesigning>"`.

## Checking it worked (read-only, safe)

```bash
pgrep -lx Lidless                                                # app running
(cd Core && swift run -c release lidless-smc --read-only)        # fans/temps readable; writes nothing
launchctl print system/dev.lidless.helper 2>/dev/null | grep state   # helper running (after the person approves it)
```

## Rules

- **Don't change system state yourself** unless the person explicitly asks. That means no `pmset` writes, no SMC writes, no `launchctl` load or unload, no `sfltool resetbtm`, and no editing `/Library`. Lid mode and fans are controlled from the app's menu.
- **Don't post or share `lidless-smc --all` output.** It contains hardware serial numbers.
- **Never handle passwords.** Never handle Apple ID credentials, and never put a `sudo` password into a command.
- **Prefer uninstalling through the script.** If something goes wrong, `scripts/install.sh --uninstall` restores sleep and fan settings and removes everything. You can also have the person click **Uninstall Helper** in Settings → Helper.

## Developing

- **Core logic** lives in `Core/`, a Swift package. Run `(cd Core && swift test)` before committing. Every restore and guard path has a test with fakes in `SessionControllerTests.swift`.
- **The Xcode project** `Lidless.xcodeproj` is generated from `project.yml` with XcodeGen. If you change `project.yml`, run `xcodegen generate` and commit both.
- **Signing.** Your Team ID goes in the git-ignored `Config/Local.xcconfig`; `scripts/install.sh` writes it for you. For a Debug build, run `scripts/build-debug.sh`.
- **Debug builds** accept shell commands through `scripts/debug-command.swift` and support simulating thermal and battery conditions. See `docs/TESTING.md`.
- **The helper owns all privileged state**, persists it before every change, and restores it on disconnect, missed heartbeats, SIGTERM, relaunch and reboot. Keep that invariant.
