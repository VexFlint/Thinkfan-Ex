# Thinkfan-Ex v1.2

Fan control rebuilt around measured hardware behaviour rather than assumed
behaviour, plus two new tools for measuring your own machine.

## Highlights

**Defaults derived from measurement.** Fan speeds were benched on a repasted
ThinkPad T480 and the level ladder pruned to the speeds that actually differ.
Levels 4 and 7 measured identical to 3 and 6, and level 0 stops the fan entirely,
so all three are now unused. `CRITICAL_TEMP` is 88000 and `HYSTERESIS` 6000 to suit
the wider bands that pruning produces.

**`thinkfan-ex -check`** reports whether a machine supports fan control at all:
driver, fan interface, manual control state, which of `level` / `auto` /
`disengaged` / `full-speed` the firmware accepts, watchdog availability and sensor
count. Never touches the fan.

**`thinkfan-ex -probe`** measures real RPM at every level, waiting for the
tachometer to go steady rather than using a fixed dwell.

**`fanbench.sh`** is an interactive bench: live RPM, change level by keypress, and a
min/max/last table per level as you work through them.

**EC watchdog armed automatically.** If the daemon is killed without running its
cleanup trap, firmware reclaims the fan after `WATCHDOG_TIMEOUT` seconds.

## Fixed

- An empty sensor read aborted the control loop under `set -e`. Some `hwmon` nodes
  return nothing while `cat` still exits 0, so the `|| echo 0` fallback never fired.
- Reading `/sys/module/thinkpad_acpi/parameters/fan_control` aborted the installer
  when `thinkpad_acpi` is built into the kernel rather than loaded as a module.
- The default fan command was `auto`, which `/proc/acpi/ibm/fan` rejects. The valid
  command is `level auto`.
- A `grep` miss while reading the current level aborted the loop under `set -e`.
- `local error_code=$?` always captured 0, because `local` resets `$?`.
- `systemctl enable --now` will not restart an already-running service, so
  reinstalling over a live install left the old daemon running the old code.
- Hysteresis was applied as an offset to every level below the current one, which
  shifts the whole ladder down while leaving the bands exactly as narrow as before.
  It is now a deadband around the level actually held.
- A single-sample temperature spike raised the level while the smoothed temperature
  still permitted an immediate drop, so the fan reversed itself one poll later.
  `UP_CONFIRM` requires consecutive readings to agree before raising.
- The configuration used when the config file fails its syntax check no longer
  diverges from the shipped defaults.

## Added

- `HYSTERESIS`, `SMOOTH_SAMPLES`, `UP_CONFIRM`, `WATCHDOG_TIMEOUT`
- `-check`, `-probe`, `fanbench.sh`
- Startup logging of the configuration source and every resolved value

## Upgrading

The installer does not overwrite an existing configuration, so a v1.1 config will
survive and silently keep the old curve. To take the new defaults:

```bash
sudo thinkfan-ex -uninstall
echo "level auto" | sudo tee /proc/acpi/ibm/fan
sudo rm -f /etc/thinkfan-extreme.conf
chmod +x thinkfan-extreme.sh
sudo ./thinkfan-extreme.sh
```

## Note on the defaults

These thresholds were measured on one machine with healthy thermals. A laptop with
degraded paste will sit at the top of this curve constantly. Run `-check`, then
`fanbench.sh`, and set your thresholds against what your own fan does.
