# Testing checklist

These steps change system state (`disablesleep`, fans), but only through the Lidless helper. Before you start, record the baseline:

```bash
pmset -g | grep -i SleepDisabled || echo "SleepDisabled 0 (absent)"
(cd Core && swift run -c release lidless-smc --read-only) | grep -E "F0md|F0Tg|F0Ac"
```

Useful while testing:

```bash
log stream --predicate 'subsystem == "dev.lidless.helper"' --level info   # helper decisions
sudo launchctl print system/dev.lidless.helper | head -30                 # daemon state
sudo cat "/Library/Application Support/Lidless/state.json"                # present only while active
```

## 0. Fan writes, before anything else

1. Install the helper and choose **Max**.
2. `lidless-smc` should show `F0md 1` and `F0Tg 6550`. `F0Ac` should ramp up within a few seconds.
3. Choose **Auto**. You should see `F0md 0`, and `F0Ac` falls back.

If the mode write is rejected on this M5, the helper logs `SMC rejected 'F0md' (result 0x82)`. Check `log stream` and report it before going further.

## 1. Lid closed, no display, on AC

1. Turn on lid mode and choose **While claude is running**.
2. Start a long Claude Code task, then close the lid.
3. From another machine, check that the Mac is still awake and reachable:
   ```bash
   ssh <mac> 'pmset -g | grep SleepDisabled; pmset -g assertions | head; uptime'
   ```
4. After 10 minutes, check that Claude Code is still responding.

## 2. `kill -9` the app restores within 5 s

```bash
kill -9 $(pgrep -x Lidless); sleep 5
pmset -g | grep SleepDisabled      # expect: absent / 0 (your original)
(cd Core && swift run -c release lidless-smc) | grep F0md   # expect 0
```

Also kill the helper itself with `sudo kill -9 $(pgrep -x LidlessHelper)`. launchd relaunches it, it restores from `state.json`, and the app shows a "Lidless recovered" notification.

## 3. Reboot mid-session

1. Turn on lid mode and set fans to Max.
2. Run `sudo reboot`.
3. After login, `pmset -g` should be back to your original `SleepDisabled` value and `state.json` should be gone. The helper runs at boot (`RunAtLoad`).

## 4. Thermal critical (Debug builds only)

```bash
echo '{"thermal":"critical"}' | sudo tee "/Library/Application Support/Lidless/simulate.json"
# within ~1 s: lid mode off, fans auto, notification; if the lid is closed the Mac sleeps
sudo rm "/Library/Application Support/Lidless/simulate.json"
```

To test the notification only, use `{"thermal":"serious"}`. Lid mode should stay on.

## 5. Battery below threshold (Debug builds only)

1. Leave Settings → Safety → "Only allow on AC power" off (the default).
2. Turn on lid mode.
3. Run:
   ```bash
   echo '{"onAC":false,"batteryPercent":15}' | sudo tee "/Library/Application Support/Lidless/simulate.json"
   ```
   Lid mode should turn off.
4. With "Only allow on AC power" turned on, `{"onAC":false}` alone also turns lid mode off.

## 6. MacBook Air (no fans)

`lidless-smc` prints `FNum = 0`, the fan section is hidden, and `setFanMode` is refused by the helper. The unit test `testFanlessMacHasNoFanControl` covers this.

## Automated

`(cd Core && swift test)` runs 34 tests. Every restore path above runs against fakes: disconnect, heartbeat loss, boot restore, thermal, battery, AC-only, max session, until, process grace, display-off on lid close, fan rollback, sleep, and wake.
