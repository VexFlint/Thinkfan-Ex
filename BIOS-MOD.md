# Hidden BIOS settings on a ThinkPad T480

What "hidden BIOS settings" actually are on this machine, what is reachable from
a booted Linux, what the public research does and does not establish, and what it
would cost to go further.

**Nothing in this file has been written to the machine.** Every value below was
read. The one write this repo has ever made to firmware settings went through
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
| [The safe next step](#the-safe-next-step) | IFR extraction, which writes nothing |
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

So the honest statement: a variable with a promising name holds 34 zero bytes on
this machine, which is consistent with a disabled bitfield and equally
consistent with a vestigial store the firmware never reads. **Writing `0xFF`
into it is a guess, not a procedure**, and it is a guess against the firmware
that decides whether this laptop turns on.

## What the public research establishes

| claim | status |
|---|---|
| Hidden entries are suppressed in the IFR, values live in EFI variables | **Established.** This is how UEFI setup works, and the [UEFI Lessons material](https://github.com/Kostr/UEFI-Lessons/blob/master/Lessons_uncategorized/Lesson_Hidden_BIOS_settings) documents the mechanism directly |
| Settings can be changed without flashing, by writing the variable | **Established** as a general technique — [bios-mods how-to](https://www.bios-mods.com/forum/Thread-HOW-TO-Change-hidden-BIOS-settings-without-unlock-request-and-without-flashing), [SlimIFR + UefiVarTool](https://github.com/GeographicCone/SlimIFR) |
| A T480-specific guide exists for unlocking the hidden menu | **Dead link.** The widely-cited "Thinkpad T480 unlock BIOS hidden menu + modify whitelist + cfg lock" is hosted on `programming.vip`, which no longer resolves |
| T480 CFG Lock sits at `VarOffset 0x3C`, `VarStore 0x3` | **Claimed, untested.** The [poster](https://github.com/taina0407/T480-OpenCore-Hackintosh/issues/4) says outright they had not tried it on their machine |
| `LenovoHiddenSetting` unhides menus when its bits are set | **Hypothesis only.** No demonstration on any model |
| Some ThinkPads brick permanently from one UEFI setting | **Established, and does not apply here.** "Thunderbolt BIOS Assist" killed P52, P52s, P1, P72 and X1 Yoga 2018 boards. [The T480 has no Thunderbolt and is not affected](https://www.notebookcheck.net/Some-recent-ThinkPads-can-be-destroyed-by-changing-a-UEFI-BIOS-setting.346156.0.html) |

The last row is the only piece of unambiguously good news: the specific landmine
that has destroyed ThinkPad boards is not in this machine's path.

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

## The safe next step

Before writing anything, get the list. This writes nothing to the machine:

1. Download Lenovo's T480 BIOS update package and extract the firmware image
   from it. No hardware, no flashing — the vendor ships the image.
2. Open it in **UEFITool**, find and extract the Setup module.
3. Run **IFRExtractor** over it, and **SlimIFR** to make the dump readable.
4. Read the result: every setting the firmware knows about, its variable, its
   offset, its possible values, and whether it is suppressed.

That converts the whole question from forum hypotheses into a list — and
critically, it produces **this machine's own offsets** rather than a stranger's.
The difference between a safe write and a brick is usually exactly that.

The offsets are firmware-version-specific. A number that worked for someone
else's T480 on a different BIOS revision is not a number, it is a coin flip.

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

So the state of play is: the door is identifiable, the lock is understood in
general, no one has published a key for this model, and nothing this repo wants
is on the other side. That may change if the IFR dump turns up something real.
Until it does, this file is research, not a procedure.
