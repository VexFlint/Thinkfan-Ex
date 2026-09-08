# Hidden BIOS settings on a ThinkPad T480

What "hidden BIOS settings" actually are on this machine, what is reachable from
a booted Linux, what the public research does and does not establish, and what it
would cost to go further.

**Nothing in this file has been written to the machine.** Every value below was
read, including the firmware image, which was unpacked and decoded offline. The
one write this repo has ever made to firmware settings went through
`think-lmi`, is documented in [`FIRMWARE.md`](FIRMWARE.md), and is not what this
file is about.

> [!CAUTION]
> This is the highest-risk surface the repo touches, and the risk is not
> symmetrical with the rest of it. A bad fan curve makes noise. A bad undervolt
> hangs the machine and a reboot clears it. **A bad firmware variable or a bad
> flash can leave a board that does not POST**, and there is no external
> programmer on hand here to recover one. Read to the end before writing a byte.

## Contents

| | |
|---|---|
| [The distinction that matters](#the-distinction-that-matters) | Hiding the menu and storing the value are different things |
| [What is on this machine](#what-is-on-this-machine) | Measured: variables, sizes, attributes |
| [`LenovoHiddenSetting`](#lenovohiddensetting) | A named lead, and why it is not a recipe |
| [What the public research establishes](#what-the-public-research-establishes) | And what it only claims |
| [The two routes](#the-two-routes) | Writing the variable, or reflashing the image |
| [The IFR dump](#the-ifr-dump-done) | **Done.** What the firmware actually contains |
| [What it found](#what-it-found) | The Intel Advanced Menu, with offsets |
| [What else is hidden](#what-else-is-hidden) | The other 2,700 settings, and which are reachable |
| [Is any of this worth wanting?](#is-any-of-this-worth-wanting) | The honest answer for this repo's purposes |

## The distinction that matters

A "hidden" setting is two separate things, and conflating them is what sends
people to a SPI programmer they did not need.

1. **The menu entry** is hidden by `suppressif` or `grayoutif` in the firmware's
   setup forms (the IFR). The BIOS simply never draws it. Removing that requires
   modifying the firmware image and flashing it back.
2. **The value** the entry controls lives in an EFI variable — `Setup`,
   `CpuSetup`, and friends. It is a byte at an offset. Changing it does not
   require the menu to exist, or the firmware to be modified at all.

**You almost never want the menu. You want the value.** Route 2 is the one worth
understanding first, and on this machine it is open.

## What is on this machine

159 EFI variables are present. `think-lmi` exposes 79 BIOS settings as a
supported kernel interface, documented in [`FIRMWARE.md`](FIRMWARE.md) — those
are the *visible* ones and they need none of this. The setup stores behind the
menu are these:

| variable | data size | attributes | |
|---|---|---|---|
| `Setup` | 1515 B | NV, BS, **RT** | the main store; IFR offsets index into this |
| `CpuSetup` | 774 B | NV, BS, **RT** | CPU settings, where CFG Lock lives |
| `LenovoConfig` | 245 B | NV, BS, **RT** | |
| `LenovoFunctionConfig` | — | — | present, unread |
| `SetupCpuFeatures` | 41 B | NV, BS, **RT** | |
| `CpuSetupVolatileData` | — | — | present, unread |
| `LenovoHiddenSetting` | 34 B, **all zeros** | NV, BS, **RT** | see below |

Sizes are the data, with efivarfs's four-byte attribute prefix subtracted.

```bash
# how the above was read - all of it non-destructive
ls /sys/firmware/efi/efivars/ | wc -l
sudo head -c4 /sys/firmware/efi/efivars/Setup-ec87d643-eba4-4bb5-a1e5-3f3e36b20da9 | od -An -tu4
sudo hexdump -C /sys/firmware/efi/efivars/LenovoHiddenSetting-1827cfc7-4e61-4273-b796-d35f4b0c88fc
```

**Every one carries `RT` — runtime access.** That is the finding that decides
which routes are available: these are writable from a booted Linux, not only
from a UEFI shell before the OS starts. Linux additionally sets an immutable
flag on efivarfs entries as a guard:

```
$ sudo lsattr /sys/firmware/efi/efivars/Setup-ec87d643-...
----i----------------- Setup-ec87d643-...
```

`chattr -i` clears it. That guard is the only thing standing between a stray
`dd` and the setup store, which is worth sitting with for a moment.

## `LenovoHiddenSetting`

The variable exists, it is 34 bytes, and **every byte is zero**.

The only substantive public discussion is a
[bios-mods thread about a ThinkPad Edge E145](https://www.bios-mods.com/forum/Thread-Unlock-hidden-menus-on-Thinkpad-Edge-E145),
where modders hypothesised it is a bitfield gating hidden tabs — *"0x22 may be
the container of value to enable or disable Hidden Tabs, Bios just checking the
value (some bits elevated) example 0xFF = 11111111 (bits setted) and Bios can
show the Hidden Tabs."*

**That thread produced no working method.** It ends with the modders declining
the job: the UEFI image was beyond what they could disassemble, and the brick
risk was not worth it. Nobody in it demonstrated the variable doing anything.

~~So the honest statement: a variable with a promising name holds 34 zero bytes
on this machine, which is consistent with a disabled bitfield and equally
consistent with a vestigial store the firmware never reads.~~

**Settled by the IFR dump: it is not the gate.** `LenovoHiddenSetting` appears
**nowhere** in the Setup module's forms — not as a varstore, not as a GUID, not
once in 21 626 lines. Its GUID occurs only in `LenovoVariableInitDxe`,
`SystemSmbiosLoaderDxe` and `EcIoDxe`, which initialise variables and have
nothing to do with the setup browser. **Whatever this variable is for, it does
not hide or reveal the menu**, and the E145 hypothesis does not carry to this
model. Writing `0xFF` into it would have accomplished nothing, at the risk of
the firmware that decides whether this laptop turns on.

## What the public research establishes

| claim | status |
|---|---|
| Hidden entries are suppressed in the IFR, values live in EFI variables | **Established.** This is how UEFI setup works, and the [UEFI Lessons material](https://github.com/Kostr/UEFI-Lessons/blob/master/Lessons_uncategorized/Lesson_Hidden_BIOS_settings) documents the mechanism directly |
| Settings can be changed without flashing, by writing the variable | **Established** as a general technique — [bios-mods how-to](https://www.bios-mods.com/forum/Thread-HOW-TO-Change-hidden-BIOS-settings-without-unlock-request-and-without-flashing), [SlimIFR + UefiVarTool](https://github.com/GeographicCone/SlimIFR) |
| A T480-specific guide exists for unlocking the hidden menu | **Dead link.** The widely-cited "Thinkpad T480 unlock BIOS hidden menu + modify whitelist + cfg lock" is hosted on `programming.vip`, which no longer resolves |
| T480 CFG Lock sits at `VarOffset 0x3C`, `VarStore 0x3` | **Confirmed** against this machine's own firmware — see below. The [poster](https://github.com/taina0407/T480-OpenCore-Hackintosh/issues/4) had not tested it; the IFR dump says they were right |
| `LenovoHiddenSetting` unhides menus when its bits are set | **Refuted here.** The variable is referenced by no setup form in this firmware |
| Some ThinkPads brick permanently from one UEFI setting | **Established, and it DOES apply here.** ~~The T480 has no Thunderbolt and is not affected~~ — **wrong, corrected 2026-09-08.** This machine has a JHL6240 Thunderbolt 3 controller, the T480 20L5/20L6 is on the affected list, and `ThunderboltBIOSAssistMode` is exposed by `think-lmi` and writable from Linux. See [`MACHINE.md`](MACHINE.md#hazards) |

> [!CAUTION]
> **The last row was written the wrong way round and stood for two days.** It
> said the board-killing landmine was not in this machine's path. It is: the
> T480 has Thunderbolt 3 (`JHL6240`, verified on the PCI bus), the 20L5/20L6 is
> on the affected list, and `ThunderboltBIOSAssistMode` is not even hidden — it
> sits in `think-lmi` alongside the 79 ordinary settings, one `echo` away.
> It currently reads `Disable`. **Leave it there.**
>
> The error came from generalising an article's sentence about cheaper
> Thunderbolt-less ThinkPads instead of running `lspci`. Full verified inventory
> is now in [`MACHINE.md`](MACHINE.md), which exists so this class of mistake
> stops happening.

## The two routes

| | write the variable | reflash a modified image |
|---|---|---|
| **gets you** | the setting changed | the menu entry visible |
| **needs** | `chattr -i` and a byte at a known offset, or `RU.efi` at boot | dump SPI, patch the IFR, flash back |
| **tools** | UEFITool + IFRExtractor to *find* the offset; then `dd` or UefiVarTool | UEFITool, plus realistically a CH341A and a SOIC8 clip — the BIOS region is protected against software flashing |
| **if it goes wrong** | a firmware that will not POST, recoverable only by flashing the chip externally | a dead board until reflashed externally |
| **reversible from the OS?** | no | no |

Both failure modes end in the same place: needing hardware this machine does not
have. That is the reason neither has been attempted here, and it is a better
reason than squeamishness.

## The IFR dump (done)

Done on 2026-09-08, and it writes nothing to the machine. The vendor ships the
firmware image; everything after that is offline analysis.

The package had to match the *running* firmware, because IFR offsets are
version-specific. `dmidecode` reports `N24ET79W (1.54)`, and Lenovo's readmes
map build numbers to versions:

| package | BIOS version |
|---|---|
| `n24uj40w.exe` | 1.53 |
| **`n24uj41w.exe`** | **1.54 — the match** |
| `n24uj42w.exe` | 1.55 |
| `n24uj43w.exe` | 1.56 |

`innoextract` unpacks it to `N24ET79W/$0AN2400.FL1` — 9,455,008 bytes, and the
directory name is the BIOS ID itself. `uefiextract` unpacks that to 8,733 files,
and the module list names a DXE driver called plainly **`Setup`**
(`E6A7A1CE-5881-4B49-80BE-69C91811685C`, 552 KB). `ifrextractor` turns its forms
into 21,626 readable lines.

Reproduction steps are in [`FIRMWARES/README.md`](FIRMWARES/README.md); the
curated result is [`FIRMWARES/advanced-menu-digest.txt`](FIRMWARES/advanced-menu-digest.txt).

**The offsets are trustworthy, and that is checked rather than assumed.** The
IFR declares each varstore's size, and those match the live EFI variables on
this machine exactly:

| varstore | IFR declares | live variable |
|---|---|---|
| `Setup` | `0x5EB` = 1515 | **1515 B** |
| `CpuSetup` | `0x306` = 774 | **774 B** |
| `SetupCpuFeatures` | `0x29` = 41 | **41 B** |

Three for three. This is the right firmware for this machine.

## What it found

**The formset is titled "Intel Advanced Menu".** It is the Intel reference
setup, compiled into the shipping firmware, carrying **1,727 `OneOf` and 1,147
`Numeric` settings across 146 forms** — with **791 `SuppressIf` blocks** doing
the hiding. Lenovo's own menu (`LenovoSetupMainDxe` and friends) is a separate,
much smaller UI that never offers a path to it.

The settings this repo has spent the week reaching through MSRs are all in
there, by name:

| setting | varstore | offset | live value |
|---|---|---|---|
| **Voltage Offset** (IA Core) | `CpuSetup` | `0x1B2`, 16-bit | **0** |
| Offset Prefix (sign) | `CpuSetup` | `0x1B4` | 0 |
| Voltage Mode (adaptive/override) | `CpuSetup` | `0x1AF` | 0 |
| **CFG Lock** | `CpuSetup` | `0x3C` | **1** (locked) |
| **Overclocking Lock** | `CpuSetup` | `0xEB` | **0** (unlocked) |
| Tcc Activation Offset | `CpuSetup` | `0x7B` | — |
| Power Limit 1 / Override | `CpuSetup` | `0x10` / `0x14` | — |
| Uncore Voltage Offset | `SaSetup` | `0x1AC` | — |
| GT Voltage Offset | `SaSetup` | `0x1B4` | — |
| Disable PROCHOT# Output | `CpuSetup` | `0x77` | — |

The help text on the voltage entries is the punchline:

> *"Specifies the Offset Voltage applied to the IA Core domain. This voltage is
> specified in millivolts. **Uses Mailbox MSR 0x150, cmd 0x11.** Range −500 to
> 500 mV"*

**That is the same mailbox, the same command, that `uvsoak` and
`intel-undervolt` drive.** The firmware has a full UI for the exact mechanism
this repo qualified from Linux — it is simply never drawn.

Two useful corroborations fell out. The community's untested claim that T480 CFG
Lock lives at `VarOffset 0x3C` in varstore `0x3` is **correct** — varstore `0x3`
is `CpuSetup`, and the live byte reads `1`, exactly as a locked machine should.
And every value read back is coherent with a stock machine: offsets zero, CFG
Lock set, OC Lock clear.

> **What this does *not* establish** is that writing those bytes does anything.
> The forms exist; whether Lenovo's build actually runs the Intel reference code
> that consumes them at boot is untested and untestable without writing. A
> populated form is evidence the setting was compiled in, not evidence it is
> wired up.

## What else is hidden

The power settings are a small corner of it. **2,809 settings across 124 forms,
of which 2,123 sit inside a `SuppressIf` or `GrayOutIf` block** — the full
inventory is in [`FIRMWARES/form-inventory.txt`](FIRMWARES/form-inventory.txt),
the annotated pick in
[`FIRMWARES/notable-settings.txt`](FIRMWARES/notable-settings.txt).

The largest forms are mostly plumbing nobody wants — 24 identical *PCI Express
Root Port* forms at 36 settings each, *Link options* (168), *SATA And RST*
(97), *Control Logic options* (128). The interesting part is elsewhere.

### Reachability is the first filter

A setting is only writable from Linux if its varstore exists as a live EFI
variable. The IFR distinguishes `VarStoreEfi` from plain `VarStore`, and that
prediction is imperfect, so it was checked against the machine:

| varstore | IFR declares | on this machine |
|---|---|---|
| `Setup` | `0x5EB` | **1515 B** ✓ |
| `CpuSetup` | `0x306` | **774 B** ✓ |
| `SaSetup` | `0x30C` | **780 B** ✓ |
| `PchSetup` | `0x75F` | **1887 B** ✓ |
| `SetupCpuFeatures` | `0x29` | **41 B** ✓ (despite being a plain `VarStore`) |
| `MeSetup` | `0x141` | **absent** — declared `VarStoreEfi`, no variable exists |
| `MeSetupStorage` | — | absent (plain `VarStore`, an internal buffer) |

Four for four on sizes. **2,517 of the 2,601 settings that name a varstore — 96 %
— live in a store that is present and runtime-writable.**

**The 4 % that is not reachable is the most sensitive 4 %.** Everything in
`MeSetup` and `MeSetupStorage` — *ME State*, *Local FW Update*, *Me FW Image
Re-Flash*, *ME Unconfig on RTC Clear*, *TPM 1.2 Deactivate* — has no EFI
variable behind it here. Whatever one thinks about disabling the Management
Engine, **it is not on the table by this route on this machine.**

### What the machine actually reports

Read-only, from the live variables at the offsets the IFR gives:

| setting | varstore + offset | value | reading |
|---|---|---|---|
| Debug Interface | `CpuSetup 0xED` | **0** | CPU debug disabled |
| Debug Interface Lock | `CpuSetup 0xEE` | **1** | and locked — as a production part should be |
| BIOS Lock | `PchSetup 0x17` | **1** | flash write protection on; this is *why* software flashing fails and a programmer is needed |
| Flash Wear Out Protection | `CpuSetup 0xF0` | 0 | |
| VMX Virtualization | `CpuSetup 0xCD` | 1 | on |
| VT-d | `SaSetup 0xE3` | 1 | on |
| DVMT Pre-Allocated | `SaSetup 0xDF` | 1 | |
| DVMT Total Gfx Mem | `SaSetup 0xE0` | 2 | |
| **Acoustic Noise Mitigation** | `CpuSetup 0x1CC` | **1** | **enabled** |
| **Slow Slew Rate for IA Domain** | `CpuSetup 0x1D0` | **3** | slowest setting |
| Maximum Memory Frequency | `SaSetup 0x10F` | 0 | auto |
| SA GV | `SaSetup 0x12B` | 3 | |

The debug rows are quiet good news: this machine's CPU debug interface is off
*and* locked, which is the configuration you want and not one you can take for
granted. `BIOS Lock = 1` independently confirms what the two-routes table above
asserts — the flash is write-protected in hardware policy, so the reflash route
really does need an external programmer.

### The one that is this repo's business

**`Acoustic Noise Mitigation` is enabled, and the IA slew rate is set to its
slowest value.** That is a deliberate trade: the voltage regulator is made to
ramp slowly so the inductors do not sing, at the cost of transient response when
load steps. On a machine whose entire repo is about refusing the acoustics-first
defaults, that is the most on-topic thing in the dump — Lenovo made the same
class of choice in the VR that they made in the fan curve.

It is *not* an action item. It is hidden behind the same unreachable-menu
problem as everything else, the write route is the unrecoverable one, and
nothing here measures what it costs. It is filed as the most interesting lead
the dump produced, and left alone.

### Also present, for the record

*Memory / DRAM*: 71 settings including `tCL`, `tRCD/tRP`, `Maximum Memory
Frequency`, `SA GV`, `Rank Margin Tool` — DRAM timing control on a laptop whose
menu offers none. *Graphics*: `DVMT Pre-Allocated`, `DVMT Total Gfx Mem`, `LCD
Panel Type`, `Panel Color Depth`. *Debug*: `TraceHub Enable Mode`, `JTAG C10
Power`. *Thunderbolt*: a complete 47-setting form — and unlike the
`Realsense 3D Camera` form next to it, this hardware **is** present, so those
settings are live rather than vestigial.

## Is any of this worth wanting?

For this repo's purposes, on current evidence: **no, and it is worth saying so
plainly.**

- **Undervolting does not need it.** `MSR 0x150` is open, unlocked, and
  documented in [`FIRMWARE.md`](FIRMWARE.md). The validated −100 mV setting was
  applied without touching firmware at all.
- **The power limits do not need it.** TCC offset and MMIO PL1 are reachable
  from Linux and already automated.
- **CFG Lock does not matter here.** It gates `MSR 0xE2`, which matters for
  macOS power management. It is not in the way of anything this repo does.
- **The one genuinely unreachable knob** — the SpeedStep *Mode for AC* /
  *Mode for Battery* submenu that `think-lmi` does not carry — is already
  visible in the ordinary setup menu, and was set by hand there.

~~So the state of play is: the door is identifiable, the lock is understood in
general, no one has published a key for this model, and nothing this repo wants
is on the other side. That may change if the IFR dump turns up something real.~~

**The dump did turn up something real, and the answer stays no — for a better
reason.** It is no longer "there is probably nothing behind the door". There is:
a full Intel Advanced Menu with a voltage-offset control that drives the very
mailbox this repo spent the week qualifying. The reason not to go through the
door is that **we are already on the other side of it, by a route that reverses
itself.**

| | firmware variable | `MSR 0x150` from Linux |
|---|---|---|
| reaches the same mailbox | yes | yes |
| effect of a wrong value | may not POST | reboot clears it |
| recovery needs | an external SPI programmer | patience |
| already validated here | no | **179 660 verified answers** |

An undervolt written into `CpuSetup` would survive suspend without a re-apply
unit, which is the single thing it would buy over `intel-undervolt`. That is not
worth trading a reversible mistake for an unrecoverable one, on a machine with
no programmer in the drawer.

So this file stays what it has been: **research, not a procedure.** It now knows
considerably more — the menu is real, the offsets are verified against this
firmware, one community claim is confirmed and one is refuted — and it still
ends in the same place, which is that nothing here needs writing.
