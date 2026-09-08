# Firmware and hardware control surfaces

> Hardware facts for this machine — CPU, firmware version, batteries, what it
> does and does not have — are in [`MACHINE.md`](MACHINE.md), read from the
> machine rather than assumed. Check there before trusting a spec from memory.

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

### Which PL1 copy binds — measured (2026-09-08)

This file and the README both state that hardware enforces `min(MSR, MMIO)`, and
`power-unlock` writes only the MMIO copy on the strength of it. Open question 10
put that in doubt: a 90 s run measured 24.87 W package with MMIO PL1 set to 22 W,
which is within noise of the *MSR* copy's 25 W.

Tested directly with `pl1probe.py` — it drives MMIO PL1 to a requested value,
loads all eight threads, and samples package power from `MSR_PKG_ENERGY_STATUS`
deltas every 5 s alongside both limit copies, the TCC offset and
`MSR_PERF_LIMIT_REASONS`. AC, EPP `performance`, `power-profiles-daemon` stopped
*before* EPP was set so its AC handler could not win the race, fan pinned to
level 7 and TCC offset 4 (throttle at 96 C) so thermal could not bind.

| run | MMIO PL1 | MSR PL1 | tail-half mean | limiter in tail |
|---|---|---|---|---|
| E | 12 W | 25 W | **12.09 W** | PL1 |
| C | 18 W | 25 W | **18.10 W** | PL1 |
| D | 22 W | 25 W | **21.98 W** | PL1 |

Steady state tracks the MMIO copy across a 10 W span while the MSR copy sits
untouched at 25 W throughout. **`min(MSR, MMIO)` holds, and the MMIO copy is the
binding one.** The three places that assert it — `power-unlock.sh`, the README's
"Raising the power limits", and the `lock=0` note above — stand as written.

12 W was picked deliberately. 22 against 25 W is a 3 W discrimination, and 1.45 W
of run-to-run drift is already documented in this exact setup — the confound that
wrecked the first −50 mV attempt below. 12 against 25 W cannot be mistaken for
drift.

#### Why the 90 s run read 24.87 W

PL1 is not a hard cap. It is an average over its time window — 27.98 s here, from
`MSR_PKG_POWER_LIMIT` bits 23:17 — and a load started from idle runs at **PL2**
until that average catches up. `MSR_PERF_LIMIT_REASONS` (0x64F) names the active
limiter directly, so this is read off the hardware rather than inferred:

| t | `0x64F` low bits | bit | limiter | PkgWatt |
|---|---|---|---|---|
| 5 s | `0x1000` | 12 | max turbo | 29.97 |
| 10–30 s | `0x0800` | 11 | **PL2, 29 W** | ~29 |
| 35–300 s | `0x0400` | 10 | **PL1, 22 W** | ~22 |

Crossover at t≈33 s. A 90 s run therefore spends its first third at 29 W *by
design*, and its arithmetic mean lands well above PL1 whatever PL1 is set to:

```
prefix  90s   24.61 W     <- the original run measured 24.87 W
prefix 180s   23.28 W
whole  300s   22.76 W
tail  150s+   21.98 W     <- the actual limit
```

**The 24.87 W was a run-length artifact, not evidence about which copy binds.**
The step that made it look like evidence — "90 s is longer than the 28 s window,
so this is not a transient" — is the error: 28 s is the averaging constant, and
convergence takes several of them.

This run had the fan pinned at level 7 where the original had it on `auto`, so it
was *better* cooled, not worse, and the prefix mean reproduced anyway.

`MSR_CORE_PERF_LIMIT_REASONS` (0x690) reads `0x0` in every sample on this part.
0x64F is the one that is populated here; the kernel defines both.

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

**Disabling the zone clamps PL1 to 15 W.** Within 1 s of `disabled`, MMIO PL1
becomes `15000000` — and stays. Three independent runs, identical each time:

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

> **Correction (2026-09-08).** This section originally read the clamp as needing
> a *second enable cycle*, and open question 5b asked why. It does not: the
> trigger is the **disable**. Stepped at 1 s resolution from a clean baseline:
>
> ```
> ENABLE:   +1s  TCC=3  PL1=22000000     <- TCC moves, PL1 does not
>           +5s  TCC=3  PL1=22000000
> DISABLE:  +1s  TCC=3  PL1=15000000     <- the clamp lands here
>           +5s  TCC=3  PL1=15000000
> ```
>
> Reproduced twice. The trial log above is consistent with this once read that
> way — the `[+2242ms] TCC/PL1 = 3/15000000` line follows trial 1's *disable*,
> and trial 2 merely opens with the value already clamped. The original reading
> sampled after each enable, so a change caused by the intervening disable was
> attributed to the enable that came next. So `DYTC(0x01FF)` — the withdrawal —
> is what clamps PL1, not `DYTC(0x000F0001)`. Question 5b is withdrawn: it was
> asking about an artifact of sampling order.

Disabling the zone and re-applying restores 22 W. Nothing survives a reboot.

Reproduce it (this **overrides your power limits while enabled**):

```bash
sudo systemctl stop thinkpad-power-unlock-watch     # or it fights the firmware
D=/sys/bus/platform/devices/INT3400:00
Z=/sys/class/thermal/thermal_zone1
# On kernel 7.2.2 the zone will not enable until a UUID is selected -- a bare
# `echo enabled > $Z/mode` fails with rc=1 and changes nothing. This is new
# since the recipe was first written; pick any of $D/uuids/available_uuids.
echo 3A95C389-E4B8-4629-A526-C52C88626BAE > $D/uuids/current_uuid
echo enabled  > $Z/mode      # TCC 4 -> 3, odvp0 0 -> 7
echo disabled > $Z/mode      # PL1 -> 15000000
sudo systemctl start thinkpad-power-unlock          # put both limits back
```

**`odvp0` moves with it, and that makes it a witness.** `_OSC` provably calls
`DYTC(0x000F0001)`, and `odvp0` goes 0 → 7 at the enable. So odvp0 does track
DYTC invocation, which is what open question 3 needs — but with two caveats that
decide how it can be used:

- **It is a one-way latch.** It stays 7 through the disable, through a
  `current_uuid` reset, and through re-applying the limits. Nothing short of a
  reboot puts it back to 0. So it witnesses "DYTC has been invoked since boot",
  not "DYTC was invoked just now" — **any hunt that uses odvp0 as a live witness
  must start from a fresh boot**, or the instrument is already tripped and reads
  7 no matter what happens.
- **It is also a discriminator.** Forced DPTF sets odvp0 to 7. If a wild
  claw-back leaves odvp0 at 0, that is independent evidence the wild path is not
  this one — which would corroborate the TCC 3-vs-30 argument below with a
  second, unrelated register.

**The DPTF path raises SMIs.** `MSR_SMI_COUNT` went 2972 → 2978 across the
forcing sequence: six SMIs. That is consistent with `DYTC` resolving to
`PSIF` → `SMI(0x14, ...)` as traced in HANDOFF.md, and it means the SMI counter
is a live instrument for this path rather than a hoped-for one.

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

### One more revert, on AC this time (2026-09-08)

Caught incidentally by the PL1 probe. First load run of the session: TCC 4 and
MMIO PL1 12 W going in, and between t=5 s and t=10 s both went to the firmware
defaults — TCC 30, PL1 15 W. `MSR_PKG_POWER_LIMIT` read 25.00 W before and
after, which is what answers open question 1.

What that run logged directly is the MMIO PL1 move and the MSR staying put; it
did not yet sample TCC per row, so the TCC move is read off the thermal
signature — power pinned at 70 C with `0x64F` bit 1 (thermal) asserted, which is
throttle-at-70 and therefore offset 30 — plus the next run's header. A later
self-test settles that the signature is right: writing TCC 30 and PL1 15 W into
a healthy run by hand reproduces that row exactly, 70 C and `0x0002` included.

What this adds, and what it does not:

- **It was on AC.** Every prior capture was on battery. AC is not immune.
- **Sub-TDP PL1 is not the trigger.** The obvious reading was that writing PL1
  below the 15 W TDP provokes the firmware to reassert. Tested directly: run E
  requested the same 12 W under the same load and held it for 90 s, tail 12.09 W.
  So the request being out of range is not what did it.
