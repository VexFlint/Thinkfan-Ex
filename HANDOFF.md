# chargewatch — handoff notes

Companion tool in the thinkfan-ex suite. Monitors USB-C PD charge rate on a
ThinkPad T480 with dual packs (Power Bridge). Read this before changing
`chargewatch.sh` — most of it is hardware facts that were verified on the real
machine, not assumptions, and re-deriving them costs a charger and an afternoon.

## Verified hardware facts (T480, CachyOS, kernel 7.2.2-1-cachyos)

This is an **Arch-based** system. `pacman`, not `apt`.

**PD / UCSI — the important one.** The header used to claim
`/sys/class/typec/` is empty on this generation. That is **wrong** on this
kernel: `USBC000:00` exists, `ucsi_acpi` binds, and `port1-partner` publishes
the charger's advertised source capabilities. Confirmed PDOs:

| PDO | Voltage | Current | Power |
|-----|---------|---------|-------|
| 1 | 5 V | 3 A | 15 W |
| 2 | 9 V | 3 A | 27 W |
| 3 | 12 V | 3 A | 36 W |
| 4 | 15 V | 3 A | 45 W |
| 5 | 20 V | 5 A | **100 W** |
| 6 | PPS 3.3–21 V | 5 A | (range, not a rating) |

So the charger in use is a 100 W third-party PD source, **not** a 45 W or 65 W
Lenovo brick. The original 45-vs-65 inference logic was answering a question
that does not apply here. It is now the fallback path, used only when no UCSI
partner node exists.

Limits of that data:
- These are **advertised capabilities, not the negotiated contract**. The RDO
  is never exposed. `port1`'s own sink caps read 5 V / 100 mA / 500 mA — those
  are PPM placeholders, not what the machine requests.
- `revision: 2.0`, so PPS cannot be requested; the EC picks a fixed PDO.
- 20 V / 5 A assumes an e-marked cable. That is the source's claim.
- No `/sys/kernel/debug/ucsi-*` on this kernel — no raw UCSI opcodes.

**Batteries.** BAT0 internal (~10.4 V), BAT1 external (~11.5 V), both capped at
85% via `charge_control_end_threshold`. No `charge_control_start_threshold` is
exposed, so `resume_below()` falls back to the end threshold.

- Power Bridge charges **one pack at a time**. An idle pack next to a charging
  one is normal EC sequencing. This produced a false "adapter saturated"
  warning in an earlier revision — see `packs_starved()`.
- The packs populate `power_now` and leave `current_now` at 0. Amps are
  derived as W/V.
- Observed ceiling is ~35 W into the packs + ~4 W SoC with an idle CPU. With a
  100 W charger that ceiling is **EC budget allocation**, not adapter
  saturation. `MACHINE_MAX_W` (default 65) is the chassis limit: 20 V / 3.25 A.

**Saturation has two stages**, in the order the EC goes through them:
1. EC tapers charge current to zero — status goes `Not charging` while a pack
   sits below its resume threshold. This is what a 45 W brick hits.
2. Packs actually discharge on AC. Many adapters never get here.

Known blind spot: a pack charging at a *trickle* because the budget is nearly
spent still reads `Charging`, so stage 1 does not fire. That shows up as
falling charge power, not in the status field. Deliberately not guessed at.

## Testing

`test-chargewatch.sh` fakes the whole sysfs surface in a temp dir through four
env overrides the script honours:

```
CHARGEWATCH_PS_ROOT  CHARGEWATCH_RAPL_ROOT  CHARGEWATCH_TYPEC_ROOT  CHARGEWATCH_CONF
```

```bash
./test-chargewatch.sh ./chargewatch.sh     # 24 assertions, no sudo, no hardware
```

Every regression listed below has a case in there. Add one before fixing
anything new — the interesting bugs are all "what does it say in state X", and
state X usually cannot be reproduced on demand with a real charger. `-probe` is
**not** covered (it pegs every core); test that by hand.

## What was fixed, and why it mattered

- **Saturation reported backwards.** `Not charging` was normalised to 0 W, so
  the verdict said "batteries near full or system idle" at the exact moment the
  adapter was at its ceiling. `-probe` only tested for discharge, so it ran full
  duration and reported "never saturated".
- **Power Bridge false positive** (introduced by the above fix, caught on real
  hardware): any idle pack tripped the alarm. Now one `Charging` pack anywhere
  proves the EC still has headroom.
- **`-probe` counted iterations, not seconds.** Each pass costs >1 s, so the
  loop overran the workers' `PROBE_SECONDS + 10` deadline and the load could die
  mid-measurement. Now `SECONDS`-based, deadline `PROBE_SECONDS * 2 + 15`.
- **`dump_pd_contract` walked `-maxdepth 2`**; PDO attributes are three levels
  down. It printed a bare header and nothing else. Now parses PDOs into a table,
  with a raw dump fallback so it can never silently print an empty section again.
- `-help` printed six lines of source (`sed -n '2,45p'`), now stops at the first
  non-comment line. ETA ignored the charge cap (overestimated by ~20 min), now
  scales `energy_full` and clamps. RAPL wrap constant was hardcoded, now reads
  `max_energy_range_uj`. `-interval` unvalidated. `read_raw` forked `cat` ~20×
  per refresh, now uses `read`.

## Open threads

