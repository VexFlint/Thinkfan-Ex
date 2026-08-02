# Thinkfan-Extreme

Aggressive, fully configurable fan control for ThinkPad laptops — including the
`disengaged` mode that bypasses the embedded controller's RPM ceiling and runs the
fan flat out. Works on any machine whose `thinkpad_acpi` exposes
`/proc/acpi/ibm/fan`; see [Compatibility](#compatibility) for a one-command check.

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

## Compatibility

The requirement is not "is it a ThinkPad" but three specific things:

1. `thinkpad_acpi` loads on the machine
2. it exposes `/proc/acpi/ibm/fan`
3. that interface accepts the `level` command

Rather than trust a list, ask the machine. This is authoritative, takes a second,
and changes nothing:

```bash
sudo thinkfan-ex -check
```

It reports the driver, the fan interface, whether manual control is enabled, which
of `level` / `auto` / `disengaged` / `full-speed` the firmware accepts, whether the
EC watchdog exists, and how many temperature sensors are readable — then gives a
verdict and exits non-zero if anything is wrong. It never changes the fan state.

Before installing, the same thing by hand:

```bash
[ -e /proc/acpi/ibm/fan ] && cat /proc/acpi/ibm/fan || echo "no fan interface"
```

Read the `commands:` lines. If they list `level <level> (<level> is 0-7, auto,
disengaged, full-speed)`, everything this project needs is present. The driver
rejects unsupported operations with `EINVAL`, so a level it cannot set fails loudly
rather than silently doing nothing.

Two caveats worth knowing before you tune:

- **`auto` and `full-speed`/`disengaged` are not universal.** The kernel documents
  that not all ThinkPads support them. If yours doesn't, set `CRITICAL_TEMP` above
  any temperature you will realistically reach so the disengaged rung is never used,
  and the ladder still works on levels 0-7 alone.
- **Levels do not map to distinct speeds on every model.** Several older machines
  collapse 3-5 into a single RPM, and some cap the useful maximum below 7. Measure
  yours:

  ```bash
  sudo systemctl stop thinkfan-extreme
  sudo thinkfan-ex -probe
  ```

  This steps through every level and prints the real RPM alongside the CPU
  temperature. Rather than waiting a fixed time at each level, it polls the
  tachometer and moves on only once the readings stop changing — a fan has real
  inertia, and spinning down from 4000 RPM to a stop takes far longer than nudging
  one level upward. Steadiness is measured as the spread across a window of recent
  readings, so a slow ramp is not mistaken for a settled one; `disengaged` in
  particular is open-loop and can take well over a minute to reach full speed.

  A figure marked `*` never went steady inside the time limit and is approximate.
  Levels that share an RPM want one threshold between them, not several.

  The probe refuses to run if the service is active or the CPU is above 65 °C,
  aborts early if the CPU passes 80 °C, and restores automatic control on exit or
  interrupt. Expect two to four minutes, and it is audible.

  For interactive work — watching RPM live while you change levels by hand — use
  `fanbench.sh` instead:

  ```bash
  sudo systemctl stop thinkfan-extreme
  sudo ./fanbench.sh
  ```

  Press `0`-`7`, `a` for auto, `d` for disengaged, `f` for full-speed. It shows the
  current RPM and builds a min/max/last table per level as you sit on each one.
  Readings taken while the fan is still changing speed are discarded, as is the
  `65535` value the EC returns when its tachometer registers are not being updated.
  `q` restores automatic control.

  Tunable through the environment if the defaults do not suit your fan:
  `POLL` (2 s between reads), `SETTLE_TOL` (60 RPM spread counted as steady),
  `SETTLE_HITS` (3 readings), `PROBE_MIN` (6 s), `PROBE_MAX` (45 s), and
  `PROBE_MAX_DISENGAGED` (120 s).

### Known working

Confirmed on modern hardware: **T480** (developed and tested here). ThinkWiki
records the A31, R50-R61, T22-T61, T400/T410, T42/T43, W500/W510, X30-X61, X120e,
X201i, X220, and Z60/Z61 families, with per-model RPM tables. That list has not been
updated since 2020, so the absence of a recent model means nothing — most T, X, P,
and L series machines from the last decade work.

Older machines that use a different register but are still handled through
`/proc/acpi/ibm/fan`: 240, 570, 600, and 770 families.

### Known not working

These regulate the fan through a method `thinkpad_acpi` does not drive:

| Models | Reason |
|---|---|
| 390, 390E, 390X | Different method and register |
| 800, 820-823, 850, 851, 860 | Different method and register |
| SL300, SL400/c, SL500/c | Different method and register |
| R30, R31, R32, R40, R40e | Different method and register |
| 560, 560X | No fan at all |

**Non-ThinkPads will not work.** IdeaPad, Legion, ThinkBook, and every other vendor's
hardware lack `thinkpad_acpi` entirely, so there is no `/proc/acpi/ibm/fan` to write
to. The installer will report the missing interface rather than doing damage, but
there is nothing here for those machines.

## Requirements

| | |
|---|---|
| Hardware | A ThinkPad exposing `/proc/acpi/ibm/fan` — see [Compatibility](#compatibility) |
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
| `sudo ./fanbench.sh` | Interactive bench: live RPM, switch levels by keypress |
| `sudo thinkfan-ex -check` | Capability report and verdict for this machine |
| `sudo thinkfan-ex -probe` | Measure real RPM at each level (stop the service first) |
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
# Above this the fan goes to "disengaged", leaving the EC's closed-loop control
# and spinning as fast as it physically can. An emergency rung, not a setting.
CRITICAL_TEMP=88000

# Downshift deadband. See "Hysteresis" below.
HYSTERESIS=6000

# Readings averaged when deciding to step down. Upshifts ignore this.
SMOOTH_SAMPLES=5

# Seconds of silence after which the EC takes fan control back. 0 disables.
WATCHDOG_TIMEOUT=120

# Thresholds. Omitted levels are never used - see "Prune duplicate levels".
declare -A level_threshold
level_threshold[1]=45000
level_threshold[2]=52000
level_threshold[3]=58000
level_threshold[5]=65000
level_threshold[6]=72000
```

Levels may be omitted. The ladder is built from whichever keys you define, so
dropping `level_threshold[4]` simply means level 4 is never used. That is not a
curiosity — it is how the config is meant to be written. See
[Prune duplicate levels](#prune-duplicate-levels).

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

### Prune duplicate levels

A ThinkPad exposes eight fan levels, but most models do not have eight distinct
fan speeds. Adjacent levels frequently map to the same RPM, and giving each of them
its own threshold means the fan changes level without changing sound — churn with no
benefit.

Measured on the reference T480 with `fanbench.sh`:

| Level | RPM | Verdict |
|---|---|---|
| 0 | 0 | Fan off. Never wanted while the machine is working. |
| 1 | ~2500 | keep |
| 2 | ~2700 | keep |
| 3 | ~2950 | keep |
| 4 | ~2985 | **drop** — indistinguishable from 3 |
| 5 | ~3390 | keep |
| 6 | ~3780 | keep |
| 7 | ~3780 | **drop** — indistinguishable from 6 |
| `disengaged` | ~4700 | the only way past the EC's RPM ceiling |

Nine nominal rungs, six useful ones. The shipped defaults therefore define levels
1, 2, 3, 5 and 6 only, and reserve `disengaged` for `CRITICAL_TEMP`.

Note also that `full-speed` measured 4680-4746 against `disengaged` at 4672-4754 —
the same thing, as the kernel documents. `full-speed` is an alias; the driver reports
it back as `disengaged`.

Fewer, wider bands also let `HYSTERESIS` do its job: a deadband only damps flapping
if it is larger than the gap between neighbouring thresholds.

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

### 1.2

**Changed**

- Default thresholds rebuilt from measured fan speeds rather than assumed ones.
  Levels 0, 4 and 7 are no longer used: 4 and 7 were measured as duplicates of 3
  and 6, and 0 stops the fan entirely. `CRITICAL_TEMP` lowered to 88000 and
  `HYSTERESIS` to 6000 to suit the wider bands that pruning produces.

**Added**

- `fanbench.sh`, an interactive bench for reading real fan speeds: live RPM,
  level switching by keypress, and a min/max/last table per level.

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
- `-check`, reporting whether this machine supports fan control and which fan
  commands its firmware accepts, without touching the fan.
- `-probe`, measuring real RPM at every level so thresholds can be set against
  measured behaviour instead of assumed behaviour. It waits for the tachometer to
  go steady rather than using a fixed dwell, and judges steadiness by the spread
  across a window of readings so a slowly ramping fan is not reported as settled.

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