- **The three later runs of the session held**, with TCC 4 written immediately
  before each load, at up to 94 C and 30 W peak. Nothing about heat or power
  separates them from the one that reverted.
- The one difference left is that the reverting run was the first load after a
  long idle, with the fan still spinning up from `auto` (2148 RPM at load onset
  against ~2460 in the runs that held). That is the cold-fan hypothesis again,
  which the section above already failed to reproduce under a direct test — so
  this is a consistent observation, not a revival of it.

The count is now one revert in four comparable AC runs on top of one in five on
battery, and the trigger is still unidentified.

### Resume reverts both registers, and the kernel hides half of it (2026-09-08)

The controlled resume test this file has been asking for, run with every repairer
out of the way. `thinkpad-power-unlock.service` was removed from
`suspend.target.wants` — the boot path left intact — because it re-applies both
limits within ~0.3 s of resume and is what wrote the `ok TCC offset = 4` line
under the REVERT lines in the wild capture above. The watch unit was already
disabled. `intel-undervolt` was checked and left alone: its config carries only
voltage offsets, no TCC, PL1 or RAPL directive, and at resume it logged only mV.
`uv-resume-probe` reads and does not write.

Limits at TCC 4 / PL1 22 W, BAT0 on `force-discharge` so the machine ran off the
pack with AC still plugged, idle, and `--no-load` deliberately — after eight
cold-start load trials the same session (below), a revert during a load
excursion would not have been attributable to the resume. `clawwatch.py`
witnessed at 1 Hz straight across the suspend; it never writes a register.
S3 entry 18:17:39, resume 18:29:54, twelve minutes down.

```
   t   PkgW  MHz   C  TCC   mmioPL1  msrPL1  SMI  cThr  limiter
   42  11.10 4009  65   4    22.00   25.00    0     0  max-turbo
   46 56981.38 3731  35  30    15.00   25.00 -2781     0  PL2
### t=46s  tcc: 4  ->  30
### t=46s  pl1: 22000000  ->  15000000
### t=46s  odvp: 0,0,0,...  ->  7,0,0,...
   48  17.28 3549  48  30    22.00   25.00 -2781     0  -
### t=48s  pl1: 15000000  ->  22000000
```

**Both registers revert, and `odvp0` moves with them — question 2 answered.**
The run began from a fresh boot with odvp0 confirmed at 0, which is the only
condition under which that question can be asked, and the latch was spent on
this capture rather than on DPTF forcing. At the first post-resume sample TCC is
30, MMIO PL1 is 15000000, and odvp0 has gone 0 → 7. The MSR copy read 25.00 W
before and after, consistent with question 1.

**That kills `odvp0` as a discriminator, which is a correction to the calibration
committed hours earlier.** Yesterday's reading was that forced DPTF sets odvp0 to
7, so a wild claw-back leaving it at 0 would be independent evidence the wild
path is not the DPTF path — corroborating the TCC 3-vs-30 argument with an
unrelated register. The wild claw-back sets it to 7 as well. So odvp0 is reached
by both paths and cannot separate them. This is **not** evidence that the wild
path *is* the DPTF path; it removes odvp0's ability to say it is not, and leaves
the TCC 3-vs-30 difference standing unaided as the whole of that argument.

**Nothing enabled the Linux zone — question 6 narrowed.** Across the revert,
`thermal_zone1/mode` stayed `disabled` and `current_uuid` stayed `INVALID`, while
odvp0 went to 7. Firmware moved its own policy variable without the OS-visible
DPTF zone ever coming up. So the thing to look for is not firmware enabling the
zone Linux can see; the register writes and the policy variable move on a path
that leaves the zone alone.

**The kernel puts MMIO PL1 back, and that has been hiding half of every resume
revert.** PL1 returns to 22000000 two seconds later while TCC stays at 30. No
userspace writer did it: the journal shows only `uv-resume-probe` (read-only) and
`intel-undervolt` (mV only) running at resume, `thinkpad-power-unlock` provably
did not run, the watch unit was disabled, and `thinkfan-ex` contains no reference
to either register.

The agent is the kernel — argued here from the module graph, confirmed by
measurement below. `intel_rapl_common` exports
`rapl_pm_notifier` and `rapl_pm_callback`, and the MMIO domain is registered on
top of that same module — `intel_rapl_common` is held by `intel_rapl_msr` and
`processor_thermal_rapl`, and it is the latter that backs `intel-rapl-mmio` here —
so a `PM_POST_SUSPEND` notifier re-applying cached constraints would reach it.
The TCC offset has no such driver-side cache, which is consistent with it staying
where firmware left it.

**Confirmed by measurement 2026-09-08 — it is the kernel, replaying a cache.**
This was inference by elimination when first written; the distinctive-value test
it called for has since been run. MMIO PL1 was set to **19000000** — a value that
appears in no config on this machine — with `power-unlock` out of
`suspend.target.wants`, AC, idle, TCC 4, witnessed at 1 Hz across a 14m41s deep
suspend.

```
   t   PkgW  MHz   C  TCC   mmioPL1  msrPL1  SMI  cThr  limiter
  122   4.11 2299  45   4    19.00   25.00    0     0  -
  127 51240.17 3429  41   4    15.00   25.00    0     0  PL2
### t=127s  pl1: 19000000  ->  15000000
  128  18.25 3901  44   4    19.00   25.00    0     0  turbo-atten
### t=128s  pl1: 15000000  ->  19000000
```

**19 W came back, not 22 W.** Firmware reverted to its 15 W default and the
restorer put back the *cached pre-suspend value*, not the 22 W that
`/etc/thinkpad-power-unlock.conf` holds. A config-driven writer would have
written 22 W; nothing did. `thinkpad-power-unlock` logged nothing at this resume,
confirming it did not run. That is the `intel_rapl_common` PM notifier re-applying
cached constraints, as argued above, and it is now measured rather than inferred.

The practical consequence stands and is sharpened: **sysfs cannot tell you
whether MMIO PL1 was reverted at resume**, because the kernel will have replayed
whatever you last wrote, ~1 s later, whatever firmware did in between.

Two consequences. **Firmware reverts both registers at resume**, symmetrically,
and the asymmetric end state is Linux's doing rather than a firmware quirk. And
**reading MMIO PL1 from sysfs after a resume cannot tell you whether it was
reverted** — it will read 22 W either way, a couple of seconds later. Any past
or future "PL1 survived the resume" conclusion drawn that way is void; only a
sampler running across the transition, or the watchdog's own log, can see it.

**`MSR_SMI_COUNT` resets across S3, so it is not an instrument for resume.** It
read 3154 before the suspend and restarted afterwards, reaching 373 by the end of
the run — hence the negative `SMI` column, which is a delta against a
pre-suspend baseline that no longer exists. Question 11 leans on this counter;
that lean is valid within a boot and void across a sleep.

**Refined 2026-09-08 across four resume captures — the post-resume count is not
arbitrary, it is ~371 every time.** The `SMI` column is `count − count at run
start`, so its sign says more about when the run was armed than about the sleep:

| capture | count at run start | `SMI` at end | post-resume absolute |
|---|---|---|---|
| battery, idle | 3154 | −2769 | ~385 |
| AC, idle (run 1) | 2923 | −2552 | ~371 |
| AC, idle (run 2) | 373 | −2 | ~371 |
| AC, 19 W PL1 | 371 | 0 | 371 |

A run armed after a previous resume already starts near 371, so it shows a
delta of 0 or −2 rather than a large negative — which is why "the delta goes
negative" is a statement about the first capture of a boot, not about S3.

The consistency is the interesting part: **every resume lands the counter at
about the same value**, which reads as the resume path itself generating a
repeatable burst of roughly 371 SMIs. The captures cannot separate "the counter
resets to 0 and the resume path then issues ~371 SMIs" from "the counter comes
back at ~371", since the first post-resume sample is already past both. Either
way the *absolute* post-resume count is a stable, meaningful number even though
the delta is not, and question 11 — whether the revert arrives through an SMI —
should be asked against that absolute rather than abandoned at the sleep
boundary. Worth chasing with a sample taken as early in the resume path as
possible.

