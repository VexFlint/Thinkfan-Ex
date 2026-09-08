# This machine, verified

Ground truth for the ThinkPad this repo is developed on. Every value here was
**read from the machine**, not from a spec sheet, a forum post or memory. It
exists so that basic facts stop being guessed at.

Commands are included for every section so any claim can be re-checked in
seconds, and so the file can be regenerated on a different T480 without
inheriting this one's answers.

> [!IMPORTANT]
> **Read [Hazards](#hazards) before changing any firmware setting.** One setting
> reachable from Linux on this exact model can permanently destroy the board.

## Contents

| | |
|---|---|
| [Identity](#identity) | Model, firmware, OS |
| [Hazards](#hazards) | **The things that can destroy the board, and the live gotchas** |
| [CPU](#cpu) | Including the numbers the undervolt work depends on |
| [Memory, storage, graphics](#memory-storage-graphics) | |
| [Thunderbolt and USB-C](#thunderbolt-and-usb-c) | It *has* Thunderbolt 3 |
| [Power and thermal](#power-and-thermal) | Batteries, fan, sensors |
| [Firmware surfaces](#firmware-surfaces) | What is reachable, and from where |
| [Corrections](#corrections) | Things this repo got wrong and fixed |

## Identity

| | | source |
|---|---|---|
| Model | **ThinkPad T480**, type **20L6** | `dmidecode -s system-product-name` |
| Machine type | `20L6SE7N00` | `dmidecode -s system-version` |
| UEFI BIOS | **N24ET79W (1.54)**, 2025-03-17 | `dmidecode -t bios` |
| EC firmware | **1.22** (`N24HT37W`) | `dmidecode`, EC offset `0xF0` |
| Chipset | Intel Sunrise Point-LP (`8086:9d4e`) | `lspci -nn` |
| TPM | present, **version 2** | `/sys/class/tpm/tpm0/tpm_version_major` |
| OS | CachyOS, kernel `7.2.2-1-cachyos` | `uname -r`, `/etc/os-release` |
| CPU microcode | `0xf6` | `/proc/cpuinfo` |

Lenovo's BIOS packages for this model are `n24uj<NN>w.exe`, and the build number
is *not* the version:

| package | BIOS version |
|---|---|
| `n24uj40w.exe` | 1.53 |
| **`n24uj41w.exe`** | **1.54 — matches this machine** |
| `n24uj42w.exe` | 1.55 |
| `n24uj43w.exe` | 1.56 |

Readmes: `https://download.lenovo.com/pccbbs/mobiles/n24ur<NN>w.html`.

## Hazards

### Thunderbolt BIOS Assist can permanently brick this board

Enabling **"Thunderbolt BIOS Assist"** hangs affected ThinkPads at the next
reboot with a black screen and a corrupted UEFI. The documented fix is a
**motherboard replacement**.

**The T480 (20L5/20L6) is on the affected list**, and the setting is present on
this machine, exposed by `think-lmi`, and writable from Linux:

```
$ cat /sys/class/firmware-attributes/thinklmi/attributes/ThunderboltBIOSAssistMode/current_value
Disable          # <- leave it exactly here
```

| attribute | current | possible |
|---|---|---|
| **`ThunderboltBIOSAssistMode`** | **`Disable`** | `Enable;Disable` ← **do not set `Enable`** |
| `ThunderboltAccess` | `Enable` | `Disable;Enable` |
| `ThunderboltSecurityLevel` | `NoSecurity` | `NoSecurity;UserAuthorization;SecureConnect;DisplayPortandUSB` |
| `PreBootForThunderboltDevice` | `Enable` | `Disable;Enable;Pre-BootACL` |
| `WakeByThunderbolt` | `Disable` | `Disable;Enable` |

Sources: [Notebookcheck](https://www.notebookcheck.net/Some-recent-ThinkPads-can-be-destroyed-by-changing-a-UEFI-BIOS-setting.346156.0.html),
[repair follow-up](https://www.notebookcheck.net/ThinkPad-UEFI-failure-Experienced-users-can-repair-their-laptops-with-some-effort.346806.0.html).

### Thunderbolt security is off, DMA is mitigated only by VT-d

`ThunderboltSecurityLevel` is `NoSecurity` and the kernel agrees
(`/sys/bus/thunderbolt/devices/domain0/security` → `none`). Any Thunderbolt
device that is plugged in is authorised automatically. The saving grace is that
**VT-d is enabled** (`SaSetup 0xE3` = 1), so the IOMMU is between a hostile
device and memory. That is a mitigation, not a policy — if this machine ever
travels somewhere untrusted, raise the security level first.

### A removed NVMe leaves a stale device that blocks suspend — *cleared*

> [!NOTE]
> **Resolved by the reboot at 2026-09-08 13:45.** Kept in full because the
> failure recurs every time the M.2 drive is pulled from a running system, and
> because the evidence it leaves behind is misreadable in two separate ways.

The `WD_BLACK SN770M 1TB` in the M.2 slot was **physically removed by the owner
while the system was running** (2026-09-08 12:24). M.2 NVMe is not hot-pluggable
here, so the kernel does not notice the slot is empty — it keeps a stale device
and marks it `dead` after the reset fails:

```
nvme 0000:02:00.0: Unable to change power state from D3hot to D0, device inaccessible
nvme nvme0: Disabling device after reset failure: -19
$ cat /sys/class/nvme/nvme0/state
dead
```

`lspci` still enumerates `15b7:5042` and `lsblk` still lists `nvme0n1` at 0 B,
both stale. **The practical consequence is that suspend now fails**, repeatedly:

```
nvme 0000:02:00.0: PM: pci_pm_suspend(): nvme_suspend returns -16
nvme 0000:02:00.0: PM: failed to suspend async: error -16
```

**A reboot cleared all of it**, as predicted. Nothing was broken and no drive
was lost. After the boot at 13:45 the M.2 slot is simply empty — the device is
gone from sysfs and from the PCI bus, not merely marked dead:

```
$ ls /sys/class/nvme/         # ls: cannot access: No such file or directory
$ lspci -nn | grep -i 15b7    # (no output)
$ who -b                      # system boot  2026-09-08 13:45
```

**Suspend was then re-tested and works**, 13:58:10 → 13:58:27, deep S3, no
device failed and nothing needed a second attempt:

```
PM: suspend entry (deep)
PM: suspend exit          # and no "Some devices failed to suspend" between them
```

> **Lesson one, on reading the logs.** Read cold and in the wrong direction,
> these lines look exactly like a drive failing on its own, and this file
> briefly said so. `dmesg -T` gave the wall-clock time and the owner gave the
> cause. **Relative dmesg timestamps are easy to convert wrongly — use
> `dmesg -T`.**

> **Lesson two, on reading the resume probe.** `uv-resume-probe` records the OC
> mailbox on every wake from `suspend.target`, precisely so that *the offset
> survived S3* can be told apart from *the offset was restored for us*. A
> suspend that **aborts** still fires that target, so the probe still runs — and
> writes a row showing the offset intact, because the core rail never lost
> power. Two such rows are in the log, and they read like survival:
>
> ```
> 2026-09-07 12:34:33  core=+0.00   cache=+0.00     <- real S3, 8h59m asleep
> 2026-09-08 12:24:31  core=+0.00   cache=+0.00     <- real S3, 23h49m asleep
> 2026-09-08 13:16:42  core=-99.61  cache=-99.61    <- suspend ABORTED by nvme
> 2026-09-08 13:41:27  core=-99.61  cache=-99.61    <- suspend ABORTED by nvme
> 2026-09-08 13:58:27  core=+0.00   cache=+0.00     <- real S3, 17s, post-fix control
> ```
>
> They are not survival; they are a suspend that never happened. **Pair every
> row of `/var/log/uvsoak/resume-probe.log` with a `PM: suspend exit` that is
> *not* preceded by `PM: Some devices failed to suspend`** before believing it:
>
> ```bash
> journalctl -b -1 -k | grep -E 'PM: suspend (entry|exit)|failed to suspend'
> ```
>
> The finding itself is unaffected — **suspend wipes the mailbox** still rests
> on the `+0.00` rows from every suspend that actually completed, including the
> deliberate 17-second control run after the reboot. That last row is the useful
> one: it shows the wipe does not need a long sleep. **17 seconds in S3 is
> enough to clear the mailbox**, so the re-apply is not an optimisation for long
> suspends, it is required for all of them.

### The two risk tiers this repo works in

| tier | example | recovery |
|---|---|---|
| reversible | `MSR 0x150` voltage offsets, PL1, TCC | a reboot clears it |
| **not reversible here** | EFI setup variables, EC RAM writes, SPI flash | needs an external programmer this machine does not have |

`BIOS Lock` is **enabled** (`PchSetup 0x17` = 1), which is *why* software
flashing fails and why the reflash route needs a CH341A and a clip.

## CPU

| | | source |
|---|---|---|
| Model | **Intel Core i7-8650U** (Kaby Lake-R) | `lscpu` |
| Topology | 4 cores / 8 threads | `lscpu` |
| Base ratio | **21 → 2100 MHz** | `MSR 0xCE` bits 15:8 |
| TSC frequency | **2100 MHz** (kernel: `Detected 2099.944 MHz TSC`) | `dmesg` |
| Turbo ratios | **42 / 42 / 39 / 39** for 1/2/3/4 active cores | `turbostat` |
| Max / min freq | 4200 / 400 MHz | `lscpu` |
| Cache | L1d 128 K, L2 1 M, L3 **8 M** | `lscpu` |
| TjMax | **100 °C** | `MSR 0x1A2` bits 23:16 |
| TCC offset | **4** → throttles at 96 °C | `MSR 0x1A2` bits 29:24 |

> **The base ratio is 21, not 19.** The marketing base clock of an i7-8650U is
> 1.9 GHz, but `PLATFORM_INFO` reports 21 and the kernel measures the TSC at
> 2099.944 MHz. **2100 is the correct multiplier for `Bzy_MHz = base × APERF/MPERF`**,
> and every clock figure in `FIRMWARE.md` derives from it. Do not "fix" it to 1900.

### Voltage planes

`MSR 0x150`, the OC mailbox, is **unlocked and writable** despite microcode
`0xf6` carrying the Plundervolt mitigation. Five planes: core, iGPU, cache,
system agent, analog I/O.

**Core and cache share a rail**, and the delivered voltage follows the *higher*
of the two requests — so they must always move together. Full evidence in
[`FIRMWARE.md`](FIRMWARE.md).

| offset | standing |
|---|---|
| **−100 mV** | validated: 179,660 verified answers over 2 h AC + 45 min battery |
| −120 mV | one unexplained display artifact, never reproduced — not attestable |
| −140 mV | hard hang, frozen with the display lit |

Currently applied persistently at **−99.61 mV** on core and cache via
`intel-undervolt`. **Suspend wipes the mailbox** — the offset is restored on
resume by a unit, not preserved by hardware.

## Memory, storage, graphics

| | |
|---|---|
| RAM | **16 GB** — 2 × 8 GB Samsung `M471A1K43DB1-CTD`, DDR4-2400, 1 rank each, dual channel (`ChannelA-DIMM0`, `ChannelB-DIMM0`) |
| Boot disk | **Crucial MX500 250 GB** SATA (`/dev/sda`), btrfs on `sda2` |
| NVMe | M.2 slot **empty** — `WD_BLACK SN770M 1TB` removed 2026-09-08; clean since the 13:45 reboot, see [Hazards](#hazards) |
| Card reader | `sdb`, Generic SD/MMC over USB — reads **0 B** with no card inserted, which is normal and not a fault |
| iGPU | Intel UHD Graphics 620, Kaby Lake-R GT2 (`8086:5917`) |
| dGPU | **NVIDIA GeForce MX150** (`10de:1d10`, GP108M) |
| Panel | 1920×1080 eDP |
| Audio | Sunrise Point-LP HD Audio (`8086:9d71`) |
| Ethernet | Intel I219-LM (`8086:15d7`) |
| Wi-Fi | Intel Wireless 8265 / 8275 (`8086:24fd`) |

> The MX150's VBIOS exposes **no power management object**, so `nvidia-smi`
> reports `N/A` for `power.draw` permanently. Only temperature and the hardware
> slowdown flags are readable — see `burnboth.sh`.

## Thunderbolt and USB-C

**This machine has Thunderbolt 3.** Stating it plainly because this repo
previously assumed otherwise and was wrong.

| | |
|---|---|
| Controller | **Intel JHL6240 Thunderbolt 3, Alpine Ridge LP (2016)** |
| PCI IDs | bridges `8086:15c0`, NHI `8086:15bf`, USB 3.1 `8086:15c1` |
| NVM version | 23.0 |
| Domain security | `none` — see [Hazards](#hazards) |
| USB-C ports | 2 (`/sys/class/typec/port0`, `port1`), both sink/device capable |

```bash
lspci -nn | grep -i thunderbolt
cat /sys/bus/thunderbolt/devices/domain0/security
```

## Power and thermal

| | | source |
|---|---|---|
| BAT0 (internal) | design 22.80 Wh, now **22.23 Wh**, 6 cycles, `01AV421` | `/sys/class/power_supply/BAT0` |
| BAT1 (external) | design 48.84 Wh, now **49.45 Wh**, 14 cycles, `01AV425` | `/sys/class/power_supply/BAT1` |
| Total | **~71.7 Wh** | |
| Discharge order | **BAT1 first**, so BAT0 reads 100 % for the first hour | measured during a battery soak |
| Whole-machine wattmeter | `power_now`, **only readable on battery** — reads 0 on AC | |
| Fan | single fan, `thinkpad_acpi`, levels 0-7 + `auto`/`disengaged`/`full-speed` | `/proc/acpi/ibm/fan` |
| MSR PL1 | 25 W | `MSR 0x610` |
| MMIO PL1 | **22 W when applied — firmware claws it back to 15 W** | `intel-rapl-mmio:0` |

Thermal zones: `acpitz`, `INT3400`, `SEN1`, `pch_skylake`, `B0D4`, `iwlwifi_1`,
`x86_pkg_temp`.

`thinkpad_acpi` exposes: `beep bluetooth cmos driver fan hotkey lcdshadow led
light thermal volume`. **`platform_profile` never registers**, so DYTC has no
sysfs entry point on this machine.

## Firmware surfaces

| surface | reach | notes |
|---|---|---|
| `MSR 0x150` OC mailbox | read/write | unlocked; the undervolt path |
| `MSR 0x610` / RAPL MMIO | read/write | PL1; MMIO copy is the binding one |
| `MSR 0x1A2` | read/write | TjMax and TCC offset |
| `think-lmi` | **79 attributes**, read/write | the *visible* BIOS settings, incl. the Thunderbolt hazard |
| EFI setup variables | present, `NV,BS,RT` | `Setup` 1515 B, `CpuSetup` 774 B, `SaSetup` 780 B, `PchSetup` 1887 B, `SetupCpuFeatures` 41 B — **`MeSetup` absent** |
| Intel Advanced Menu (IFR) | decoded, not written | 2,809 settings, 124 forms, 2,123 suppressed — see [`BIOS-MOD.md`](BIOS-MOD.md) |
| EC RAM | read-only (`ec_sys`) | 256 bytes; writes are the highest-risk tier |
| SPI flash | **not reachable** | `BIOS Lock` enabled; needs an external programmer |

```bash
ls /sys/class/firmware-attributes/thinklmi/attributes/ | wc -l   # 79
ls /sys/firmware/efi/efivars/ | wc -l                            # 159
```

## Corrections

Kept deliberately, because each one was a confident wrong answer:

| claim | reality |
|---|---|
| "The T480 has no Thunderbolt and is not affected by the bricking bug" | **Wrong on both counts.** It has JHL6240 TB3, and the T480 20L5/20L6 is on the affected list. The claim came from an article's general statement instead of from this machine |
| "This is an i5-8250U" | It is an **i7-8650U** |
| "`LenovoHiddenSetting` may gate the hidden menu" | **Refuted** — it appears nowhere in the setup forms |
| "The returns from undervolting are flattening" | True for fixed-clock power, false for fixed-power clock, which is the metric that matters |
| "The battery clamp is firmware/DPTF" | It was **EPP**, one layer above |
| "The ring/LLC at −120 mV explains the display artifact" | Failed to reproduce at 3× exposure |

The pattern in every row is the same: a claim taken from something other than
this machine. **Check the machine.**
