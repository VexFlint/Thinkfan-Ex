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
| `MSR 0x150` OC mailbox | Core/cache voltage offsets | `/dev/cpu/*/msr` | No | **High** — instability, silent corruption |
| `MSR 0x1FC` POWER_CTL | C1E, energy-efficient turbo | `/dev/cpu/*/msr` | No | Low |
| DPTF `INT3400` | Thermal policy, `odvp*` state | platform sysfs | policy `INVALID` | Low to read |
| DPTF `data_vault` | OEM thermal policy blob (2263 B) | sysfs, read-only | n/a | Read-only |
| ACPI `DYTC` | Lenovo Intelligent Cooling modes | AML, via EC HKEY | n/a | **High** — invokes firmware |
| EC RAM | Fan, battery, thermal, charge | `ec_sys` debugfs | read-only as loaded | **Very high** on write |
| `thinkpad_acpi` | Fan, LEDs, hotkeys, thermal | `/proc/acpi/ibm/*` | no | Low to medium |
| ACPI `_Qxx` (48 handlers) | EC event hooks | AML only | n/a | Read-only here |
| ACPI-WMI (18 devices) | Lenovo config interfaces | `/sys/bus/wmi` | n/a | Unmapped |
| EFI variables (158, 21 Lenovo) | BIOS setup, hidden settings | `efivarfs` | some RO | **Very high** on write |
| SPI flash | BIOS/EC image | needs `flashrom` | n/a | **Bricking** |

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

## Embedded controller

256 bytes via `ec_sys`, loaded read-only. Offset `0xF0` carries the EC firmware
string (`N24HT37W`). `thinkpad_acpi` exposes the civilised subset at
`/proc/acpi/ibm/` — `fan`, `thermal`, `led`, `hotkey`, `cmos`, `lcdshadow`.

48 `_Qxx` EC query handlers exist. Only `_Q26` and `_Q27` touch anything
power-related, and only `PWRS` (the AC-present flag) — these are the AC
plug/unplug hooks. **No `_Qxx` handler writes power limits**, which rules out
the EC event path as the claw-back mechanism.

## Not mapped, for lack of tools

Absent on this system: `flashrom`, `ectool`, `nvramtool`, `msr-tools`,
`turbostat`, `powertop`. So SPI flash imaging and the EC command interface are
unexplored — not because they are uninteresting, but because nothing here can
reach them yet. The MSR path works regardless via `/dev/cpu/*/msr`.

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
4. **What is in `data_vault`?** 2263 bytes of OEM thermal policy, undecoded.