Two instrument caveats this run exposed, both in `clawwatch.py`: the `PkgW` column
is meaningless at the resume boundary (56981.38 W — the RAPL energy counter resets
while `time.monotonic()` correctly excludes the suspended time, so the first
post-resume delta is garbage), and the `SMI` column is meaningless from the
boundary onward for the reason above. The register columns, which are what the
capture is for, are unaffected.

Left standing afterwards for the record: `coreThr` 10 and `pkgThr` 40 accumulated
while TCC sat at 30, which is the reverted offset throttling at 70 C exactly as it
says it should.

One controlled pair was still missing when this was written. Both resume reverts
on record — this one and the unattended one above — were idle **and** drawing
from the pack, so "resume reverts" rested on two events sharing a power state.
That pair has since been run, and the answer is below: on AC the resume revert
fires but spares the TCC offset.

### The AC resume revert is partial — PL1 moves, TCC does not (2026-09-08)

The controlled pair the section above asked for, and the clean run it left owed.
Runs 1 and 2 were taken on one boot — run 1 on a fresh `odvp0` of 0, run 2 on
the latch run 1 spent. **Run 3 is the clean confirmation**: its own fresh boot,
`odvp0` back at 0, every precondition held. All three had the same repairers out
of the way:
`thinkpad-power-unlock.service` removed from `suspend.target.wants` with the boot
path intact and `daemon-reload` verified against the runtime graph, watch unit
disabled, `intel-undervolt` carrying voltage offsets only and logging mV at
resume, `uv-resume-probe` read-only. One unit ran at each of these resumes that
the list above does not mention — `nvidia-resume.service` — and neither it nor
`nvidia-sleep.sh` references TCC, RAPL or powercap.

Held identical to the battery arm except the power source: TCC 4, MMIO PL1 22 W,
idle, `--no-load`, witnessed at 1 Hz across the transition. Every run's
`# start:` line records the same DPTF surface, `zone1=disabled uuid=INVALID`.
The battery arm ran with `BAT0` on `force-discharge`; these ran on `[auto]` with
the pack full, so the machine was adapter-fed.

| arm | odvp0 at start | S3 dwell | TCC | mmio PL1 | odvp0 after |
|---|---|---|---|---|---|
| battery, idle | 0 | 12m15s | **4 → 30**, stays 30 | 22 → 15 → 22 | 7 |
| AC, idle (run 1) | 0 | 8s | **4, never moved** | 22 → 15 → 22 | 7 |
| AC, idle (run 2) | 7 | 8m27s | **4, never moved** | 22 → 15 → 22 | 7 |
| AC, idle (run 3) | **0** | 7m45s | **4, never moved** | 22 → 15 → 22 | 7 |

```
   t   PkgW  MHz   C  TCC   mmioPL1  msrPL1  SMI  cThr  limiter
  402   3.72 3902  55   4    22.00   25.00    6     0  max-turbo
  407 56782.19 2823  35   4    15.00   25.00   -2     0  PL2
### t=407s  pl1: 22000000  ->  15000000
  408  16.56 2587  52   4    22.00   25.00   -2     0  turbo-atten
### t=408s  pl1: 15000000  ->  22000000
```

**The revert fires on AC — it is not a null.** `odvp0` went 0 → 7 in runs 1 and
3, and MMIO PL1 was caught at 15 W in all three, so firmware acted at every
resume. What differs from battery is which registers it takes: the TCC offset
stayed at 4 in every sample of all three runs, start to end. **Power source is
not on/off for the resume revert; it selects which registers claw back.**

**Neither of the first two runs was individually clean, but run 3 is.** Run 1 had
the required `odvp0 = 0` start and a dwell of only 8 s. Run 2 matched the battery
arm's dwell but began with `odvp0` already latched at 7, spent by run 1 — the
exact confound the precondition exists to prevent. Run 3 carries neither defect:
fresh boot, `odvp0 = 0` at entry, TCC 4 and MMIO PL1 22 W, AC online with `BAT0`
on `[auto]`, watch unit inactive, and the repairer verified out of
`suspend.target` in the runtime graph rather than only on disk. Firmware acted,
and TCC did not move in any of the 293 rows:

```
### t=60s  pl1: 22000000  ->  15000000
### t=60s  odvp: 0,0,0,... -> 7,0,0,...
### t=61s  pl1: 15000000  ->  22000000
# end: TCC=4 MMIO_PL1=22000000   odvp0..19 = 7,0,0,...
```

**The short dwell does not reopen the question.** Run 3 slept 7m45s — less than
run 2, less than the battery arm — and dwell is exactly what retired run 1, so
the objection deserves an answer rather than a footnote. It does not carry
across.
Run 1's defect was that 8 s might not have given firmware the chance to act at
all, which is what made its TCC hold uninformative. Run 3 shows firmware acting:
PL1 caught at 15 W and `odvp0` going 0 → 7, with TCC holding straight through it.
Dwell adequacy here is established by the outcome, not by the clock. The long
side is covered independently — the 19 W PL1 test below slept 14m41s, longer
than the battery arm, and ended at TCC 4. That run is still **not** a TCC arm:
non-standard PL1, `odvp0` already spent, and not run for this question, so it
does not stand in for run 3. What it does is bound the range, leaving no
untested band between 7m45s and 14m41s on AC in which a dwell-gated TCC revert
could be hiding.

Run 2 also shows firmware reverting PL1 *with* `odvp0` already at 7, so a latched
policy variable does not gate the revert mechanism — for it to explain the TCC
hold it would have to suppress the TCC write selectively while leaving the PL1
write intact, which nothing in this record proposes.

**What is still owed is a second battery resume, and it needs a reboot** — `odvp0`
is spent at 7 on this boot.

**The battery arm is n=1.** This asymmetry rests on four AC idle resumes — three
run as TCC arms, plus the 19 W PL1 test — against a single battery capture with a
per-row TCC reading. The base-rate problem recorded
above — one revert in five comparable battery runs — is about the wild claw-back
rather than resume, and every resume tested so far has reverted *something*, so
the resume trigger looks reliable in a way the load trigger is not. But "battery
takes TCC, AC does not" is one capture per arm on the register that matters, and
should be read as such until a second battery resume confirms it.

**This does not contradict "AC is not immune" above.** That capture was a *wild*
claw-back during a load run, where TCC did go to 30 — inferred from the thermal
signature rather than sampled per row. The event here is a resume, a different
and far more reliable trigger. Taken together they say the resume revert on AC
spares TCC while the wild claw-back on AC does not, which is a point of
separation between the two paths rather than a conflict.

**A correction to `thinkpad-power-unlock`.** That script's header comment has
long claimed "suspending an *idle* T480 leaves both limits untouched… Idle resume
needs nothing; loaded resume does." The battery arm is an idle resume that
reverted both registers, and both AC runs are idle resumes that reverted PL1. The
comment predates the removal of the repairer from the suspend path, which is
almost certainly why idle resumes looked clean: the unit put the limits back
0.3 s later. Corrected in the script.

### Eight cold-start trials on AC, none reverted (2026-09-08)

Run before the resume test, as the observational stage the batched block called
for: 120 s of 8-thread load per trial, each preceded by a cooldown to ≤52 C with
the fan stopped, so every trial was a genuine cold start rather than a
continuation. AC, EPP `performance`, TCC 4 / PL1 22 W, watch unit disabled,
witnessed at 1 Hz by `clawwatch.py`.

Seven ran the full 120 s; the eighth was cut short at 74 samples when the
campaign was stopped to free the machine for the resume test. All eight held.
Peaks 30.5–33.6 W at 91–92 C, every trial inside or above the excursion band of
the run that reverted (32 W, 81 C), and odvp0 ended at 0 in all eight. Nothing
moved in 872 samples.

This is further evidence against the cold-fan hypothesis, which the direct test
above already failed to reproduce — these trials reproduced the cold-start
condition eight times over with the fan stopped at trial onset, at higher peak
power and higher temperature than the reverting run, and produced nothing. It
also answers **question 3 for the load case**: firmware did not invoke DYTC
during any of them, odvp0 having stayed at 0 throughout. Where it *is* invoked is
at resume, which the section above catches directly.

