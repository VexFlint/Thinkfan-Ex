# Firmware and hardware control surfaces

A map of every low-level entry point this machine exposes, what each one
controls, whether it is locked, and what it costs to get it wrong.

The point is to be able to tinker later without rediscovering the landscape each
time. Regenerate the raw data with:

```bash
sudo ./fwmap.sh              # read-only; writes to /var/log/fwmap-<date>
diff -r /var/log/fwmap-old /var/log/fwmap-new
```

`fwmap.sh` has no write path in it, deliberately. Everything below marked
**write** is documented, not exercised — see [Before you write anything](#before-you-write-anything).

## The machine this was mapped on

Any of these changing invalidates a comparison against an older dump, which is
why `fwmap.sh` stamps them at the top of every report.

| | |
|---|---|
| Model | ThinkPad T480 `20L6SE7N00` |
| BIOS | `N24ET79W` 1.54, 2025-03-17 |
| EC firmware | `N24HT37W` |
| CPU | i7-8650U (Kaby Lake R), TjMax 100 C, TDP 15 W |
| Microcode | `0xf6` |
| Kernel | 7.2.2 (CachyOS), UEFI boot |

## Surface map

| Surface | Controls | Access | Locked? | Risk |
|---|---|---|---|---|
| `MSR 0x610` PKG_POWER_LIMIT | PL1/PL2 package power | `/dev/cpu/*/msr` | **No** (`lock=0`) | Low — resets at boot |
| `MSR 0x1A2` TEMPERATURE_TARGET | TjMax, TCC offset (bits 24-29) | `/dev/cpu/*/msr` | No | Medium — thermal |
| RAPL MMIO PL1 | Sustained power, the copy that wins | `powercap` sysfs | No | Low |
| `tcc_offset_degree_celsius` | Throttle point below TjMax | sysfs | No | Medium — thermal |
| `MSR 0x1AD` TURBO_RATIO_LIMIT | Per-core-count turbo multipliers | `/dev/cpu/*/msr` | No | Medium |
| `MSR 0x150` OC mailbox | Core/cache voltage offsets | `/dev/cpu/*/msr` | No — write path tested open | **High** — instability, silent corruption |
| `MSR 0x1FC` POWER_CTL | C1E, energy-efficient turbo | `/dev/cpu/*/msr` | No | Low |
| DPTF `INT3400` | Thermal policy, `odvp*` state | platform sysfs | policy `INVALID` | Low to read |
| DPTF `data_vault` | OEM thermal policy blob (2263 B) | sysfs, read-only | n/a | Read-only |
| ACPI `DYTC` | Lenovo Intelligent Cooling modes | AML, via EC HKEY | n/a | **High** — invokes firmware |
| EC RAM | Fan, battery, thermal, charge | `ec_sys` debugfs | read-only as loaded | **Very high** on write |
| `thinkpad_acpi` | Fan, LEDs, hotkeys, thermal | `/proc/acpi/ibm/*` | no | Low to medium |
| ACPI `_Qxx` (48 handlers) | EC event hooks | AML only | n/a | Read-only here |
| ACPI-WMI (18 devices) | Lenovo config interfaces | `/sys/bus/wmi` | n/a | Read-only here |
| **think-lmi** | 79 BIOS setup settings | `firmware-attributes` | `LockBIOSSetting=Disable` | Read safe, **write = BIOS change** |
| EFI variables (158, 21 Lenovo) | BIOS setup backing store | `efivarfs` | some RO | **Very high** on write |
| SPI flash | BIOS/EC image | needs `flashrom` | n/a | **Bricking** |
| `MSR 0x774` HWP_REQUEST / EPP | The frequency the governor actually picks | `cpufreq` sysfs | No | Low — and the largest measured lever here |

That last row is not firmware, and it is in this table anyway: it outweighed
every firmware knob below it on battery, and a map that stops at the firmware
boundary is how it stayed hidden for four commits.

## Power and thermal — the part already in use

`power-unlock.sh` uses two of these. The rest are unexploited.

```
MSR_PKG_POWER_LIMIT  0x004280e800dd80c8
   PL1 25.00 W  enabled=1  clamp=1  LOCK=0
   PL2 29.00 W  enabled=1
MSR_PKG_POWER_INFO   TDP (thermal spec) 15.00 W
MSR_TEMPERATURE_TARGET  TjMax 100 C, TCC offset 4 C
```

Three facts worth carrying forward:

- **`lock=0`.** The power-limit MSR is not locked on this firmware, so PL1/PL2
  can be written directly. The repo currently only writes the MMIO copy, because
  hardware enforces `min(MSR, MMIO)` and the MSR copy already sits at 25 W. If
  you ever want above 25 W sustained you must raise both.
- **TDP thermal spec is 15 W**, and that is where `max_power_uw = 15000000`
  comes from — and it is exactly the value a claw-back reverts PL1 to.
- **`PLATFORM_INFO` says programmable TDP = 1, programmable ratio = 1,
  programmable TjMax = 1.** All three knobs physically exist on this part.

Turbo is `0x27272a2a`: **42x** (4.2 GHz) for 1-2 cores, **39x** for 3-4.
`TURBO_ACTIVATION_RATIO` is `0x12` (18x).

`MSR 0x150` — the overclocking mailbox — reads `0x000185dd` and is unlocked.
This is the undervolt interface (what `intel-undervolt` drives). Untouched here.

## DPTF (`INT3400`) — Intel's dynamic thermal manager

```
current_uuid:    INVALID        <- no policy active in the kernel
production_mode: 1
data_vault:      2263 bytes     <- the OEM policy blob
odvp0 = 7, odvp1..19 = 0
```

`PPCC` (`ssdt10.dsl:1030`) advertises the power-limit envelope DPTF may use.
The default `NPCC` package carries PL1 window 28-32 s, step 1 W, and PL2
`0xDBBA` = **56.25 W**. It is rewritten at runtime by `CPL0`/`CPL1`/`CPL2`
depending on `\_PR.CBMI` (cTDP boot index) and `\_PR.CLVL` (how many cTDP levels
exist), which live in an SSDT field region rather than as constants.

> `odvp*` are firmware-set policy variables, and **the power-unlock watchdog does
> not correct them**. That makes them the one piece of state that survives a
> claw-back as evidence. Log all twenty alongside a `burnboth` run — with
> `thinkpad-power-unlock-watch` **stopped**, or the watchdog repairs the limits
> in 0.5 s and there is nothing left to correlate against.

## The OEM thermal policy, decoded

`data_vault` is not opaque. It is an LZMA-alone stream after a `REPO` marker,
2263 bytes unpacking to 55 KB of "DPTF Policy Configuration": one row of power
limits per named configuration. `fwmap.sh` decodes it to `dptf_policy.txt`.

Values are milliwatts; `TccOffset` is degrees below TjMax. Suffixes: `_DC` on
battery, `_IA` Intel-adaptive, `_VGA` discrete GPU present.

| config | PL1 | PL1MAX | PL1MIN | PL2 | PL4 | TccOffset |
|---|---|---|---|---|---|---|
| `MMC_PERFORMANCE` | 25000 | 25000 | 5000 | 29000 | 71000 | - |
| `MMC_PERFORMANCE_DC` | 15000 | 15000 | 5000 | 25000 | 51000 | - |
| `MMC_COOL` | 12000 | 12000 | 3000 | 29000 | 71000 | - |
| `STD_U42` | 25000 | 25000 | 13000 | 29000 | 71000 | - |
| `STD_U42_DC` | 15000 | 15000 | 13000 | 25000 | 51000 | - |
| `PSC_7` | 25000 | 25000 | 13000 | 25000 | 71000 | - |
| `PSC_8_DC` | 15000 | 15000 | 13000 | 25000 | 71000 | - |
| `IFC` | 25000 | **4500** | 4500 | 29000 | 71000 | **50** |
| `STP` | - | **2000** | 2000 | 29000 | 71000 | **45** |

~~**It explains the battery result.**~~ **It does not — corrected 2026-09-06.**
Every `_DC` row here does cap PL1 at 12-15 W, and sustained package power on
battery did measure 13.2-13.9 W against 21.9 W on AC with MMIO PL1 reading 22 W
throughout, which made this table look like the answer. It was a coincidence of
numbers. Nothing was applying these rows: the `INT3400` zone is `disabled` at
boot and stays that way. The battery result was
[EPP](#the-battery-clamp-was-epp-not-firmware), and raising MMIO PL1 buys
21.9 W on battery once the hint is out of the way.

The table is still what DPTF *would* apply if something enabled it, which is why
it stays here. It is a policy the machine carries, not a policy the machine was
running.

`MMC_PERFORMANCE` (25 W) and `MMC_COOL` (12 W) are the two Intelligent Cooling
states DYTC switches between. `PSC_*` correspond to power-slider positions.

## DPTF writes these registers — demonstrated

The DPTF path can be driven on demand, and it reproduces the claw-back's PL1
value exactly. The `INT3400` thermal zone starts `disabled`; enabling it makes
the kernel run `_OSC`, which firmware answers by calling `DYTC(0x000F0001)`.
Disabling it runs `DYTC(0x01FF)`.

**A single enable moves only the TCC offset.** Within 2 ms of the first enable,
TCC goes 4 to 3. PL1 is untouched — verified over 45 s idle and over a full 300 s
`burnboth` run, which held 22 W, 21.7 W sustained, 97 C peak, no `LIMITS CHANGED`.

**A second enable cycle clamps PL1 to 15 W.** Disable an already-enabled zone and
re-enable it, and about 2 s later MMIO PL1 becomes `15000000` — and stays. Three
independent runs, identical each time:

```
trial 1   baseline TCC=4 PL1=22000000   after enable: TCC=3 PL1=22000000
trial 2   [+2242ms] TCC/PL1 = 3/15000000
          baseline TCC=3 PL1=15000000   after enable: TCC=3 PL1=15000000
trial 3   baseline TCC=3 PL1=15000000   after enable: TCC=3 PL1=15000000
```

The `power-unlock` oneshot ran at the top of trial 2 and **succeeded** — exit 0,
`ok MMIO PL1 (uW) = 22000000` — and the firmware overrode it roughly two seconds
later. So this is not a failed write; it is the firmware winning a write it did
not make first.

Disabling the zone and re-applying restores 22 W. Nothing survives a reboot.

Reproduce it (this **overrides your power limits while enabled**):

```bash
sudo systemctl stop thinkpad-power-unlock-watch     # or it fights the firmware
Z=/sys/class/thermal/thermal_zone1
echo enabled  > $Z/mode      # first cycle: TCC 4 -> 3 only
echo disabled > $Z/mode
echo enabled  > $Z/mode      # second cycle: PL1 -> 15000000
echo disabled > $Z/mode      # release
sudo systemctl start thinkpad-power-unlock
```

> **Still not proof that the wild claw-back is this path.** The PL1 value matches
> exactly and the mechanism demonstrably overrides a successful write, but the
> forced case lands TCC at 3 where the observed claw-back lands it at 30, and
> nothing in userspace enables this zone during a normal session. It is a
> mechanism that produces the same symptom, not a confirmed cause.

## The claw-back caught in the wild

The watchdog caught a spontaneous revert on an unattended resume. This is the
first capture with both registers logged at the moment it happened:

```
01:07:03.047  PM: suspend entry (deep)
01:14:04.735  REVERT: TCC offset was 30 (wanted 4), rewrote -> 4
01:14:04.774  REVERT: MMIO PL1 was 15000000 (wanted 22000000), rewrote -> 22000000
01:14:04.977  PM: suspend exit
01:14:05.267  thinkpad-power-unlock: ok TCC offset = 4
```

`TCC 30` **and** `PL1 15000000` together — the firmware's true defaults, and the
exact signature seen during load runs.

**This rules the DPTF path out as the cause.** Forcing DPTF lands TCC at **3**;
this lands it at **30**. Different values, different paths. DPTF demonstrably
writes these registers, but it is not what reverts them in normal use. The wild
claw-back is firmware re-initialisation, and resume is one confirmed trigger.

**The discriminator looks like AC vs battery, not idle vs load.** Three suspends
so far:

| suspend | power | load | reverted |
|---|---|---|---|
| controlled test | AC | idle | no |
| drain batch | battery | loaded | yes |
| unattended | battery | idle | **yes** |

That reads as "on battery it reverts", not "under load it reverts", which is what
this file and the README previously said. Untested as a controlled pair; the
experiment is one suspend on AC and one on battery with the watchdog stopped.

**Battery is not the discriminator either (2026-09-06).** Four 8-thread load runs
on one boot, all on battery: three held their limits with zero drift — two of
them witnessed at 1 Hz across 142 samples — and one reverted. Battery was
constant across all four, so it cannot be what separates them.

That one run is the cleanest capture of the claw-back so far, because it landed
inside the sampler's own stream instead of in a separate log:

```
  t   pkgW  maxMHz  cpuC  cpu-limit
  5.5  32.2   3314    81  PL2
  6.0  26.5   2900    81  thermal
  >>> LIMITS CHANGED at t=6.0s: tcc4/pl1 22W -> tcc30/pl1 15W
  6.5  22.3   2900    70  thermal
```

Both registers moved inside one 0.5 s sample, 6 s into a run that had pulled
32 W and 81 C from a cold start with the fan still ramping through 2100 RPM. The
temperature then pins at 70 C — TjMax − 30, the firmware default — which is the
throttle point doing exactly what the reverted offset says.

A later run on the same boot reached **84 C at the same 33 W peak and did not
revert**. So a temperature threshold and a peak-power threshold are both ruled
out as sufficient triggers. What is left: the excursion happened while the fan
was still spinning up from cold, which the non-reverting runs did not do. That is
a hypothesis with one supporting run, not a finding.

## The battery clamp was EPP, not firmware

**Corrected 2026-09-06.** This section used to be headed "the battery clamp sets
no limit-reason bit" and concluded that a DC budget was being enforced by a path
invisible to Intel's own limit reporting. The observation was right and the cause
was wrong. The clamp is `energy_performance_preference`, which
`power-profiles-daemon` programs to `balance_power` on battery in its `balanced`
profile. It sets no bit in `CORE_PERF_LIMIT_REASONS` because it is not a limit —
it is a hint to the hardware governor, and hints are not reported.

Four 8-thread runs, one boot, all on battery, with TCC offset 4 and MMIO PL1 22 W
verified per sample throughout:

| EPP | limits held by | sustained pkg | all-core | `nothing` | `PL1` | `PL2` | `thermal` |
|---|---|---|---|---|---|---|---|
| `balance_power` | boot unlock | 14.5 W | 2382 MHz | 90 | 0 | 0 | 0 |
| `balance_power` | watch unit | 14.5 W | 2390 MHz | 90 | 0 | 0 | 0 |
| `performance` | nothing — clawed back at t=6 s | 14.7 W | 2400-2900 MHz | 0 | 25 | 11 | 39 |
| `performance` | watch unit | **21.9 W** | **2931 MHz** | 0 | 73 | 17 | 0 |

The last row is the AC figure — 21.7 W — reached on battery, for 120 s, at 31.7 W
out of the pack. So no DC budget exists below that. What happens above it is
untested: PL1 22 W was the binding limit in that run, reported by 73 of 90
samples.

The single measurement that proves it was a frequency hint and not a power
budget: **two threads, 9.0 W package, still pinned at 2400 MHz.** Power sat a
third under the ceiling and the frequency did not move.

`MSR 0x774` HWP_REQUEST on battery reads `0xc0002a04` — min 4, **max 42**, so
4.2 GHz is not capped anywhere; only the EPP byte (`0xc0`) is conservative.
`max_perf_pct` is 100, `no_turbo` is 0, `scaling_max_freq` is 4200000. Nothing
declares a 2.4 GHz ceiling. It is what the governor picks under that hint.

Two consequences worth keeping in view. Every power measurement in this file
taken before this date has an unrecorded EPP, so any AC-vs-battery comparison
among them is confounded by whatever `power-profiles-daemon` was doing at the
time. And the biggest single lever found on this machine so far was not in the
firmware at all — it was one sysfs string, one layer above everything else here.

## What turbostat adds (installed 2026-09-06)

`extra/turbostat`, 266 KiB, one package. It should have been the first thing
installed on this machine and it was the last. Everything in this file up to here
was inferred from RAPL energy deltas and one limit-reason register; turbostat
reads the platform's own decode and the per-core residencies directly.

Its startup dump alone settles several things that were open or assumed:

```
MSR_HWP_CAPABILITIES: 0x0108132a (high 42 guar 19 eff 8 low 1)
MSR_HWP_REQUEST:      0xc0002a04 (min 4 max 42 des 0 epp 0xc0 window 0x0 pkg 0x0)
MSR_MISC_PWR_MGMT:    0x00401cc0 (ENable-EIST_Coordination DISable-EPB DISable-OOB)
EPB: 8 (custom)
MSR_IA32_POWER_CTL:   0x0024005d (C1E auto-promotion: DISabled)
MSR_PKG_POWER_INFO:   0x00000078 (15 W TDP, RAPL 0 - 0 W)
MSR_PKG_POWER_LIMIT:  0x4280e800dd80c8 (UNlocked)
  PKG Limit #1: ENabled (25.000 W, 28.000000 sec, clamp ENabled)
  PKG Limit #2: ENabled (29.000 W, 0.002441 sec, clamp DISabled)
  PKG Limit #4: 71.000000 W (locked)
MSR_IA32_TEMPERATURE_TARGET: 0x04640000 (96 C) (100 default - 4 offset)
turbo ratios: 42 / 42 / 39 / 39 for 1 / 2 / 3 / 4 active cores
```

- **PL1's window is 28 s**, and its clamp bit is enabled. Neither was known here.
  A 28 s averaging window is longer than several of the load runs in this file
  spent at peak, which matters for how their first samples read.
- **PL4 is 71 W and locked** — the only power limit on this part that is.
- **EPB is disabled in `MSR_MISC_PWR_MGMT`**, so the legacy energy-perf-bias knob
  (`EPB: 8`) is inert and HWP's EPP byte is the live one. Anything that tries to
  tune this machine through `x86_energy_perf_policy` is writing to a register the
  hardware is ignoring.
- **All-core turbo is 3.9 GHz**, so the 2.93 GHz measured at `performance` is
  power-limited, not ratio-limited, and the 2.39 GHz at `balance_power` is
  neither — it is the hint.
- **C1E auto-promotion is already disabled**, which is one of the two things
  `MSR 0x1FC` was listed above as a candidate for changing.
- CPUID reports base 2100 MHz while `MSR_CONFIG_TDP_NOMINAL` reports base ratio
  19 and sysfs reports 1900000. Most likely two definitions rather than a
  contradiction — `CONFIG_TDP_NOMINAL` is the guaranteed ratio at the configured
  TDP level, and `HWP_CAPABILITIES` guar 19 agrees with it, while CPUID 0x16
  reports the marketing base. Unverified against the datasheet. Either way, do
  not treat "base clock" as a single number on this part.

Same two EPP arms as above, re-run under turbostat, 90 s of `stress -c 8` each,
on battery with TCC 4 / PL1 22 W held:

| | `balance_power` | `performance` |
|---|---|---|
| `Bzy_MHz` | 2394 | 3003 |
| `PkgWatt` | 14.91 | 23.91 |
| `CorWatt` | 13.07 | 22.01 |
| **`UncMHz`** | **2100** | **2600** |
| `PkgTmp` | 66 | 83 |
| `SysWatt` | 22.19 | 32.62 |
| `IPC` | 1.19 | 1.19 |
| `CoreThr` | 0 | 0 |
| `SMI` | 0 | 0 |

**`UncMHz` is new information.** The hint moves the uncore/ring clock as well as
the cores, 2100 → 2600 MHz. No instrument used in this file before could see
that, and it is part of why `balance_power` costs more than the core ratio alone
suggests — IPC is identical at 1.19, so the work per clock did not change; the
clocks did, both of them.

**`SMI` = 0 across both runs** is the useful baseline for the claw-back hunt. If
the mechanism is SMM — the standing hypothesis, since nothing OS-visible
distinguishes a reverting run — then a run that reverts should show a non-zero
SMI count where these show none. That is a direct test, and it did not exist
before this tool was on the machine.

**One turbostat column is broken on this part.** `PKG_%` — the RAPL package
throttle-time accumulator from `MSR_PKG_PERF_STATUS` — read `0.00` in all 100
one-second intervals of a run whose `CORE_PERF_LIMIT_REASONS` reported PL1 in
most samples, at 22.6 W against a 22 W limit. Two different registers, and only
`0x64f` works here. Do not swap the instrument.

### The cold-fan hypothesis did not survive

The one hypothesis left standing for the claw-back was that the reverting run's
excursion happened while the fan was still ramping from cold. Tested directly:
fan at level 1 and 2468 RPM, package 44 C, EPP `performance`, watch unit off,
limits at TCC 4 / PL1 22 W, 90 s of 8-thread load, witnessed at 1 Hz and sampled
by turbostat at 1 Hz alongside.

It reached 34 W peak and 85 C — hotter and harder than the run that reverted —
and **did not revert**. 108 of 108 witness samples flat at `tcc=4 pl1=22000000`,
zero SMIs, zero NMIs, `CoreThr` 0 throughout.

So the count is now one revert in five comparable battery runs, with battery
state, temperature, peak power and fan state each individually ruled out as the
trigger. The honest position is that short runs are the wrong instrument for an
event this rare, not that the trigger is exotic.

## DYTC — Lenovo Intelligent Cooling

The most interesting thing found so far, and the leading claw-back suspect.

`DYTC` is a method on the EC's `HKEY` device (`dsdt.dsl:30452`) taking a packed
command word: bits 12-15 `ICFunc`, 16-19 `ICMode`, 20 `ValidF`.

It is **called by the DPTF `_OSC` handler** (`ssdt10.dsl:550`): when an OS
declares DPTF support, firmware runs `DYTC(0x000F0001)`; when support is
withdrawn, `DYTC(0x01FF)`. Other call sites pass `0x001F4001` and `0x000F4001`.

Inside, DYTC sets the ODM variables — `\ODV0 = \STDV`, `\ODV1 = \VCQL`,
`\ODV2 = \VTIO` — gated on `\_SB.IETM.DPTE`, the DPTF-enabled flag.

This matters because it is a firmware path, reachable from ordinary OS activity,
that reprograms thermal policy without the kernel logging anything. It is
consistent with everything observed about the claw-back: no kernel event, no
userspace daemon, both limits moving together to platform defaults.

**Not yet established.** `thinkpad_acpi` did not register a `platform_profile`
on this machine, so DYTC is not currently reachable from userspace — no
`/sys/firmware/acpi/platform_profile` exists. Whether the firmware invokes it
on its own during load is exactly the open question.

## BIOS settings via think-lmi

The `think-lmi` driver binds WMI GUID `51F5230E-9677-46CD-A1CF-C0B23EE34DB7` and
exposes **79 BIOS setup settings** as a supported kernel interface — far better
than poking the EFI variables that back them.

```bash
sudo cat /sys/class/firmware-attributes/thinklmi/attributes/<name>/current_value
sudo cat /sys/class/firmware-attributes/thinklmi/attributes/<name>/possible_values
```

The four that bear on this repo:

| setting | value | options |
|---|---|---|
| `AdaptiveThermalManagementAC` | `MaximizePerformance` | `MaximizePerformance;Balanced` |
| `AdaptiveThermalManagementBattery` | `Balanced` → **`MaximizePerformance`** | `MaximizePerformance;Balanced` |
| `CPUPowerManagement` | `Automatic` | `Disable;Automatic` |
| `SpeedStep` | `Enable` | `Disable;Enable` |

### The write, and what it bought (2026-09-06)

`AdaptiveThermalManagementBattery` was written to `MaximizePerformance` through
this interface with the owner's permission. It behaved as documented: the value
**persisted across a reboot**, and it was visible in BIOS setup afterwards, under
Config → Power → Adaptive Thermal Management → Scheme for Battery. So the
`firmware-attributes` write path is real and does reach the setup menu.

It changed **nothing measurable**. The battery load run after the reboot gave
14.5 W sustained at 2382 MHz with 90 of 90 samples reporting no limit reason —
the same clamp, within noise of the 13.8 W recorded before the write. The
hypothesis that it was the BIOS-level selector behind the battery ceiling is
dead; see [The battery clamp was EPP](#the-battery-clamp-was-epp-not-firmware).

### The SpeedStep submode is not exposed here

The same BIOS page carries a second tree — Config → Power → Intel (R) SpeedStep
technology — with its own **Mode for AC** and **Mode for Battery**, values
`Maximum Performance` / `Battery Optimized`. On this machine the battery mode
shipped as the optimized one, and it was set to `Maximum Performance` by hand in
setup, along with the AC mode, on the same reboot as the write above.

**think-lmi does not expose it.** All 79 attributes were dumped: there is a
`SpeedStep` (`Enable`/`Disable`) and nothing else matching, no AC/Battery
submode, so this knob is reachable only from the setup menu. That is a real limit
on the claim that `firmware-attributes` beats poking EFI variables — it beats it
for the 79 settings it carries, and there is at least one it does not carry.
Candidate backing variables, unread: `CpuSetup-b08f97ff-…`,
`SetupCpuFeatures-ec87d643-…`.

Because both changes landed on the same reboot, neither is individually isolated.
They do not need to be: the measured result is a null for the pair.

`LockBIOSSetting = Disable`, so settings are not locked. Writes through this
interface normally require the BIOS supervisor password via the driver's
authentication node when one is set.

## The OC (undervolt) mailbox

`MSR 0x150` is the voltage-offset mailbox — the interface `intel-undervolt`
drives. Reading an offset requires writing a *query* word to the mailbox
(`0x80000010 | plane << 40`) and reading the result back; the query sets nothing.

All five planes currently read **0.00 mV** — no undervolt applied:

| plane | domain | offset |
|---|---|---|
| 0 | CPU core | +0.00 mV |
| 1 | iGPU | +0.00 mV |
| 2 | CPU cache | +0.00 mV |
| 3 | System agent | +0.00 mV |
| 4 | Analog I/O | +0.00 mV |

### The write path is open (tested 2026-09-06)

It is **not** locked. Microcode `0xf6` carries the Plundervolt mitigation
(CVE-2019-11157), which closes this interface on many Kaby Lake-R systems, and it
does not close it here.

Tested with the smallest offset worth writing, on the core plane only:

```
plane 0 (CPU core): +0.00 -> wrote -15.0 -> reads -14.65 mV
```

−14.65 is −15 quantised: the mailbox stores in 1/1.024 mV steps, so −15 mV
encodes as −15 units and reads back as −15 / 1.024. That round trip is the
result — the register accepted a write and returned it.

30 s of 8-thread load at that offset ran clean: 2376 MHz, 14.16 W, 58 C, no
machine checks, `CoreThr` 0. **The offset was set back to 0 immediately
afterwards**; nothing on this machine is undervolted.

> **What this does not prove.** The readback shows the mailbox stored the value,
> not that the voltage regulator applied it. −15 mV is around 1 % of core
> voltage — far inside run-to-run noise, so no power or frequency measurement
> here can confirm it landed. Demonstrating the *effect* needs a larger offset
> and a fixed-frequency comparison (in the PL1-limited regime it shows up as more
> MHz at the same watts, not as fewer watts). That is a separate experiment, and
> a real undervolt is the one place in this file where a wrong value corrupts
> data silently rather than announcing itself.

### −50 mV, and proof that the regulator applies it

The −15 mV test above proved the register accepted a write. −50 mV proves the
voltage regulator acts on it.

First attempt, and why it failed: four alternating 90 s runs of `stress -c 8` on
AC in the PL1-limited regime, 0 / −50 / 0 / −50. Package power fell monotonically
across all four — 24.87, 23.67, 23.42, 22.08 W — regardless of voltage, because
the chassis was soaking heat the whole time. Each −50 arm was ~1.2 W under the
0 arm before it, but the drift between two 0 arms was 1.45 W. **The effect and
the confound were the same size.** A power-limited comparison cannot answer this:
the governor is free to trade the saved watts for clock, and the clock was
falling too.

Second attempt, at a pinned frequency where PL1 is far away and nothing can move
but voltage. All cores capped at 2.0 GHz, 8 threads, six 40 s arms alternating,
one continuous load so the machine never cools between them:

| arm | `Bzy_MHz` | `CorWatt` | `PkgWatt` | `PkgTmp` |
|---|---|---|---|---|
| 0 mV | 2000 | 9.09 | 10.88 | 56 |
| −50 mV | 2000 | **8.65** | 10.44 | 56 |
| 0 mV | 2000 | 8.99 | 10.78 | 57 |
| −50 mV | 2000 | **8.60** | 10.38 | 55 |
| 0 mV | 2000 | 8.95 | 10.74 | 56 |
| −50 mV | 2000 | **8.65** | 10.44 | 55 |

Identical clock, identical IPC (1.19 in all six), temperatures within 2 C, and
**every undervolted arm below every baseline arm with no overlap**: 9.01 W mean
against 8.63 W, −4.2 % core power. The offset is real and the regulator applies
it.

Stability at −50 mV: 749 SHA-256 passes over a 128 MB buffer across 8 parallel
workers, **zero mismatches**, no machine checks, `CoreThr` 0. A wrong answer is
the failure mode that matters with an undervolt — a hang announces itself, silent
corruption does not — so the check is for wrong answers, not for uptime.

The offset was set back to 0 afterwards. Nothing is undervolted, and nothing here
persists across a reboot anyway.

> **Do not read −4.2 % as the payoff.** This was measured at 2.0 GHz, where the
> part already runs near its voltage floor. The regime an undervolt is actually
> for is the power-limited one, where the saved watts come back as clock — and
> that is exactly the measurement the thermal drift above ruined. Quantifying it
> needs the alternating protocol with a fixed thermal starting point per arm.

The protocol, so it does not have to be re-derived — write the command word to
`MSR 0x150`, then read the same MSR back:

| | command word |
|---|---|
| read plane *p* | `0x8000001000000000 \| (p << 40)` |
| write plane *p* | `0x8000001100000000 \| (p << 40) \| packed` |

`packed = ((int)round(mv * 1.024) << 21) & 0xffffffff`, and unpacking is the
inverse: sign-extend the low 32 bits, arithmetic-shift right 21, divide by 1.024.
Planes are core, iGPU, cache, system agent, analog I/O, in that order. On this
part the core and cache planes are commonly moved together.

## Embedded controller

256 bytes via `ec_sys`, loaded read-only. Offset `0xF0` carries the EC firmware
string (`N24HT37W`). `thinkpad_acpi` exposes the civilised subset at
`/proc/acpi/ibm/` — `fan`, `thermal`, `led`, `hotkey`, `cmos`, `lcdshadow`.

48 `_Qxx` EC query handlers exist. Only `_Q26` and `_Q27` touch anything
power-related, and only `PWRS` (the AC-present flag) — these are the AC
plug/unplug hooks. **No `_Qxx` handler writes power limits**, which rules out
the EC event path as the claw-back mechanism.

## Not mapped

Not "everything is mapped now". What follows is the standing list of what is
still dark, and what it would take to light up.

**Missing tools.** Absent on this system: `flashrom`, `ectool`, `nvramtool`,
`msr-tools`, `powertop`. So SPI flash imaging and the EC command interface are
unexplored — not because they are uninteresting, but because nothing here can
reach them yet. The MSR path works regardless via `/dev/cpu/*/msr`.
`turbostat` was on this list and is now installed; see
[What turbostat adds](#what-turbostat-adds-installed-2026-09-06).

**Module options not taken.** These change what the kernel will let anyone touch:

| module / option | opens | why it is not set |
|---|---|---|
| `ec_sys.write_support=1` | writing EC RAM directly | **Very high risk.** The EC owns charging, fans and thermal cutoffs, and a bad byte is not undone by a reboot. Read-only is a deliberate choice, not an oversight |
| `acpi_call` | invoking arbitrary AML, incl. `DYTC` | Not installed. This is the only route to DYTC while `platform_profile` is absent, and it runs firmware code with arguments nobody has validated |
| `thinkpad_acpi.experimental=1` | extra `/proc/acpi/ibm` nodes on some models | Untested here; may expose nothing on a T480 |
| `msr` write path | `0x1AD` turbo ratios, `0x1FC` C1E/EE-turbo, `0x150` undervolt | Loaded and readable. The writes are documented above and unexercised |
| `intel_pstate=passive` | hands frequency to `cpufreq` governors | Would replace the HWP hint mechanism that turned out to matter most. Worth trying, but it changes the thing being measured |

**Interfaces that exist and were only read.** `MSR 0x1AD` (per-core-count turbo
multipliers) and `MSR 0x1FC` (C1E, energy-efficient turbo) are both unlocked and
both untouched. `MSR 0x150` reads zeros on all five planes and may or may not
accept a write — microcode `0xf6` carries the Plundervolt mitigation.

**Not reachable from here at all.** `platform_profile` never registered, so DYTC
has no sysfs entry point; the 158 EFI variables include settings think-lmi does
not carry, and writing them is in the bricking tier; SMM is invisible by
construction, and it remains the most likely home of the claw-back.

18 ACPI-WMI devices are listed by GUID only; their methods are unenumerated.
158 EFI variables are listed by name only, 21 of them Lenovo/Setup namespaces
(`CpuSetup`, `LenovoHiddenSetting`, `LenovoConfig`, `LenovoFunctionConfig`).

## Before you write anything

Read-only enumeration is safe and is all `fwmap.sh` does. The write tier is not
uniformly risky, and the difference is worth keeping straight:

- **Reversible at reboot** — RAPL limits, TCC offset, turbo ratios. These reset
  from firmware every boot. Worst case is a hard power cycle.
- **Reversible but destabilising** — OC mailbox voltage offsets. A bad undervolt
  hangs the machine or corrupts data silently under load. Test with the machine
  idle and nothing important open.
- **Not reliably reversible** — EC RAM writes (`ec_sys write_support=1`). Some
  ThinkPad EC offsets do not come back without a full power drain, battery
  disconnect included, and a few not at all. EFI variable writes can leave the
  firmware unable to boot.
- **Bricking** — SPI flash. Needs external recovery hardware when it goes wrong.

The ordering that keeps a mistake cheap: read, document, change one thing,
observe, reboot to confirm it resets, and only then automate it.

## Open questions

1. **Does the claw-back move the MSR copy too, or only MMIO?** Unresolved — the
   probe designed to answer it ran five clean runs and never caught a revert.
   If MSR survives while MMIO drops, whatever does this writes the BAR
   specifically, which narrows the mechanism sharply.
2. **Does `odvp0` move at the revert?** Same probe, same non-result.
3. **Is DYTC invoked during load?** Nothing observed yet; no OS-side trigger
   exists on this machine.
4. ~~What is in `data_vault`?~~ **Answered** — decoded above; `fwmap.sh` unpacks
   it on every run.
5. **Why does forced DPTF land TCC at 3 when the wild claw-back lands it at 30?**
   Same register, same subsystem, different value. Until that is explained the
   DPTF path is a strong candidate rather than the identified cause.
5b. **Why does the PL1 clamp need a second enable cycle?** The first `_OSC` only
   moves TCC. Reproducible, unexplained — likely the `DYTC(0x01FF)` withdrawal
   leaving state that the next entry applies differently.
6. **What enables DPTF in the wild?** The zone is `disabled` at boot and nothing
   in userspace turns it on here. If firmware can enable it autonomously under
   load, that closes the loop.
7. ~~Which path enforces the DC budget?~~ **Answered — there is no DC budget.**
   The 12-15 W battery ceiling was `power-profiles-daemon` setting EPP to
   `balance_power`. With EPP at `performance` and PL1 held at 22 W, the machine
   sustains 21.9 W on battery. The `_DC` rows in the policy table cap what DPTF
   would apply if it ran; nothing was applying them.
8. **What triggers the claw-back?** Still open, and now with battery state,
   temperature and peak power all ruled out as sufficient. The surviving
   hypothesis is a power/thermal excursion taken while the fan is still ramping
   from cold — one supporting run, no controlled pair.
9. **Is there a DC ceiling above 22 W at all?** Untested. PL1 22 W was the
   binding limit in the run that reached 21.9 W, so the question of what the
   pack and the EC allow above that is unprobed.
10. **Why does the package sustain 24.87 W with MMIO PL1 set to 22 W?** Measured
   on AC over a full 90 s run, so it is not the 28 s window letting a transient
   through. 24.87 W is within noise of the *MSR* copy's 25 W. If the MMIO copy is
   not the binding one here, "the hardware enforces min(MSR, MMIO)" — which this
   file and the README both state, and which `power-unlock` is built on — is
   wrong or incomplete on this part. The battery runs do not settle it: they
   never reached either limit.
11. **Why did the first AC run report 16 SMIs and 16 `CoreThr` events when every
   battery run reported zero of both?** Only the first run after plugging in.
   Charging is the obvious difference, and the SMI counter is the instrument the
   claw-back hunt is counting on, so what raises it here is worth knowing.
