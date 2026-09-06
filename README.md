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

## Contents

| | |
|---|---|
| [What it does](#what-it-does) | The installer, the daemon, and the companion tools |
| [Requirements](#requirements) · [Installation](#installation) | Getting it running |
| **[Commands](#commands)** | **Every command in the suite, in three tables** |
| [Compatibility](#compatibility) | Whether your machine can do this at all |
| [Configuration](#configuration) | The curve, and the five knobs that shape it |
| [Measuring your fan](#measuring-your-fan) | Finding your real RPM ladder before you tune |
| [Power and charging](#power-and-charging) | `chargewatch`, USB-C PD, and where the watts go |
| [Safety](#safety) · [Logging](#logging) · [Troubleshooting](#troubleshooting) | Operating it |
| [Uninstallation](#uninstallation) · [Changelog](#changelog) | Removing it, and what changed |

## What it does

The installer (`thinkfan-extreme.sh`) sets up everything in one pass:

- Verifies root, then ensures `/etc/modprobe.d/thinkpad_acpi.conf` contains
  `fan_control=1`, backing up the existing file first if it needs changing
- Adds `thinkpad_acpi.fan_control=1` to the kernel command line — through
  `GRUB_CMDLINE_LINUX` + `update-grub` on GRUB systems, or
  `KERNEL_CMDLINE[default]` + `limine-update` on Limine systems. If neither
  bootloader config is present it says so and skips the step rather than failing:
  the `modprobe.d` entry above is the real prerequisite and stands on its own
- Reloads the `thinkpad_acpi` module, or tells you to reboot if it's built into
  the kernel and therefore can't be reloaded
- Installs the `thinkfan-ex` daemon to `/usr/local/bin`
- Creates and starts `thinkfan-extreme.service`
- Installs bash completion to `/etc/bash_completion.d/thinkfan-ex`
- Installs the four companion tools to `/usr/local/bin` as `powerwatch`,
  `thermalsensors`, `fanbench` and `chargewatch`, so they are on `PATH` too.
  (`sensors.sh` becomes `thermalsensors` because plain `sensors` would shadow the
  lm_sensors binary of that name.) They are copies: the daemon never calls them,
  and they still run straight from the clone if you prefer
- Installs `power-unlock.sh` to `/usr/local/sbin/thinkpad-power-unlock`. Placing it
  changes nothing on its own: it does nothing without a config, and its unit is
  only created when you explicitly run
  [`thinkfan-ex -powerunlock`](#raising-the-power-limits)

The daemon (`thinkfan-ex`) then runs continuously: it reads every temperature sensor
it can find, takes the hottest reading, maps it to a fan level through your
configured thresholds, and writes that level to `/proc/acpi/ibm/fan`. Above
`CRITICAL_TEMP` it switches to `disengaged`.

Alongside it the repo carries four standalone tools that change nothing on the
machine: `thermalsensors` and `powerwatch` for reading thermals and power,
`fanbench` for measuring your fan by hand, and `chargewatch` for watching
USB-C PD charge rate. The installer puts them on `PATH`, but none of them need
installing — run them as `./sensors.sh`, `./powerwatch.sh` and so on from the
clone and they behave identically. See [Commands](#commands).

## Requirements

| | |
|---|---|
| Hardware | A ThinkPad exposing `/proc/acpi/ibm/fan` — see [Compatibility](#compatibility) |
| Kernel module | `thinkpad_acpi` loaded with `fan_control=1` (the installer handles this) |
| Privileges | Root, for both the installer and the daemon |
| Init system | systemd |
| Bootloader | GRUB or Limine for the automatic boot-parameter step; anything else is a manual one-liner |
| Optional | `msr-tools`, if you want the throttle diagnostics in [Tuning](#tuning-to-your-machine) |

A reboot is required after installation, since the boot parameter only takes effect
at boot.

## Installation

Two ways in. Cloning tracks `main` and is what the rest of this README assumes;
a [release](https://github.com/VexFlint/Thinkfan-Ex/releases) gives you a pinned,
tagged version instead.

### From a clone

```bash
git clone https://github.com/VexFlint/Thinkfan-Ex.git
cd Thinkfan-Ex
chmod +x *.sh
sudo ./thinkfan-extreme.sh
sudo reboot
```

### From a release

Every release carries a source tarball. Take **Source code (tar.gz)** from the
version you want and the steps are otherwise identical:

```bash
curl -LO https://github.com/VexFlint/Thinkfan-Ex/archive/refs/tags/v1.3.1.tar.gz
tar xf v1.3.1.tar.gz
cd Thinkfan-Ex-1.3.1
chmod +x *.sh
sudo ./thinkfan-extreme.sh
sudo reboot
```

> [!NOTE]
> Releases also attach `thinkfan-extreme.sh` on its own, which is handy for reading
> the installer before you trust it with your fan. Running that file alone installs
> the daemon and nothing else: it copies the companion tools only if they sit beside
> it, so with no tree around it you get `Skipping powerwatch.sh: not found next to
> this installer` four times and a daemon-only install. Use the tarball or the clone
> if you want `powerwatch`, `thermalsensors`, `fanbench` and `chargewatch` on
> `PATH`.

Verify afterwards:

```bash
systemctl status thinkfan-extreme
sudo thinkfan-ex -status
```

`status: enabled` in the fan output means manual control is active. If it says
`disabled`, the boot parameter didn't take — confirm
`thinkpad_acpi.fan_control=1` is in `/proc/cmdline`, and see
[Troubleshooting](#troubleshooting) for where to look per bootloader.

## Commands

Everything in the suite, grouped by what it operates on. The daemon runs by itself
and needs no interaction; these are for when you want to look, measure, or tune.

### The daemon — `thinkfan-ex`

Installed to `/usr/local/bin`, so it's on `PATH` and needs no `./`.

| Command | Effect | Root? |
|---|---|---|
| `thinkfan-ex -help` | Usage summary | no |
| `sudo thinkfan-ex -check` | Capability report and verdict for this machine. Touches nothing | yes |
| `sudo thinkfan-ex -status` | Current fan level, RPM, and *every* sensor on the machine | yes |
| `sudo thinkfan-ex -probe` | Measure real RPM at each level. Stop the service first — see [Measuring your fan](#measuring-your-fan) | yes |
| `sudo thinkfan-ex -config` | Open `/etc/thinkfan-extreme.conf` in `$EDITOR` | yes |
| `sudo thinkfan-ex -powerunlock` | Enable the CPU power/thermal limit unit. Opt-in, applies nothing until configured — see [Raising the power limits](#raising-the-power-limits) | yes |
| `sudo thinkfan-ex -uninstall` | Remove daemon, service, boot parameter, completion | yes |

Service control is ordinary systemd. After editing the config, restart so it
re-reads it:

```bash
sudo systemctl restart thinkfan-extreme     # reload config
sudo systemctl stop thinkfan-extreme        # hand the fan back to firmware
journalctl -u thinkfan-extreme -f           # follow it live
```

### Thermal and power tools

Standalone, read-only, and safe to run at any time. None of them require the
daemon to be installed — the installer copies them to `/usr/local/bin` so they are
on `PATH`, and the same files run from the clone as `./sensors.sh`,
`./powerwatch.sh`, `./fanbench.sh` if you would rather not install anything.

| Command | Effect | Root? |
|---|---|---|
| `thermalsensors` | Every thermal sensor with its hwmon, name, label and reading, in one table | no |
| `sudo powerwatch` | Live package/core/iGPU power, clocks, temperature, throttle reasons. Runs until Ctrl-C | yes |
| `sudo powerwatch 60` | The same, bounded to 60 seconds | yes |
| `sudo fanbench` | Interactive bench: live RPM, change level by keypress | yes |

`sensors.sh` installs under the name `thermalsensors`, not `sensors`: `/usr/local/bin`
comes before `/usr/bin` on `PATH`, so a binary called `sensors` there would shadow
lm_sensors.

`powerwatch` is only meaningful under load — idle numbers say nothing. Run it
alongside `stress -c $(nproc)`.

`fanbench` refuses to start while `thinkfan-extreme` is active, since two things
writing fan levels would fight. Stop the service first, and note its keys:

| Key | Action |  | Key | Action |
|---|---|---|---|---|
| `0`-`7` | set that fan level | | `f` | full-speed |
| `a` | back to `auto` | | `r` | reset the observed table |
| `d` | `disengaged` | | `q` | quit, restoring `auto` |

Tunable through the environment: `SETTLE` (4 polls ignored after a level change).

### Charge monitoring — `chargewatch`

USB-C PD charge-rate monitor for dual-battery ThinkPads. Read-only: no EC writes,
no daemon, nothing to uninstall. See [Power and charging](#power-and-charging) for
what it can and cannot see.

| Command | Effect | Root? |
|---|---|---|
| `chargewatch -help` | Usage and the full explanation of what's measured vs. inferred | no |
| `chargewatch -once` | One reading, then exit | for RAPL |
| `sudo chargewatch` | Watch continuously — the default mode | for RAPL |
| `sudo chargewatch -probe` | Load every core until the adapter saturates, bounding the ceiling empirically. **Heats the machine** | yes |
| `chargewatch -interval 5` | Seconds between samples (default 2) | — |
| `chargewatch -csv out.csv` | Append timestamped samples as CSV | — |

Root is needed for the RAPL energy counters, which is how SoC power enters the
estimate. Without it the battery table still prints, and the adapter estimate is
replaced by a note saying why. `-probe` requires root outright and refuses to run
on battery.

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

Two caveats worth knowing before you tune, both covered in
[Measuring your fan](#measuring-your-fan):

- **`auto` and `full-speed`/`disengaged` are not universal.** The kernel documents
  that not all ThinkPads support them. If yours doesn't, set `CRITICAL_TEMP` above
  any temperature you will realistically reach so the disengaged rung is never used,
  and the ladder still works on levels 0-7 alone.
- **Levels do not map to distinct speeds on every model.** Several older machines
  collapse 3-5 into a single RPM, and some cap the useful maximum below 7.

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

# Consecutive readings that must agree before the level is raised. Stops a brief
# spike from raising the level only for the next poll to lower it again.
UP_CONFIRM=2

# Seconds of silence after which the EC takes fan control back. 0 disables.
WATCHDOG_TIMEOUT=120

# Thresholds. Omitted levels are never used - see "Prune duplicate levels".
declare -A level_threshold
level_threshold[1]=51000
level_threshold[2]=57000
level_threshold[3]=63000
level_threshold[5]=69000
level_threshold[6]=76000
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

Upshifts use neither average nor deadband. They act on the raw reading, so a real
load gets cooling almost immediately. Adding cooling quickly is safe; removing it
slowly is safe; the reverse arrangement would be neither.

**`UP_CONFIRM` guards the one weakness in that asymmetry.** Because a rise is
judged on the raw reading while a fall is judged on the average, a single-sample
spike can raise the level while the average is still low enough to permit an
immediate drop — the fan undoes its own decision one poll later. Requiring two
consecutive readings to agree before raising costs one extra poll of reaction time
and removes the effect: on a recorded idle trace with periodic spikes it cut level
changes from 44 to 2. Set it to 1 for the old immediate behaviour.

If levels still change too often, raise `HYSTERESIS` first — it should exceed your
typical swing, not merely match the gap between thresholds. Raise `SMOOTH_SAMPLES`
only if the readings themselves are noisy; it costs responsiveness when a load ends.

### Prune duplicate levels

A ThinkPad exposes eight fan levels, but most models do not have eight distinct
fan speeds. Adjacent levels frequently map to the same RPM, and giving each of them
its own threshold means the fan changes level without changing sound — churn with no
benefit.

Measured on the reference T480 with `fanbench`:

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

### Which sensors drive the curve

`SENSOR_PATTERNS` decides which sensor files are read. The default is the CPU
package and cores only, and that default matters: the curve uses the **hottest**
reading it finds, so globbing every `hwmon` in the system lets an unrelated device
command a CPU fan.

This is not hypothetical. On the reference T480 the NVMe SSD idles hotter than the
CPU, and while it was included the fan never dropped below level 1 even with the
CPU at 36 °C:

| hwmon | Name | Idle | What it is | In the curve? |
|---|---|---|---|---|
| hwmon9 | `coretemp` | 34-36 °C | CPU package and 4 cores | **yes** — the target |
| hwmon8 | `thinkpad` | 35 / 30 °C | EC sensors, labelled `CPU` and `GPU` | optional, see below |
| hwmon1 | `acpitz` | 35 °C | ACPI zone, mirrors the CPU | no — redundant |
| hwmon4 | `nvme` | **41.8 °C** | SSD, `Sensor 1` runs hottest | no — was hijacking the fan |
| hwmon7 | `pch_skylake` | 32 °C | Chipset | no |
| hwmon10 | `iwlwifi_1` | 30 °C | Wi-Fi | no |
| hwmon0, 2, 3, 5, 6 | `AC` `BAT0` `BAT1` `ucsi_*` | — | Charger, batteries, USB-C | no, no `temp*_input` |

The `thermal_zone*` files are the same silicon through a different interface:
`zone0` is `acpitz`, `zone1` is the PCH, `zone5` is Wi-Fi, `zone6` is
`x86_pkg_temp`. Adding them alongside `coretemp` gains nothing.

List your own with `thermalsensors`, which prints every sensor with its name and
label in one table, or with `thinkfan-ex -status`, which prints every sensor path
and its reading regardless of which ones the curve uses.

**Excluding a device does not leave it unprotected.** An NVMe drive throttles
itself, and a CPU fan barely reaches it anyway. Only widen the patterns for
something that genuinely shares the heatsink:

```bash
# also follow the discrete GPU, via the EC's labelled sensors
SENSOR_PATTERNS="/sys/devices/platform/coretemp.0/hwmon/hwmon*/temp*_input /sys/class/hwmon/hwmon8/temp[12]_input"
```

Note the `temp[12]` — the EC exposes eight sensors and six of them read 0, which
would be harmless here but is worth being deliberate about. `hwmon` numbering is
not stable across boots, so prefer a path under `/sys/devices/platform/` where one
exists.

### Where the fan stops

There is no separate "minimum temperature" setting, and that is deliberate. The fan
returns to firmware control at `level_threshold[<lowest>] - HYSTERESIS`, so the
lowest threshold sets both ends:

```
level_threshold[1]=51000   HYSTERESIS=6000

    fan starts at 51 °C
    fan stops  at 45 °C
```

To change where it stops, move the lowest threshold. Do not add a floor that cuts
straight to `auto` below some temperature: a floor has no deadband, so a
temperature resting on it toggles the fan every poll. Tested on a trace hovering
around 45 °C, a bare floor produced 35 level changes where the deadband produced 1.

## Measuring your fan

Thresholds set against assumed fan speeds are guesses. These two tools tell you
what your machine actually does, and both want the service stopped first so
nothing else is writing levels.

### `-probe` — the automatic sweep

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
Levels that share an RPM want one threshold between them, not several — see
[Prune duplicate levels](#prune-duplicate-levels).

The probe's temperature checks read the same sensors as the curve, so widening
`SENSOR_PATTERNS` widens what its safety limits watch. `-status` deliberately
does not: it lists every sensor on the machine, which is how you find out that
something unexpected is running hot.

The probe refuses to run if the service is active or the CPU is above 65 °C,
aborts early if the CPU passes 80 °C, and restores automatic control on exit or
interrupt. Expect two to four minutes, and it is audible.

### `fanbench` — the interactive bench

For watching RPM live while you change levels by hand:

```bash
sudo systemctl stop thinkfan-extreme
sudo fanbench
```

It shows the current RPM and builds a min/max/last table per level as you sit on
each one. Readings taken while the fan is still changing speed are discarded, as is
the `65535` value the EC returns when its tachometer registers are not being
updated. Keys are listed under [Commands](#commands).

Tunable through the environment if the defaults do not suit your fan:
`POLL` (2 s between reads), `SETTLE_TOL` (60 RPM spread counted as steady),
`SETTLE_HITS` (3 readings), `PROBE_MIN` (6 s), `PROBE_MAX` (45 s), and
`PROBE_MAX_DISENGAGED` (120 s).

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
limited — a more aggressive fan curve will buy you noise and nothing else. That is
where `powerwatch` and `chargewatch` take over.

## Power and charging

`chargewatch` answers a different question from the rest of the suite: not how
hot the machine is, but how much power is reaching it. On a machine that charges
only over USB-C PD, an underpowered adapter looks exactly like a thermal problem
from the outside — clocks drop, and nothing in the fan logs explains it.

### What it can and cannot see

The embedded controller negotiates PD in firmware and does **not** hand the
negotiated contract (the RDO) to the OS. So there are two paths, and the tool
prefers the first:

- **Where UCSI exists** (`USBC000` with `ucsi_acpi` bound, common on newer
  kernels), `/sys/class/typec/` carries the charger's advertised source
  capabilities — the PDO menu it offers. That is not the contract, but it is a hard
  upper bound, and it beats any inference. If the brick advertises 100 W, no
  ceiling you hit is the brick's fault.
- **Without UCSI** the rate is inferred, not read:
  `adapter output ≥ (power into the batteries) + (SoC package power)`. That is a
  floor. Platform overhead RAPL cannot see — panel, SSD, USB, VRM losses — adds
  roughly 5-15 W on top.

Two further details matter on dual-battery machines. **Power Bridge charges one
pack at a time**, so an idle pack next to a charging one is normal EC sequencing,
not a stalled charge — the tool sums every `BAT*` node rather than reading `BAT0`
and reporting 0 W while `BAT1` charges. And some packs populate `power_now` while
leaving `current_now` at zero, so amps are derived as W/V rather than printed as
`34.988 W at 0.000 A`.

### How saturation actually looks

When the adapter runs out of headroom the EC does **not** let the packs discharge
first. It goes through two stages in order:

1. **Charge current tapers to zero** while a pack sits below its resume threshold —
   status reads `Not charging`. This is what a 45 W brick hits.
2. **The packs discharge on AC.** Many adapters never reach this at all.

Both are reported, and `-probe` trips on either. A pack charging at a *trickle*
because the budget is nearly spent still reads `Charging`, so stage 1 does not fire
on it — that shows up as falling charge power instead, and is deliberately not
guessed at.

Measured on a T480 to put numbers on stage 1. The load is `burnboth.sh` — all eight
threads plus the dGPU, 22 W sustained package power — started against a pack already
taking full bulk charge:

| t | charge power | what the EC is doing |
|---|---|---|
| 0.5 s | 33.4 W | full bulk, load just applied |
| 8 s | 30.8 W | |
| 20 s | 27.2 W | |
| 36 s | 12.4 W | shedding hard |
| 52 s | 3.5 W | |
| 68–84 s | **0 W** | `Not charging` — stage 1, fully reached |
| 100 s | 7.0 W | resuming as the CPU settles under PL1 |
| 116 s | 15.0 W | |

The adapter gives up roughly 33 W of charge current to keep the system fed, and does
it as a smooth ramp rather than a cliff. Stage 2 never fired: **zero** samples showed
a pack discharging, across every run. Charging also recovers on its own once the CPU
drops from its PL2 burst to the PL1 steady state, which is why a single reading is
misleading — the same machine under the same load reads 33 W, 0 W, or 15 W depending
purely on when you look.

Re-measured later on the same chassis, the taper reproduces closely (31.9 W at
0.5 s, 3.3 W at 52 s, 0 W at 68-84 s, 14.8 W at 116 s). What the table above does
not show is that the recovery is **not** a one-way settling: charge power climbed
back to ~24 W by t=196 s, then shed to 0 W again at 228 s and 260 s. The EC keeps
cycling between feeding the packs and feeding the load for as long as the load
lasts, so "recovers once the CPU settles" understates it — expect oscillation, not
a single dip.

The practical consequence: on this chassis a stalled charge under load is the EC
budgeting correctly, not a fault. Worry about stage 2.

### Configuring chargewatch

Optional, at `/etc/chargewatch.conf`. Sourced as shell only after `bash -n` passes,
the same guard `thinkfan-ex` uses, so a typo can't wreck your shell.

| Setting | Default | Meaning |
|---|---|---|
| `INTERVAL` | `2` | Seconds between samples |
| `CSV_LOG` | — | Path to append timestamped samples to |
| `PROBE_SECONDS` | `45` | How long `-probe` holds full load |
| `MACHINE_MAX_W` | `65` | Most this chassis will ever negotiate (T480: 20 V / 3.25 A) |
| `PLATFORM_OVERHEAD_LOW` | `5` | Watts invisible to RAPL, low estimate |
| `PLATFORM_OVERHEAD_HIGH` | `15` | Watts invisible to RAPL, high estimate |

`MACHINE_MAX_W` is what separates "the adapter is your ceiling" from "the EC is
your ceiling" in the verdict line, so it's the one worth setting correctly for a
chassis other than a T480.

### Raising the power limits

Lenovo's firmware programs two limits conservatively and reprograms them at every
boot:

- **TCC offset** — how far *below* TjMax the CPU starts throttling. A T480
  i7-8650U ships offset 30: it throttles at 70C on a chip rated to 100C.
- **PL1** — sustained package power. That same chassis ships 15 W against an MSR
  copy already set to 25 W. The hardware enforces `min(MSR, MMIO)`, so only the
  MMIO copy needs raising.

This is **opt-in and off by default**, because raising them makes the machine run
hotter and the right values depend on your chassis and cooler:

```bash
sudo thinkfan-ex -powerunlock
```

That installs `thinkpad-power-unlock.service`, enables it for boot and resume
(resume as insurance — see [Does it stick?](#does-it-stick)), and writes `/etc/thinkpad-power-unlock.conf` with every setting commented out. It
applies nothing until you uncomment one.

| Setting | Meaning |
|---|---|
| `TCC_OFFSET` | Degrees below TjMax at which throttling begins. `0` means throttle at TjMax |
| `PL1_UW` | Sustained package power, in microwatts |

**TjMax is not 100 on every part.** Read yours before choosing an offset:

```bash
cat /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_crit   # millidegrees
```

Measured on a repasted T480 (i7-8650U, TjMax 100): `TCC_OFFSET=4` and
`PL1_UW=22000000` hold two threads at 4.1 GHz and 96C with the fan at
`disengaged`, settling to 87C / 3.5 GHz / 21 W once PL1 takes over. Offset `0`
leaves no room for the 1-2C the per-core reading overshoots the trip point by.

Re-run `sudo thinkfan-ex -powerunlock` after editing the config, or
`sudo systemctl restart thinkpad-power-unlock` — it reports what it applied and
the resulting throttle temperature, and exits non-zero if a write did not stick.

> **The firmware can claw these back under sustained load**, not only at boot. Both
> limits revert together to the firmware defaults — `tcc4/pl1 22W` becomes
> `tcc30/pl1 15W` — and stay reverted until something re-applies them. It is
> intermittent: **once in ten** valid runs at full load on AC, plus once more on
> battery. (An earlier figure of one in five was based on the first five trials;
> five further clean runs halved it. Both numbers rest on a single revert, so
> treat the rate as "occasional", not as measured.) The symptom is a machine that suddenly pins at the *firmware* throttle
> temperature. Check with `systemctl restart thinkpad-power-unlock`, which reprints
> the live values.
>
> No trigger has been found. Ruled out by measurement: adapter saturation (three
> clean runs that each drove charge power to 0 W), temperature (it reverted at
> 74 C and ran clean at 97 C), AC versus battery (seen on both), a userspace
> daemon (`power-profiles-daemon` stays on `performance` and has no platform
> driver on this chassis; no thermald/tlp/tuned), a kernel or ACPI event (the
> journal is silent in every window), iGPU versus dGPU load, and elapsed time
> (it has fired at t=12 s and at t=104 s). Nothing OS-visible distinguishes a
> reverting run from a clean one, which points at the EC or SMM acting below the
> kernel's view.
>
> An earlier note recorded PL1 reverting first with TCC following half a second
> later. The captures since show both moving inside a single 0.5 s sample, so the
> ordering is unresolved at that sampling rate rather than established.

### Correcting it automatically

The claw-back above is intermittent and silent: the machine simply starts
throttling at the firmware's temperature until something re-applies the limits.
Under a game that reads as the frame rate falling off and staying down. The
optional watch unit fixes that:

```bash
sudo systemctl enable --now thinkpad-power-unlock-watch.service
```

It compares both values every `WATCH_INTERVAL` seconds (default 0.5) and rewrites
only the one that drifted, so it costs two file reads per tick and touches nothing
in the normal case. Measured recovery on a T480: a register poked to the firmware
default was back **within 500 ms**.

Every correction is logged, which matters more than it sounds:

```
$ journalctl -t thinkpad-power-unlock-watch
REVERT: TCC offset was 30 (wanted 4), rewrote -> 4
REVERT: MMIO PL1 was 15000000 (wanted 22000000), rewrote -> 22000000
```

> **The watchdog hides the evidence it is built on.** Without it a claw-back is a
> durable state you can observe for the rest of the run; with it the revert
> becomes a sub-second blip. `burnboth.sh` will therefore stop reporting
> `LIMITS CHANGED` almost entirely while the watch is running, and the journal
> above becomes the only record. Stop the watch for any run where catching the
> revert is the point.

The unit is written by `-powerunlock` but **not enabled** — the oneshot covers
boot and resume, and a resident root process should be a choice. `-uninstall`
removes it.

### Does it stick?

Three ways the limits could be lost, and what each actually does on a T480
(i7-8650U, TjMax 100, kernel 7.2.2):

| | Result | How it was checked |
|---|---|---|
| **Reboot** | Holds | Unit runs at boot; `TCC 4 / PL1 22 W` live in sysfs afterwards |
| **Sustained load** | Usually | Clean in nine of ten valid 300 s runs on AC; the other reverted at t=12 s. See the claw-back note above |
| **Suspend / resume** | Depends on load | Idle: config moved aside so the unit no-ops, 75 s S3, both limits came back untouched. Under load: suspended mid-run, came back at firmware defaults — the unit restored them 0.5 s later |

The load run is also the positive control that the limits are doing something:
package power sits at **21.9 W sustained** against the 22 W PL1, and the throttle
reason flips from `PL1` to `thermal` exactly as the package reaches **96 C** —
the TCC offset 4 trip point, engaging where predicted.

The resume result depends on what the machine was doing. `thinkpad-power-unlock.service`
is `WantedBy=suspend.target`, so it re-runs on every wake — the unit's
`InvocationID` changes, which is how you tell a genuine re-run from a value that
was simply never disturbed. Suspend an **idle** machine with the unit deliberately
disabled and the firmware leaves both limits alone. Suspend one **under load** and
they come back at the firmware defaults; the unit then restores them within half a
second, which is visible in `burnboth.sh` as a `LIMITS CHANGED` pair 0.5 s apart
straddling the sleep. So the hook does nothing on an idle resume and real work on
a loaded one.

> If you re-test this yourself, suspend with **`systemctl suspend`**, not
> `rtcwake -m mem`. `rtcwake` writes straight to `/sys/power/state`, which never
> activates `suspend.target` — so the unit cannot run and the test silently proves
> nothing. On a machine with the NVIDIA driver it also aborts the suspend outright
> (`nv_pmops_suspend ... returns -5`), because `nvidia-suspend.service` never got
> to run either. Arm the wake separately with `rtcwake -m no -s 75`.

### Testing it

`test-chargewatch.sh` fakes the entire sysfs surface — batteries, RAPL, typec PDOs
— in a temp directory, through four roots the script honours
(`CHARGEWATCH_PS_ROOT`, `CHARGEWATCH_RAPL_ROOT`, `CHARGEWATCH_TYPEC_ROOT`,
`CHARGEWATCH_CONF`):

```bash
./test-chargewatch.sh ./chargewatch.sh     # 24 assertions
```

No sudo, no hardware, no CPU load. Every state worth checking — Power Bridge
sequencing, real starvation, the hysteresis band, discharge-on-AC, 100 W vs 45 W
chargers, missing UCSI, the capped ETA — is one command rather than an afternoon
with a charger. `-probe` is deliberately not covered, since it pegs every core;
test that one by hand.

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
`thinkpad_acpi.fan_control=1` is in `/proc/cmdline`. If it isn't, check whichever
bootloader config applies — `/etc/default/grub` then `update-grub` on GRUB,
`/etc/default/limine` then `limine-update` on Limine — and reboot. The
`fan_control=1` line in `/etc/modprobe.d/thinkpad_acpi.conf` covers most setups on
its own, so also check that it survived.

**Service restarts in a loop.** Check `journalctl -u thinkfan-extreme -b`. The usual
cause is a config file that passes its syntax check but sets nonsense values.

**Fan won't leave `disengaged`.** Some sensor is reading above `CRITICAL_TEMP`.
Run `sudo thinkfan-ex -status` and look for an outlier — it's often a non-CPU zone.

**Levels change every few seconds.** `HYSTERESIS` is smaller than your temperature
swing. Raise it, or widen the gaps between thresholds.

**Clocks are low but the fan is quiet and temperatures are fine.** You are probably
power limited rather than thermally limited. Check MSR bit 10 with
[`powerwatch`](#tuning-to-your-machine), and if the machine runs on USB-C PD,
check what the adapter is actually delivering with
[`chargewatch`](#power-and-charging).

## Uninstallation

```bash
sudo thinkfan-ex -uninstall
echo "level auto" | sudo tee /proc/acpi/ibm/fan
```

This stops and disables the service, removes the daemon, its bash completion and the
four companion tools from `/usr/local/bin`, and reverts the boot parameter from
whichever bootloader received it. It also stops and removes
`thinkpad-power-unlock.service` and its helper, so the CPU limits go back to the
firmware's own values at the next boot. Your clone is untouched, so the tools remain
available there as `./powerwatch.sh` and friends. The second command
is not optional: `-uninstall` exits before the restore trap is installed, so the fan
stays at whatever level was last written. See [Safety](#safety).

The config file and logs are left in place; remove them yourself if you want a clean
slate:

```bash
sudo rm -f /etc/thinkfan-extreme.conf /var/log/thinkfan-extreme*.log
sudo rm -f /etc/thinkpad-power-unlock.conf
```

## Changelog

### 1.3.1

Documentation only. The daemon and installer behave exactly as in 1.3.

**Added**

- Installation now documents installing from a [release](https://github.com/VexFlint/Thinkfan-Ex/releases)
  as well as from a clone, including the tarball URL and the directory name
  GitHub produces. It also warns that the standalone `thinkfan-extreme.sh`
  asset installs the daemon alone: it copies the companion tools only if they
  sit beside it, so a single-file download leaves nothing else on `PATH`.

**Fixed**

- The clone URL and `chargewatch.sh`'s header comment pointed at
  `BrunoGrande/Thinkfan-Ex`, which resolves only through GitHub's rename
  redirect. Both now point at `VexFlint/Thinkfan-Ex` directly.

### 1.3

**Added**

- The installer now copies the companion tools to `/usr/local/bin`, so
  `powerwatch`, `thermalsensors`, `fanbench` and `chargewatch` are on `PATH`
  like the daemon instead of only running as `./name.sh` from the clone.
  `sensors.sh` installs as `thermalsensors`, since a `sensors` in
  `/usr/local/bin` would shadow lm_sensors. `thinkfan-ex -uninstall` removes
  all four.

### 1.2.1

**Fixed**

- Entering and leaving `disengaged` had no deadband, so a temperature resting on
  `CRITICAL_TEMP` toggled it every few seconds. It now uses the same `HYSTERESIS`
  as every other level.

**Changed**

- Default thresholds re-spaced so the fan starts at 51 °C and stops at 45 °C,
  keeping a full `HYSTERESIS` deadband at the bottom of the ladder.

**Added**

- `SENSOR_PATTERNS`, honoured by both the control loop and `-probe`. The curve was driven by the hottest reading across every
  hwmon in the system, so an unrelated device - wifi, NVMe, PCH - could command
  a CPU fan. The default is now the CPU package and cores only.

### 1.2

Validated on a repasted ThinkPad T480 (i7-8650U). Across a seven-minute run
covering idle, a three-minute all-core load and the full cooldown, the daemon made
eight level changes, all of them real thermal events, with no reversals. The
previous release flapped eight times at idle alone.

**Changed**

- Default thresholds rebuilt from measured fan speeds rather than assumed ones.
  Levels 0, 4 and 7 are no longer used: 4 and 7 were measured as duplicates of 3
  and 6, and 0 stops the fan entirely. `CRITICAL_TEMP` lowered to 88000 and
  `HYSTERESIS` to 6000 to suit the wider bands that pruning produces.

**Added**

- `fanbench.sh`, an interactive bench for reading real fan speeds: live RPM,
  level switching by keypress, and a min/max/last table per level.
- `UP_CONFIRM`, requiring consecutive readings to agree before the level is
  raised. A single-sample spike previously raised the level while the smoothed
  temperature still permitted an immediate drop, so the fan reversed itself on the
  next poll. On a recorded idle trace this cut level changes from 44 to 2.

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