The AC load count is now one revert in eleven comparable full-length runs,
against one in five on battery.

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
across all four — 24.87, 23.67, 23.42, 22.08 W — regardless of voltage. Each
−50 arm was ~1.2 W under the 0 arm before it, but the drift between two 0 arms
was 1.45 W. **The effect and the confound were the same size.** A power-limited
comparison cannot answer this: the governor is free to trade the saved watts for
clock, and the clock was falling too.

> **Correction (2026-09-08).** This paragraph originally attributed the decline
> to the chassis soaking heat. That is wrong. The decline is the PL1 average
> converging: the first arm caught the PL2 phase, each later arm started further
> into the converged state, and the series terminates at 22.08 W — the MMIO PL1
> setting itself, not a thermal asymptote. See "Which PL1 copy binds" above,
> where a 300 s run reproduces the same curve with the temperature held down by
> a pinned fan. The conclusion this paragraph draws is unaffected: what killed
> the comparison was the drift, not what caused it.

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
> for is the power-limited one, where the saved watts come back as clock. See
> the −80 mV result below, which measures exactly that.

### −80 mV on core and cache — and the payoff, measured

Both planes together, which is how these parts are normally moved. Readback
`-80.08 mV` on plane 0 and plane 2.

Same pinned-2.0 GHz protocol as above, six 40 s arms under one continuous load:

| arm | `CorWatt` | `PkgWatt` | `PkgTmp` |
|---|---|---|---|
| 0 mV | 9.18 | 10.98 | 56 |
| −80 mV | **7.48** | 9.37 | 53 |
| 0 mV | 9.12 | 11.06 | 56 |
| −80 mV | **7.52** | 9.33 | 53 |
| 0 mV | 9.32 | 11.24 | 56 |
| −80 mV | **7.63** | 9.71 | 53 |

9.21 W mean against 7.54 W: **−18.1 % core power**, no overlap, and the package
runs 3 C cooler at the same clock. Against −4.2 % for −50 mV on the core alone —
most of that gap is the cache plane, which the earlier test did not move.

Then the measurement that answers "what does this buy": identical protocol,
frequency **unpinned**, so the machine sits in the PL1-limited regime where the
governor spends whatever the undervolt saves.

| arm | `Bzy_MHz` | `PkgWatt` | `PkgTmp` |
|---|---|---|---|
| 0 mV | 2833 | 21.80 | 82 |
| −80 mV | **3103** | 21.99 | 82 |
| 0 mV | 2886 | 21.78 | 83 |
| −80 mV | **3104** | 21.81 | 83 |
| 0 mV | 2812 | 21.88 | 82 |
| −80 mV | **3073** | 22.03 | 83 |

2844 MHz against 3093 MHz — **+249 MHz, +8.8 % all-core clock, at the same
21.9 W and the same 82-83 C**. Power differs by 0.12 W between the groups and
temperature by under a degree, so the clock is the whole of the difference. That
is the payoff, and it is the number to quote.

Stability at −80 mV: 776 SHA-256 passes across 8 workers with zero mismatches,
three single-thread turbo bursts, no machine checks, offsets intact afterwards.

> **That is "not obviously unstable", not "validated".** Real undervolt
> validation is hours of mixed workloads — AVX, single-thread turbo, light load,
> and idle transitions, which is where these fail first. Two minutes of hashing
> rules out the crudest failure only. Nothing was left applied.

### −100 mV, and where the curve is going

Same two sweeps at −100 mV on core and cache (readback `-99.61`), plus a probe
aimed at the regime an all-core hash loop never visits: ten single-thread bursts
at max turbo with idle gaps between them, which is where undervolts fail first.

| | 0 mV | −100 mV |
|---|---|---|
| pinned 2.0 GHz, `CorWatt` | 9.09 / 9.04 / 9.16 | **6.94 / 6.96 / 6.99** |
| pinned 2.0 GHz, `PkgTmp` | 57 | **52** |
| unpinned, `Bzy_MHz` | 2888 / 2884 / 2881 | **3181 / 3178 / 3178** |
| unpinned, `PkgWatt` | 21.90 | 21.92 |

**−23.5 % core power at a fixed clock, or +295 MHz (+10.2 %) at a fixed 21.9 W**,
with the two power figures 0.02 W apart and temperatures within a degree. IPC was
1.20 in all six unpinned arms and 1.19 in all six pinned ones.

The whole set so far, on one machine, one protocol:

| offset | planes | core power at 2.0 GHz | all-core clock at 21.9 W |
|---|---|---|---|
| 0 | — | 9.10 W | 2884 MHz |
| −50 | core | −4.2 % | not measured |
| −80 | core + cache | −18.1 % | 3093 MHz (+8.8 %) |
| −100 | core + cache | −23.5 % | 3179 MHz (+10.2 %) |

~~**The returns are flattening.**~~ **Corrected at −120 mV — they are not, in the
metric that matters.** That claim came from watching the fixed-clock power saving
grow by less each step. The fixed-power *clock* gain did the opposite; see the
−120 mV row below. Both are true at once: at a fixed clock the saving flattens as
the part approaches its voltage floor, while at a fixed power budget the clock
gain grows, because the power-frequency curve steepens as voltage comes down. The
second is the one an undervolt is for.

