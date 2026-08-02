# Thinkfan-Extreme

Aggressive, fully configurable fan control for ThinkPad laptops — including the
`disengaged` mode that bypasses the embedded controller's RPM ceiling and runs the
fan flat out.

ThinkPad firmware is conservative by design. It will happily let a CPU sit at 95 °C
and throttle rather than spin the fan harder, because Lenovo tuned the curve for
acoustics on a machine that has to be sold in an office. If you've repasted, if you
run sustained loads, or if you simply care more about clocks than about silence,
you want your own curve. This gives you one.

---

> [!WARNING]
> This project takes fan control away from your firmware. If the daemon dies without
> restoring automatic mode, the fan stays wherever it was last set — possibly at a
> low level, on a hot CPU, with nothing supervising it. Read
> [Safety](#safety) before running this on a machine you care about.

---

## What it does

The installer (`thinkfan-extreme.sh`) sets up everything in one pass:

- Verifies root, then ensures `/etc/modprobe.d/thinkpad_acpi.conf` contains
  `fan_control=1`, backing up the existing file first if it needs changing
- Appends `thinkpad_acpi.fan_control=1` to `GRUB_CMDLINE_LINUX` and runs `update-grub`
- Reloads the `thinkpad_acpi` module, or tells you to reboot if it's built into
  the kernel and therefore can't be reloaded
- Installs the `thinkfan-ex` daemon to `/usr/local/bin`
- Creates and starts `thinkfan-extreme.service`
- Installs bash completion to `/etc/bash_completion.d/thinkfan-ex`

The daemon (`thinkfan-ex`) then runs continuously: it reads every temperature sensor
it can find, takes the hottest reading, maps it to a fan level through your
configured thresholds, and writes that level to `/proc/acpi/ibm/fan`. Above
`CRITICAL_TEMP` it switches to `disengaged`.

## Requirements

| | |
|---|---|
| Hardware | A ThinkPad, i.e. anything driven by `thinkpad_acpi` |
| Kernel module | `thinkpad_acpi` loaded with `fan_control=1` (the installer handles this) |
| Privileges | Root, for both the installer and the daemon |
| Init system | systemd |
| Optional | `msr-tools`, if you want the throttle diagnostics in [Tuning](#tuning-to-your-machine) |

A reboot is required after installation, since the boot parameter only takes effect
at boot.

## Installation

```bash
git clone https://github.com/BrunoGrande/Thinkfan-Ex.git
cd Thinkfan-Ex
chmod +x thinkfan-extreme.sh
sudo ./thinkfan-extreme.sh
sudo reboot
```

Verify afterwards:

```bash
systemctl status thinkfan-extreme
sudo thinkfan-ex -status
```

`status: enabled` in the fan output means manual control is active. If it says
`disabled`, the boot parameter didn't take — check that `update-grub` actually
modified `/etc/default/grub` and that you rebooted.

## Usage

The daemon starts at boot and needs no interaction. When you do want to poke at it:

| Command | Effect |
|---|---|
| `sudo thinkfan-ex -status` | Current fan level, RPM, and every sensor reading |
| `sudo thinkfan-ex -config` | Open `/etc/thinkfan-extreme.conf` in `$EDITOR` |
| `sudo thinkfan-ex -uninstall` | Remove the daemon, service, GRUB change, and completion |
| `thinkfan-ex -help` | Usage summary |

After editing the config, restart the service so it re-reads it:

```bash
sudo systemctl restart thinkfan-extreme
```

## Configuration

Lives in `/etc/thinkfan-extreme.conf`, created with defaults on first run. It's
sourced as shell, so it's syntax-checked before use — if it fails the check, the
daemon falls back to built-in defaults rather than dying.

Every temperature is in **millidegrees Celsius**: `70000` is 70 °C.

```bash
# Critical temperature. Above this the fan goes to "level disengaged",
# which bypasses the EC's RPM ceiling and runs the fan flat out.
# Set this as a genuine emergency rung, not a normal operating point:
# compare it against your CPU's TjMax (usually 100C), not against idle temps.
CRITICAL_TEMP=90000

# Downshift deadband, in millidegrees. See "Hysteresis" below.
HYSTERESIS=8000

# Readings averaged when deciding to step down. Upshifts ignore this.
SMOOTH_SAMPLES=5

# Seconds of silence after which the embedded controller takes fan control back.
# This is what protects you if the daemon is killed outright. Range 1-120,
# or 0 to disable. Leave it on unless you have a reason not to.
WATCHDOG_TIMEOUT=120

# Temperature thresholds for each fan level.
declare -A level_threshold
level_threshold[0]=45000
level_threshold[1]=50000
level_threshold[2]=55000
level_threshold[3]=60000
level_threshold[4]=65000
level_threshold[5]=70000
level_threshold[6]=78000
level_threshold[7]=85000
```

Levels may be omitted. The ladder is built from whichever keys you define, so
dropping `level_threshold[4]` simply means level 4 is never used.

Below the lowest threshold the daemon writes `level auto`, handing control back to
firmware for genuinely idle temperatures.

### Hysteresis

A bare threshold is a single line: crossed going up, crossed going down, at the same
temperature. CPU temperature jitters by several degrees between reads, so any wobble
sitting on a threshold makes the fan change level every polling interval. The result
is audible pulsing and needless wear:

```
19:34:50  disengaged -> level 5
19:34:53  5 -> level 3
19:34:57  3 -> level 5
19:35:00  5 -> level 3
```

Two mechanisms prevent that, and they pull in opposite directions on purpose.

**`HYSTERESIS` is a deadband around the level currently held.** The fan stays where
it is until the temperature falls that far *below* the threshold that put it there.
At level 5 with a threshold of `70000` and `HYSTERESIS=8000`, the fan won't step down
until 62 °C. Downshifts then move one level at a time rather than jumping.

Note this is a deadband around the *current* level, not an offset applied to every
level beneath it. Offsetting the whole ladder shifts all the bands down while leaving
them exactly as narrow as before, which does almost nothing — a mistake worth
avoiding if you reimplement this.

**`SMOOTH_SAMPLES` averages the readings used to decide a downshift.** With the
default 5 and a 3-second poll, roughly 15 seconds of history has to agree before the
fan winds down.

Upshifts use neither. They act on the latest raw reading and are never delayed, so a
sudden load gets cooling on the very next poll. Adding cooling quickly is safe;
removing it slowly is safe; the reverse arrangement would be neither.

If levels still change too often, raise `HYSTERESIS` first — it should exceed your
typical swing, not merely match the gap between thresholds. Raise `SMOOTH_SAMPLES`
only if the readings themselves are noisy; it costs responsiveness when a load ends.

### Tuning to your machine

The shipped defaults suit a repasted ThinkPad with TjMax 100 °C. They are a starting
point, not a universal curve. To calibrate against your own hardware:

```bash
{ for z in /sys/class/thermal/thermal_zone*/; do echo "$z $(cat $z/type) $(cat $z/temp)"; done
  cat /proc/acpi/ibm/fan
  grep MHz /proc/cpuinfo
  sudo rdmsr 0x1b1; } 2>&1 | tee ~/thermal-snapshot.txt
```

Run it once at idle, then again after several minutes at full load
(`stress -c $(nproc)`) so the heatsink has saturated. Spread your thresholds across
the range between those two figures, and put `CRITICAL_TEMP` well above the
sustained load temperature — it should be reachable only when something has gone
wrong.

Printing `$z/type` alongside the temperature matters, because the daemon takes the
maximum across all sensors. A zone like `pch_skylake` or `iwlwifi_1` running hot has
nothing to do with your CPU, but it will still drive the fan curve.

MSR `0x1b1` (`IA32_PACKAGE_THERM_STATUS`) tells you what's actually limiting the
machine:

| Bit | Meaning |
|---|---|
| 0 | Currently thermally throttling |
| 2 | PROCHOT# asserted |
| 10 | Currently power limited |
| 16–22 | Degrees below TjMax |

If bit 10 is set and bit 0 is clear, you're power limited rather than thermally
limited — a more aggressive fan curve will buy you noise and nothing else.

## Safety

`thinkfan-ex` gives up manual control in two independent ways, because one of them
is not enough.

**The `EXIT` trap** restores `level auto` on normal shutdown and on
`systemctl stop`. It does not run on `SIGKILL`, which includes the OOM killer, and
`-uninstall` exits before the trap is ever installed.

**The EC watchdog** covers that gap. It is armed automatically at startup from
`WATCHDOG_TIMEOUT` (default 120 seconds). If the daemon stops writing to
`/proc/acpi/ibm/fan` for that long, firmware resumes automatic control on its own —
no software involvement required, so it survives a killed process.

The daemon skips redundant writes to keep the log readable, but refreshes the
current level every `WATCHDOG_TIMEOUT / 3` seconds regardless, so a steady
temperature still registers as a live daemon. If you disable the watchdog by setting
`WATCHDOG_TIMEOUT=0`, that refresh stops too.

After `-uninstall`, restore automatic control by hand:

```bash
echo "level auto" | sudo tee /proc/acpi/ibm/fan
```

## Logging

Deployment is logged to `/var/log/thinkfan-extreme-fix.log`; the daemon logs to
`/var/log/thinkfan-extreme.log`, truncated on each service start. Only real level
changes are recorded, not one line per poll.

```bash
tail -f /var/log/thinkfan-extreme.log
journalctl -u thinkfan-extreme -f
```

## Troubleshooting

**`status: disabled` in the fan output.** The boot parameter isn't active. Confirm
`thinkpad_acpi.fan_control=1` is in `/proc/cmdline`; if it isn't, check
`/etc/default/grub` and rerun `update-grub`, then reboot.

**Service restarts in a loop.** Check `journalctl -u thinkfan-extreme -b`. The usual
cause is a config file that passes its syntax check but sets nonsense values.

**Fan won't leave `disengaged`.** Some sensor is reading above `CRITICAL_TEMP`.
Run `sudo thinkfan-ex -status` and look for an outlier — it's often a non-CPU zone.

**Levels change every few seconds.** `HYSTERESIS` is smaller than your temperature
swing. Raise it, or widen the gaps between thresholds.

## Uninstallation

```bash
sudo thinkfan-ex -uninstall
echo "level auto" | sudo tee /proc/acpi/ibm/fan
```

This stops and disables the service, removes the daemon and bash completion, and
reverts the GRUB parameter. The second command is not optional: `-uninstall` exits
before the restore trap is installed, so the fan stays at whatever level was last
written. See [Safety](#safety).

The config file and logs are left in place; remove them yourself if you want a clean
slate:

```bash
sudo rm -f /etc/thinkfan-extreme.conf /var/log/thinkfan-extreme*.log
```

## Changelog

### 1.1

**Fixed**

- An empty sensor read aborted the control loop under `set -e`. Some `hwmon` nodes
  return nothing while `cat` still exits 0, so the `|| echo 0` fallback never fired
  and the resulting empty value broke the numeric comparison.
- Reading `/sys/module/thinkpad_acpi/parameters/fan_control` aborted the installer
  when `thinkpad_acpi` is built into the kernel rather than loaded as a module.
- The default fan command was `auto`, which `/proc/acpi/ibm/fan` rejects. The valid
  command is `level auto`.
- A `grep` miss while reading the current level aborted the loop under `set -e`.
- `local error_code=$?` always captured 0, because `local` resets `$?`.
- `systemctl enable --now` would not restart an already-running service, so
  reinstalling over a live install left the old daemon running the old code. The
  installer now restarts explicitly.
- The fallback configuration used when the config file fails its syntax check no
  longer diverges from the shipped defaults.

**Added**

- `HYSTERESIS` as a deadband around the level currently held, plus `SMOOTH_SAMPLES`
  to average the readings behind a downshift. Upshifts still act on the latest raw
  reading. On 20 minutes of recorded idle jitter this cut level changes from 24 to 8.
- `WATCHDOG_TIMEOUT`, armed automatically at startup, so firmware reclaims the fan
  if the daemon is killed without running its cleanup trap. The skip-redundant-writes
  optimisation refreshes the current level periodically so it cannot starve the
  watchdog while the daemon is healthy.
- The log now records which configuration source was used, plus the resolved
  `HYSTERESIS` and `WATCHDOG_TIMEOUT` values.

**Changed**

- Redundant writes are skipped, so the log records real level changes instead of one
  entry per poll.
- Level sorting uses `mapfile` with `printf | sort` instead of an `IFS`-prefixed
  array assignment.
- Default thresholds retuned for a machine with healthy thermals.

### 1.0

Initial release.

## License

MIT. See [LICENSE](LICENSE).

## Author

Bruno Bellizzi Grande

*Last updated: August 1, 2026*