1. **ACPI battery methods** are all in the DSDT (no SSDT hunt needed):
   `GBIF@18138`, `BCTG@30057`, `BCCS@30062`, `BCSG@30067`, `BCSS@30072`,
   `BDSG@30077`, `BDSS@30082`. EC OperationRegion `ECOR@16610` (0x00, 0x0100).
   `BDSS` is force-discharge — the lever for finding out where the ~39 W ceiling
   comes from: drain BAT1 on AC and watch whether the EC gives the freed budget
   to BAT0 or the SoC. **Use `tpacpi-bat`, not raw `acpi_call`** — the set
   methods take packed args and the encoding differs per method. Everything so
   far has been read-only; this would be the first real EC write.

   **1a. Read confirmed, 2026-09-04**, against `/home/vex/t480-acpi/dsdt.dsl`
   (982,211 bytes — all line numbers above verified exact):
   - `GBIF` (`\_SB.PCI0.LPCB.EC.GBIF`) is **dead code** — `grep -n "GBIF ("`
     finds no call site, only the definition. BAT0/BAT1's `_BIF`/`_BIX` call
     **`GBIX`** instead (line 18222), and `_BST` calls **`GBST`** (line
     18316). The live chain is `sysfs → kernel ACPI battery driver →
     _BIF/_BIX/_BST → GBIX/GBST → ECOR fields`, not GBIF. Both are pure
     EC-field reads (`SBBM`/`SBFC`/`SBDC`/`SBDV`/`SBSN`/`SBCH`/`SBMN`), so
     this doesn't change the risk picture, just which name to grep next time.
   - **Derived: the power_now/current_now quirk, traced to source.** In
     `GBIX` (~line 18231): `Local7 = SBBM; Local7 >>= 0x0F; Arg1[0x01] =
     (Local7 ^ 0x01)`. `SBBM` is the Smart Battery `BatteryMode` word; bit 15
     is `CAPACITY_MODE` (SBS spec: 0 = mA/mAh, 1 = 10mW/10mWh). Inverted, that
     becomes `_BIX`'s **Power Unit** element (0 = mWh, 1 = mAh), and `_BST`
     reads the same flag back via `BX0I[0x01]`. If the EC's SBS interface runs
     in capacity-mode 1 (mW), Power Unit comes out 0 (mWh), and the kernel's
     ACPI battery driver populates `energy_now`/`power_now` while leaving
     `charge_now`/`current_now` at zero — the exact quirk `chargewatch` works
     around by deriving amps as W/V. That's the mechanism now, not just the
     symptom. Nothing here reads the *live* value of `SBBM` — that needs
     `acpi_call` or a debugger, not a static read — so the specific bit value
     is inferred-consistent with observed behavior, not measured.
   - Confirmed `BCTG`/`BCCS`/`BCSG`/`BCSS`/`BDSG`/`BDSS` (all under
     `\_SB.PCI0.LPCB.EC.HKEY`) are thin wrappers calling `\PSIF(<0x05..0x0A>,
     Arg0)`. `PSIF` (`\_SB.PCI0.LPCB.EC.PSIF`, line 24793) is `Return (SMI
     (0x14, 0x05, Arg0, Arg1, 0x00))`, and `SMI` (line 24489) sets
     `CMD`/`PAR0-3` EC ports and triggers `APMC = 0xF5` — a real SMI into
     firmware, not another ASL-readable field. So `BDSS` resolves to
     `SMI(CMD=0x14, PAR0=0x05, PAR1=0x0A, PAR2=<payload>)`, and the payload's
     bit layout lives entirely in the EC's SMM handler — invisible to ASL.
     This confirms, rather than just asserts, why `tpacpi-bat` (which encodes
     these payloads from prior reverse-engineering) is right and raw
     `acpi_call` isn't: there's nothing left to read here, only to try.

   **1b. Still open.** The DSDT read closes the reading half of this thread;
   it does not unblock the experiment. The force-discharge run itself (drain
   BAT1 on AC, watch where the EC reallocates the ~39 W budget) is still a
   real EC write and still pending — don't run it without sign-off. It's the
   one item in this file that isn't reversible by re-reading a file.
2. **Platform overhead is a flat 5–15 W constant**, the widest error source in
   the whole estimate. The honest fix is one-off calibration against a USB-C PD
   meter, stored per machine in `/etc/chargewatch.conf`.
3. Trickle-charge blind spot in stage-1 detection (above).
4. `sed -n '16610,16700p' dsdt.dsl` maps the `ec_sys` window to field names —
   confirmed 2026-09-04: byte **0x2F is `HFSP`** (`Offset(0x2A)` followed by
   five consecutive byte fields — `HATR, HT0H, HT0L, HT1H, HT1L, HFSP` — so
   the offsets are exact, no aliasing `Field(ECOR...)` block redefines it),
   matching the well-known ThinkPad EC fan-level register.
   **Correction to how this thread was originally worded:** `thinkfan-ex`
   does not poke `ec_sys` directly. `thinkfan-extreme.sh` writes fan levels
   through `/proc/acpi/ibm/fan` (`$FAN_CONTROL_FILE`,
   `thinkfan-extreme.sh:119`) — the `thinkpad_acpi` kernel driver's procfs
   interface, not a raw EC byte write from this repo's shell code. The kernel
   driver is presumably what touches `HFSP`/0x2F underneath, but that's
   inference about `thinkpad_acpi`'s own source, not something these scripts
   do or this DSDT read can confirm.