Stability at −100 mV: 781 SHA-256 passes across 8 workers, ten single-thread
turbo bursts with idle gaps, zero mismatches, no machine checks. Still not
validation — see the caveat above, which applies with more force at this offset.
**Since superseded by two hours and 142 332 checked answers**; see
[−100 mV, held for two hours](#100-mv-held-for-two-hours-and-checked-the-whole-way).
Nothing was left applied; all five planes read 0.00 mV.

### Core and cache share a rail — the planes are not independent

The question asked was which plane gates the stability limit. The answer is that
on this part the question does not have the shape it looks like it has.

Three pinned-2.0 GHz sweeps at −100 mV, same protocol, differing only in which
planes were moved:

| moved | 0 mV | −100 mV | delta |
|---|---|---|---|
| core only | 9.02 W | 8.73 W | **−0.29 W** (−3.2 %) |
| cache only | 9.18 W | 9.10 W | **−0.08 W** (−0.9 %, arms overlap) |
| both | 9.10 W | 6.96 W | **−2.13 W** (−23.5 %) |

The two singles sum to −0.37 W. Together they give −2.13 W — nearly six times
their sum. Power is additive, so no model in which the planes have separate
supplies can produce that.

**They share one voltage rail, and the delivered voltage follows the higher of
the two requests.** Undervolting one plane alone leaves the other's unchanged
request holding the rail up, which is why each single is worth almost nothing and
the pair is worth a quarter of core power. This is the documented shared-VCC
arrangement on Intel client parts, and it is exactly why the standing advice is
to move core and cache together — the measurement here is that advice with a
number on it.

**It also invalidates the split-plane test that produced it.** Core −110 with
cache −80, and core −80 with cache −110, both ran clean through the probes. Read
naively that says neither plane gates at −110. Read correctly, **neither
configuration ever put −110 on the rail**: the delivered undervolt is the smaller
of the two offsets, so both arms were −80 experiments wearing different labels.
Asymmetric offsets cannot probe past the smaller one, so finding the stability
limit means moving both planes together and stepping down.

> Inferred from power behaviour, not measured at the regulator. The shared-rail
> model is the only one consistent with the super-additivity above, and it agrees
> with the known design of this generation, but nothing here reads the VR
> directly.

### −120 mV: no limit found

Run to find the edge, on the understanding that a hang or a shutdown *is* the
result. Neither happened. Both planes at `-120.12 mV`:

| | 0 mV | −120 mV |
|---|---|---|
| pinned 2.0 GHz, `CorWatt` | 9.19 / 9.20 / 9.01 | **6.66 / 6.64 / 6.62** (−27.3 %) |
| pinned 2.0 GHz, `PkgTmp` | 57-58 | **52-53** |
| unpinned, `Bzy_MHz` | 2887 / 2883 / 2882 | **3244 / 3241 / 3241** |
| unpinned, `PkgWatt` | 21.97 | 21.90 |

**+358 MHz, +12.4 %, at the same 21.9 W.** Survived ten single-thread turbo
bursts with idle gaps, 4625 SHA-256 passes across 8 workers with zero mismatches,
twelve voltage transitions across two sweeps, and roughly eight minutes under
load at the offset. No machine checks, no hang, no shutdown.

The full progression, gain measured against each run's own baseline:

| offset | fixed-clock core power | fixed-power clock | gain |
|---|---|---|---|
| −80 | −18.1 % | 3093 MHz | +249 MHz (+8.8 %) |
| −100 | −23.5 % | 3179 MHz | +295 MHz (+10.2 %) |
| −120 | −27.3 % | 3242 MHz | **+358 MHz (+12.4 %)** |
| −140 | not measured | not measured | **hard hang — see below** |

Power saving per 20 mV step: 5.4 then 3.8 points — flattening. Clock gain per
step: +46 then +63 MHz — **growing**. ~~The stability limit on this part is
somewhere past −120 mV and these probes have not found it.~~ **Superseded at
−140 mV**, which hung the machine — see [−140 mV: the hang](#140-mv-the-hang).
The limit is past −120 and not past −140, on one sample.

> **"No limit found" is not "stable at −120 mV".** Minutes of hashing and two
> sweeps are hours short of validation, and the failure this hunt is looking for
> — a wrong answer under a workload nobody tested — does not announce itself. The
> limit being past −120 is a fact about the probes as much as about the part.

### −140 mV: the hang

The next step down took the machine. The −120 run was written up as run "to find
the edge, on the understanding that a hang or a shutdown *is* the result" — this
is that result arriving, not an accident.

**Reported, not instrumented.** The step to −140 mV was taken outside the logged
protocol and the machine hung before anything about it reached disk. What the
system can still show:

| | |
|---|---|
| last entry, boot −1 | `17:29:49.029171`, a routine `[UFW BLOCK]` kernel line |
| shutdown record | **none** — `last` shows boot −1 as "still running" |
| next boot | `18:10:36`, ~40 min later |
| filesystem | btrfs `start tree-log replay` on mount — unclean unmount |
| MCE / panic / oops | **none**, in either boot |
| all five planes, after reboot | `0.00 mV` |
| how it died | **frozen, display still lit** — operator-observed |

The journal ends mid-stream on an unremarkable line. That dates the crash to **at
or after 17:29:49**, not to 17:29:49 — journald's default `SyncIntervalSec=5m`
means up to five minutes of entries were in memory and went with the hang, and
the `0x150` write, its readback, and whatever workload was running were in that
window. So the offset that hung it is **the offset reported, not an offset read
back from the mailbox**, and the file should not pretend otherwise.

**No machine check is itself a datum.** A hang with no MCE, no panic and no oops
is a different signature from a corrected or uncorrected error being logged: the
kernel did not survive to write anything. That is consistent with the core simply
ceasing to execute correct instructions — the expected failure of too deep an
undervolt — rather than with a thermal event or a detected data error.

**It froze with the display still lit, which rules out the power-delivery paths.**
Every mechanism that kills the machine from outside the core takes the backlight
with it: a regulator over-current or under-voltage protection trip, an EC thermal
cutoff, a platform reset. None of those happened — the panel stayed lit on the
last frame, so **the rails held and nothing protective fired**. Whatever failed,
failed while the platform was still being powered normally.

That is evidence about power delivery, not about the CPU. Scanout is autonomous:
the display engine walks the framebuffer over DMA on the iGPU plane, which was
left at `0.00 mV` and never moved, so it keeps painting the last frame whether or
not a core is still retiring instructions. A lit screen therefore does **not**
separate "the cores stopped executing" from "the kernel panicked and hung without
logging" — both leave exactly this picture. What it does say is that the failure
was in computation, not in the supply that protection circuits watch, which is
the shape a too-deep undervolt is supposed to have.

**What this bounds, and what it does not.** One event, one sample, no
replication: the honest statement is that the first hang in the sweep came at the
first attempt past −120, so on this part the limit is **≤ −140 mV**. That is a
bracket, not a characterised boundary. It does not locate the limit within the
20 mV gap, does not say whether −130 runs, and — the point the −120 caveat
already made — does not promote −120 to "stable", since the probes that cleared
−120 were minutes of hashing against a failure mode that takes hours to show.

Nothing persisted. Voltage offsets in `MSR 0x150` live in the mailbox until power
is lost, so the reboot cleared them; all five planes read `0.00 mV` unprompted, no
repo script writes the MSR (`fwmap.sh` only reads it), and no unit re-applies a
voltage offset at boot — `thinkpad-power-unlock` runs and restores TCC 4 and
MMIO PL1 22 W, as it does every boot, and touches no voltage plane. The
filesystem replayed its log and reported no errors after. The cost of the
experiment was one hard reboot.

> **One fact about this crash is still missing:** whether the readback confirmed
> −140 mV actually landed on the rail. Nothing in the logs can supply it, so the
> offset above stays a reported figure. The other missing fact — how it died — was
> supplied by the operator and is recorded above; it is the only thing separating
> a protection trip from a computational failure, and the logs are identical
> either way, which is to say empty.

### The display artifact at −120 mV, which nothing corroborates

The plan after −140 was a long, logged run at −120 to turn "no limit found" into
something that could be attested. It ran 401 seconds and was stopped early,
because **the operator saw blocky artifacts on screen**.

Nothing else in the machine saw anything:

| witness | reading |
|---|---|
| the run's own checks | 8286 answers verified, **zero mismatches** |
| `i915` / `drm` | no error, no FIFO or pipe underrun, no GPU hang, no reset |
| btrfs | `corruption_errs 0` |
| machine-check banks | no new bank set |
| compositor / journal | nothing |
| offset readback | `-120.12 mV` on both planes for every sample |
| 0 mV baseline afterwards | reproduces |

**When it happened is the most informative thing about it.** The artifact fell
inside the `turbo-burst` phase — one core at 4.19 GHz with a 5 s on/off duty
cycle and the other seven in deep C-states. That cuts against the boring
explanation: turbo-burst is the phase where the machine is *least* loaded, so
"the compositor was starved by an eight-thread soak" is least available exactly
where the artifact appeared. It is also the top of the voltage-frequency curve
with a voltage transition every five seconds, which is the regime this file has
been saying undervolts fail in first.

Three candidates survive, and honesty requires listing the instrument among
them:

1. **The cache plane is the ring and the LLC.** Framebuffer traffic crosses it.
   A chunk-sized wrong answer in transit is what blocky artifacts look like, and
   the three checks running at the time — SHA, modexp, matmul — all verify
   values that live in registers and L1. None of them watched a path that
   reaches DRAM. *(A fourth check that does was added afterwards; see below.)*
2. **The harness's own `MSR 0x150` poll.** It reads the offset back every five
   seconds, which means writing the mailbox command word — on the same core
   running the turbo burst. The earlier −120 runs read the mailbox only at start
   and end. This is new behaviour introduced by the instrument.
3. **Coincidence.** A driver or compositor artifact with no relation to voltage.

One thing it is *not*: the iGPU browning out. The iGPU is on its own rail. If it
shared with core and cache, an active compositor would hold the rail up and the
−27 % core power saving measured at −120 would have vanished — and it did not.

**Three hours later, the candidates are no longer equal.** The runs that
followed — two hours at −100 mV on AC, 45 minutes at −100 mV on battery, and a
10-minute control at 0 mV — all used the same harness, the same phases and the
same five-second mailbox poll. **No artifact was reported in any of them.**
Measured in the phase the artifact appeared in:

| arm | turbo-burst exposure | artifacts | operator attention |
|---|---|---|---|
| −120 mV, original | 120 s | **1** | at the machine |
| −120 mV, **replication** | 360 s | **0** | divided |
| −100 mV, AC | 1560 s | 0 | mostly away |
| −100 mV, battery | 600 s | 0 | present |
| 0 mV control | 120 s | 0 | present |

**That is 19× the exposure at a shallower offset, with the instrument behaving
identically, and nothing seen.** It weakens candidate 2 considerably: roughly
2160 mailbox polls happened at −100 and 0 mV without producing an artifact, so
polling *alone* does not do this. It weakens candidate 3 too, though absence
never disproves a one-off. ~~Candidate 1 — the ring and LLC at −120 — is now the
one standing without a mark against it.~~ **Corrected by the replication below,
which put a mark against candidate 1 as well.**

> **Two things this does not establish.** The exposure ratio is machine time,
> not observed time: the operator was not watching the screen continuously
> through a two-hour unattended soak, so "no artifact reported" is weaker than
> "no artifact occurred", and the battery leg and control — where the screen was
> deliberately kept awake and someone was present — account for only 720 s of
> that 2280 s. And candidate 2 is weakened in its simple form only. "The mailbox
> poll perturbs the rail *when the rail is already at −120*" is untouched by any
> of this, because nothing has polled at −120 since.
>
> **So −120 mV stays off the attestable list.** One unreplicated event, no
> logged corroboration, and the two tests that would settle it — replicating at
> −120, or running −120 with the poll interval widened — have not been run.

### The −120 replication, which did not reproduce it

The first of those two tests was then run: 30 minutes at `-120.12 mV`, same
harness, same phases, same five-second poll, same operating point — AC, EPP
performance, MMIO PL1 22 W, 4.2 GHz cap, watch unit and `thinkfan-extreme`
active, all confirmed before starting. **Nothing appeared.**

| | |
|---|---|
| ran | 1801 s at `-120.12 mV`, verdict `completed` |
| answers verified | 37 761 — sha 9451, int 9449, avx 9434, mem 9427 |
| mismatches | 0 |
| new machine-check banks | none |
| 0 mV baseline afterwards | reproduces |
| turbo-burst exposure | **360 s — 3× the run that produced the artifact** |
| artifacts reported | **none** |

**The machine was in the right state, and that was checked rather than assumed.**
The artifact appeared in `turbo-burst`, whose whole point is one core at
4.19 GHz while the other seven drop into deep C-states; any background load
holding those cores busy would mean the regime was never entered and the
replication would be worthless. The package-power record rules that out:

| | idle mean / max PkgW | turbo-burst mean PkgW |
|---|---|---|
| −100 mV, 2 h AC | 2.12 / 4.29 | 9.32 |
| −120 mV replication | **2.14 / 2.28** | **9.08** |

Idle-phase power is within 0.02 W of the earlier run and its *maximum* is lower
— 2.28 W against 4.29 W — so the cores genuinely idled and the deep-idle and
transition regimes were entered as designed.

**The weakness is in the observer, not the machine.** The artifact is visible
only to a person looking at the screen, and during the replication the operator
was working on a different machine. "Nothing noticed" over 30 minutes of divided
attention is a weaker negative than the raw 3× exposure suggests — the original
sighting happened under *active* attention and was caught within about six
minutes. A dim, brief, or single-frame artifact could have passed unseen here in
a way it would not have then.

**The ranking still inverts, with that caveat attached.** Both voltage-linked
candidates have now failed to reproduce: polling survived roughly 2160 polls at
−100 and 0 mV, and the ring-and-LLC explanation survived 3× the exposure at
−120 itself. That leaves **candidate 3 — coincidence** — as the best-supported
reading, which is the one this file had been treating as least interesting.

> **One event and one imperfect failed replication settles nothing.** A
> transient that fires once in six minutes and then not once in thirty is not so
> much *explained* by coincidence as *left unexplained*, and the honest position
> is that this machine did something once that nobody has reproduced or
> accounted for. The remaining clean test is the one still not run: −120 with
> the mailbox poll widened, watched deliberately rather than incidentally.
>
> **It does not promote −120 mV.** 37 761 answers is a twelfth of what stands
> behind −100, and a clean replication does not cancel a dirty observation.
> **−100 mV remains the setting in stone**; −120 remains a place this machine has
> been, twice, without a reason to stay.

### −100 mV, held for two hours and checked the whole way

Backed off one step and ran the soak that −120 did not finish. Two hours,
dedicated machine, on AC, at `-99.61 mV` on core and cache.

| | |
|---|---|
| ran | **7202 s**, verdict `completed` |
| answers verified | **142 332** — sha 35 630, int 35 612, avx 35 567, mem 35 523 |
| mismatches | **0** |
| new machine-check banks | none |
| 0 mV baseline recomputed after | **reproduces** |
| offset readback | `-99.61 mV` on both planes, all 1437 samples, no drift |
| MMIO PL1 | 22 W on all 1437 samples |

Four workload classes, not one, cycling through four phases about thirteen times:

| phase | samples | mean MHz | peak MHz | mean PkgW | peak C |
|---|---|---|---|---|---|
| all-core | 657 | 3050 | 3397 | 21.97 | 92 |
| mixed | 312 | 3640 | 3852 | 23.86 | 98 |
| turbo-burst | 312 | 4158 | 4194 | 9.32 | 97 |
| idle | 156 | 4113 | 4144 | 2.12 | 44 |

224 samples at or above 90 C and 52 at or above the 96 C TCC clamp, so this was
not a cool run — the part spent real time against its thermal limit while
undervolted. (`Bzy_MHz` is busy-frequency, which is why the idle row reads high:
the only thing running in that phase is the sampler itself, at turbo.)

**What this attests, precisely.** Two hours at −100 mV, on this machine, at
PL1 22 W / TCC 4 / EPP performance, across all-core, partial, single-thread
turbo and deep-idle phases, produced no wrong answer in four unit classes —
SHA-NI, the integer multiplier, AVX2 FP through BLAS, and a 64 MB DRAM buffer
per worker hashed whole every round. Every reference reproduces at 0 mV
afterwards, so the checks were checking something.

> **What it does not attest.** Two hours of a synthetic mix is not a year of
> real work: it narrows "a wrong answer under a workload nobody ran" without
> closing it. Nothing here exercises the GPU, the display path, storage or the
> network, and the −120 artifact above is a standing reminder that a symptom can
> appear in a subsystem the checks do not watch. This is the strongest statement
> this file can make about an undervolt on this part, and it is still a statement
> about two hours.

The harness is `uvsoak.sh`, committed alongside `fwmap.sh` and `burnboth.sh`:

```
sudo ./uvsoak.sh                    # 2h at -120 mV, AC
sudo ./uvsoak.sh 7200 -100          # what produced the table above
sudo ./uvsoak.sh 2700 -100 battery  # battery leg, stops at 30% capacity
sudo ./uvsoak.sh 600 0              # control run, no offset
```

It computes its reference answers at 0 mV before applying the offset, recomputes
them at 0 mV after clearing it, and writes them into the log header as constants
any machine can reproduce — a reference the device under test produced and kept
only in RAM proves nothing if the device was already wrong. Every line is
fsynced, which is the −140 lesson: if the machine goes down, the last line on
disk is the last thing that was true, including the phase it died in.

### −100 mV on battery: the offset changes what it buys

Unplugged, EPP drops to `balance_power` on its own — the clamp this file already
traced to EPP rather than firmware, visible live in the log header. That changes
the experiment, so the battery leg is a separate arm: 45 minutes at `-99.61 mV`,
then a 10-minute control at 0 mV through the same phases for comparison.

The leg itself was clean: **2702 s, 37 328 answers verified** (sha 9353, int
9345, avx 9324, mem 9306), zero mismatches, no new machine-check banks, the 0 mV
references reproducing afterwards, and no offset or PL1 drift across 538
samples. Battery went 100 % to 85 %.

**On battery the clock is pinned, so the offset spends itself on power instead.**
On AC the part is power-limited and a lower voltage buys frequency. Here EPP has
already clamped the clock and it does not move:

| phase | | 0 mV | −100 mV | delta |
|---|---|---|---|---|
| all-core | MHz | 2300 | **2300** | — |
| | package W | 14.18 | **11.40** | **−19.6 %** |
| | system W | 23.4 | **19.8** | **−15.4 %** |
| | peak C | 66 | 59 | −7 |
| mixed | MHz | 2389 | 2297 | −3.9 % |
| | package W | 10.64 | 8.07 | −24 % |
| turbo-burst | MHz | 2148 | 2062 | −4.0 % |
| | package W | 3.70 | 3.27 | −11.6 % |
| idle | MHz | 783 | 787 | — |
| | package W | 1.80 | 1.81 | — |

The all-core row is the clean one: `balance_power` pins both arms to exactly
2300 MHz — a ratio-23 ceiling, not a thermal or power effect — so power is the
only variable left and the comparison is like-for-like. A fifth off package
power and a seventh off the whole machine, at an identical clock. The idle row
is the sanity check: with nothing running there is nothing to save, and nothing
was saved.

**So an undervolt does not make this laptop faster on battery. It makes it last
longer.** At sustained all-core load, 23.4 W to 19.8 W against 71.7 Wh of
battery is 3.1 hours becoming 3.6 — about **+18 % runtime**. Trust the ratio
more than the hours: `power_now` and the capacity gauge disagree by about 10 %
on the same leg (16.0 W by the meter, 14.4 W by 10.8 Wh drawn in 45 minutes),
and no real workload looks like this phase mix, which is 45 % all-core
saturation.

> Two asymmetries between the arms, stated rather than smoothed over: the
> control ran 10 minutes against the leg's 45, and it ran at a different battery
> level. The all-core row survives both — 60 samples against 240, same pinned
> clock — but the `mixed` and `turbo-burst` rows move in clock as well as power,
> so their percentages are not clean single-variable comparisons.

One practical note for repeating this: hold a screen inhibitor for the duration.
`kde-inhibit --power --screenSaver systemd-inhibit --what=idle:sleep:handle-lid-switch …`
is a held process rather than a settings change, so nothing needs undoing. Idle
suspend is the real hazard, not the blank screen — a suspend mid-run puts the
machine through a resume cycle, and the claw-back on resume is documented above.

### The offset does not survive suspend — measured, not assumed

−100 mV was made persistent, which raised the question of what a lid close does
to it. The obvious test — suspend, resume, read the mailbox — cannot answer it,
because anything that re-applies on resume has already run by the time you look.
"Survived S3" and "was restored for you" produce an identical reading and are
different facts about the hardware.

So a probe was ordered in front of the re-apply: a oneshot unit on the same
resume path, `Before=intel-undervolt.service`, that reads all five planes and
appends them to a log. One lid close, and:

```
22:33:08 pre-reapply  core=+0.00 igpu=+0.00 cache=+0.00 sa=+0.00 aio=+0.00
22:33:08 intel-undervolt: CPU (0): -99.61 mV / CPU Cache (2): -99.61 mV
```

Both planes read `-99.61 mV` going into the suspend. **They come back at zero.**
S3 drops the OC mailbox entirely, and the offset that was there before the lid
closed is simply gone — restored a fraction of a second later only because a unit
was there to do it.

Two things follow. **It fails safe**: a machine that loses the re-apply — unit
disabled, package removed, a boot into something else — resumes at stock voltage
and keeps working, rather than resuming undervolted into a state nothing has
validated. And **an unmanaged undervolt is not persistent in any sense**; every
suspend silently discards it, so anyone measuring after a lid close without a
re-apply unit is measuring a stock machine and may not know it.

This also sits alongside the claw-back already documented above: on the same
resume, `thinkpad-power-unlock` restored TCC 4 and MMIO PL1 22 W. Resume resets
more than one thing on this machine, and each one needs its own hook.

A later run put a lower bound on how long the suspend has to be. A deliberate
short S3 — down at 13:58:10, up at 13:58:27, of which **11.9 seconds was
actually spent suspended** — came back at `+0.00` just like the multi-hour ones.
**The wipe is not a slow drain; it is immediate.** There is no "short nap" case
where the offset would have held.

> [!WARNING]
> **A suspend that aborts still writes a row to this log, and the row looks like
> good news.** The probe is `WantedBy=suspend.target`, and a failed suspend fires
> that target as surely as a successful one — so the machine wakes without ever
> having lost power to the core rail, and the probe faithfully records the offset
> still in place:
>
> ```
> 13:16:42 pre-reapply core=-99.61 cache=-99.61      # suspend ABORTED, not survival
> 13:41:27 pre-reapply core=-99.61 cache=-99.61      # suspend ABORTED, not survival
> ```
>
> Those two rows are real, and they are in this machine's log — written while a
> stale `nvme0` was refusing to suspend with `-16` (see
> [`MACHINE.md`](MACHINE.md#a-removed-nvme-leaves-a-stale-device-that-blocks-suspend--cleared)).
> Read alone they refute the finding this whole section establishes. **Pair every
> row with the kernel's own verdict before believing it:**
>
> ```bash
> journalctl -b -k | grep -E 'PM: suspend (entry|exit)|failed to suspend'
> ```
>
> A trustworthy row has a `PM: suspend exit` with no `PM: Some devices failed to
> suspend` before it. Anything else measured nothing.

#### The probe now tags its own rows

Rather than leave that check to whoever reads the log next, the probe asks the
kernel directly. `/sys/power/suspend_stats/{success,fail}` are counters, so a
run that diffs them against the previous run knows what the resume it is
recording actually was:

```
14:11:57  core=+0.00   ... suspend=real    slept=80s  stats=+1s/+0f
14:08:27  core=-99.61  ... suspend=aborted slept=0s   stats=+0s/+1f failed=suspend:0000:01:00.0:-5
```

Both of those are real rows from this machine, not illustrations, and they are
the two cases the log previously could not tell apart. Note that the second one
carries the identical plane readings to a surviving offset — `-99.61` on core
and cache — and is now unmistakable anyway.

Three details are load-bearing:

- **The baseline resets on `boot_id`, not on counter magnitude.** The counters
  restart at zero every boot, so "current is lower than stored" looks like the
  obvious reset trigger — and it silently fails for a boot whose counters land
  on the same values as the stored ones, tagging a genuine S3 `unknown`.
  `/proc/sys/kernel/random/boot_id` is the actual discriminator.
- **`slept=` is recorded but is not an input to the tag.** It is the growth in
  `CLOCK_BOOTTIME` − `CLOCK_MONOTONIC`, which is exactly the time spent
  suspended and nothing else — an independent witness. Folding it into the tag
  would let this script quietly resolve a disagreement between two sources. Left
  separate, `suspend=real slept=0s` is a visible contradiction in the log, which
  is the property the log exists for.
- **A row is always written, even when something throws.** The tagging is in a
  `try`, and a failure still emits the row as `suspend=unknown reason=...`. A
  missing row and a suspend that never happened look identical from the outside;
  a row that admits it does not know does not.

Both paths are tested through the real resume chain. The `real` row above is a
84-second `systemctl suspend` on 2026-09-08 — entry 14:10:32, exit 14:11:56, of
which 80 s was spent suspended — that came back at `+0.00`, was re-applied to
`-99.61` by `intel-undervolt.service` a moment later, and had both witnesses
agree.

The `aborted` path is tested against a real failure, not a simulated one: an
`rtcwake` attempt was refused by the NVIDIA driver with `-5`, and the probe
named the device out of `last_failed_dev` unprompted. That test also produced
its own finding, filed under
[Hazards](MACHINE.md#rtcwake-and-direct-syspowerstate-writes-skip-every-sleep-hook):
**`rtcwake` writes `/sys/power/state` directly, so `suspend.target` never fires
and none of the re-apply units run.** Had that suspend succeeded, the machine
would have resumed at stock voltage with nothing to say so — and no probe row
either, because the probe is one of the units it skips.

### What is installed, and how to remove it

| piece | role |
|---|---|
| `/etc/intel-undervolt.conf` | −100 mV on planes 0 and 2, with the evidence and the shared-rail warning in the comments |
| `intel-undervolt.service` | applies at boot and on resume — the same shape as `thinkpad-power-unlock.service` |
| `uv-resume-probe.service` | records the pre-re-apply readback on every resume, to `/var/log/uvsoak/resume-probe.log`, tagged `real` or `aborted` |
| `uv-resume-probe.py` | the probe's source, in this repo; installs to `/usr/local/sbin/uv-resume-probe` |
| `/var/log/uvsoak/resume-probe.state` | the probe's counter baseline — delete it and the next row tags `real` off a zero baseline, which is harmless |

`intel-undervolt-loop.service` — the daemon that re-applies every five seconds —
is deliberately **not** enabled. Nothing needs it, and it would poll the mailbox
continuously, which is the one candidate for the −120 mV display artifact that
has not been ruled out.

To remove: `sudo systemctl disable --now intel-undervolt.service
uv-resume-probe.service`, then reboot or power-cycle. Nothing persists in
hardware, so the reboot alone returns every plane to 0.00 mV.

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
Several have since been read — sizes, attributes and the fact that all of them
carry runtime access — in [`BIOS-MOD.md`](BIOS-MOD.md), along with what the
public research on unlocking them does and does not establish.

## Before you write anything

Read-only enumeration is safe and is all `fwmap.sh` does. The write tier is not
uniformly risky, and the difference is worth keeping straight:

- **Reversible at reboot** — RAPL limits, TCC offset, turbo ratios. These reset
  from firmware every boot. Worst case is a hard power cycle.
- **Reversible but destabilising** — OC mailbox voltage offsets. A bad undervolt
  hangs the machine or corrupts data silently under load. Test with the machine
  idle and nothing important open. **Demonstrated:** −140 mV on core and cache
  hung this machine hard, no log, unclean unmount — see
  [−140 mV: the hang](#140-mv-the-hang).
- **Not reliably reversible** — EC RAM writes (`ec_sys write_support=1`). Some
  ThinkPad EC offsets do not come back without a full power drain, battery
  disconnect included, and a few not at all. EFI variable writes can leave the
  firmware unable to boot.
- **Bricking** — SPI flash. Needs external recovery hardware when it goes wrong.

The ordering that keeps a mistake cheap: read, document, change one thing,
observe, reboot to confirm it resets, and only then automate it.

**One instrument costs a reboot per use.** `odvp0` is a one-way latch: anything
that invokes `DYTC` sets it to 7 and only a reboot clears it. That includes
forcing DPTF *and* the wild claw-back itself, so a hunt that needs odvp0 must
budget one fresh boot per attempt and confirm `odvp0 = 0` before arming. It reads
7 on this machine from the resume capture of 2026-09-08 and will until the next
boot. Question 2 being answered does not make the witness reusable within a boot.

## Open questions

1. ~~Does the claw-back move the MSR copy too, or only MMIO?~~ **Answered
   2026-09-08 — MMIO only.** A revert fired during a PL1 run that was sampling
   `MSR_PKG_POWER_LIMIT` every 5 s. MMIO PL1 went 12 W → 15 W between t=5 s and
   t=10 s, and the MSR copy read 25.00 W in every sample, before and after. So
   whatever does this writes the BAR specifically and leaves the MSR copy
   alone, which narrows the mechanism as hoped. Precisely: the MSR reading and
   the MMIO move are logged; the TCC offset moving 4 → 30 in the same window is
   inferred from that run's thermal signature (pinned at 70 C, `0x64F` bit 1)
   and the next run's header, since that run did not yet sample TCC per row.
   Simultaneity is independently established by the wild capture above, which
   logged both 39 ms apart — but that one did not sample the MSR copy, and this
   one did. Two caveats: the MSR was read on cpu0 only, and this is a single
   capture. It is also the first revert caught **on AC** — every prior one was
   on battery — so AC is not immune.
2. ~~Does `odvp0` move at the revert?~~ **Answered 2026-09-08 — yes, 0 → 7.**
   Caught on a resume revert witnessed at 1 Hz from a fresh boot with odvp0
   confirmed at 0, with every repairer removed first. TCC 4 → 30, MMIO PL1
   22 W → 15 W and odvp0 0 → 7 all in the first post-resume sample. The cost of
   the answer is that it also **removes odvp0 as a discriminator**: it is set by
   the wild path as well as by forced DPTF, so it cannot separate them, and the
   TCC 3-vs-30 difference in question 5 now stands unaided. See "Resume reverts
   both registers" above.
3. **Is DYTC invoked during load?** **No, across eight trials (2026-09-08)** —
   eight cold-start 120 s load runs from odvp0=0 all ended at odvp0=0, at up to
   33.6 W and 92 C. Firmware did invoke it **at resume**, where odvp0 went 0 → 7
   in the same sample as the register revert. So the answer is "not under load,
   yes across a sleep", on three resume captures that started from `odvp0 = 0`
   (the battery arm, and AC runs 1 and 3) against eight load runs. What remains
   open is whether a load-triggered revert — the rarer event these eight did not
   catch — also moves it; odvp0 cannot be reused for that within this boot, since
   the latch is now spent until a reboot.
4. ~~What is in `data_vault`?~~ **Answered** — decoded above; `fwmap.sh` unpacks
   it on every run.
5. **Why does forced DPTF land TCC at 3 when the wild claw-back lands it at 30?**
   Same register, same subsystem, different value. Until that is explained the
   DPTF path is a strong candidate rather than the identified cause.
5b. ~~Why does the PL1 clamp need a second enable cycle?~~ **Withdrawn
   2026-09-08 — it does not.** The clamp lands within 1 s of the *disable*
   (`DYTC(0x01FF)`), not on any enable. The question was an artifact of sampling
   only after each enable. See the correction under "DPTF writes these
   registers" above.
6. **What enables DPTF in the wild?** **Narrowed 2026-09-08 — nothing does, and
   it does not need to.** Across the resume revert `thermal_zone1/mode` stayed
   `disabled` and `current_uuid` stayed `INVALID` while odvp0 went 0 → 7 and both
   registers moved. Firmware changes its own policy variable and writes the
   registers without the OS-visible zone ever coming up, so the thing to look for
   is not firmware enabling the zone Linux can see.
7. ~~Which path enforces the DC budget?~~ **Answered — there is no DC budget.**
   The 12-15 W battery ceiling was `power-profiles-daemon` setting EPP to
   `balance_power`. With EPP at `performance` and PL1 held at 22 W, the machine
   sustains 21.9 W on battery. The `_DC` rows in the policy table cap what DPTF
   would apply if it ran; nothing was applying them.
8. **What triggers the claw-back?** Still open for the *load* case, but **resume
   is now a reproduced trigger** — a controlled, idle, `--no-load` suspend with
   every repairer removed reverted both registers on the first post-resume
   sample (2026-09-08), the second resume revert on record and the first
   instrumented one. Three AC resumes fired as well but **partially**: MMIO PL1
   reverted and `odvp0` latched while the TCC offset held at 4, so resume
   triggers on both power sources and the power source decides which registers
   move. The third of those is the clean arm — its own fresh boot, `odvp0 = 0` at
   entry, every precondition held — so the partial-revert finding no longer rests
   on two runs that were each defective in a different way. The cold-fan hypothesis should now be treated as dead
   rather than merely unreproduced: eight cold-start trials with the fan stopped
   at onset, at up to 33.6 W and 92 C — hotter and harder than the run that
   reverted — produced nothing. Battery state, temperature, peak power, fan
   state and an out-of-range (sub-TDP) PL1 write have each been ruled out as
   sufficient. What separates a load run that reverts from the eleven AC and five
   battery runs that do not is still unidentified; resume is the only trigger
   anyone can currently make happen on purpose.
9. **Is there a DC ceiling above 22 W at all?** Untested. PL1 22 W was the
   binding limit in the run that reached 21.9 W, so the question of what the
   pack and the EC allow above that is unprobed.
10. ~~Why does the package sustain 24.87 W with MMIO PL1 set to 22 W?~~
   **Answered 2026-09-08 — it does not.** It was a run-length artifact: the first
   ~33 s of any run from idle is PL2-limited at 29 W, so a 90 s arithmetic mean
   necessarily overshoots PL1. A 300 s run at the same setting gives a 90 s
   prefix mean of 24.61 W against the original's 24.87 W, and a tail of 21.98 W.
   Steady state tracks the MMIO copy at 12, 18 and 22 W while the MSR copy stays
   at 25 W, so `min(MSR, MMIO)` holds and `power-unlock` is built on solid
   ground. See "Which PL1 copy binds — measured" above. The premise that made
   this a question — "90 s is longer than the 28 s window, so not a transient" —
   was the actual error.
11. **Why did the first AC run report 16 SMIs and 16 `CoreThr` events when every
   battery run reported zero of both?** Only the first run after plugging in.
   Charging is the obvious difference, and the SMI counter is the instrument the
   claw-back hunt is counting on, so what raises it here is worth knowing.
   **Instrument caveat added 2026-09-08:** `MSR_SMI_COUNT` **resets across S3**.
   It read 3154 before a suspend and restarted after it, so the counter is a
   valid cumulative instrument within a boot and void across a sleep — a resume
   capture cannot use it at all.
