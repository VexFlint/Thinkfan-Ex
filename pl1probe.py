#!/usr/bin/env python3
"""pl1probe - which PL1 copy actually binds, and what is limiting right now.

The T480 carries two copies of the sustained power limit: MSR_PKG_POWER_LIMIT
(0x610) and an MMIO copy behind the processor thermal device, exposed as the
intel-rapl-mmio powercap zone. power-unlock writes only the MMIO copy, on the
claim that hardware enforces min(MSR, MMIO). This measures that claim instead of
asserting it: drive MMIO PL1 to a value well clear of the MSR copy, load every
core, and see which number steady state lands on.

  sudo ./pl1probe.py <pl1_watts> <seconds> [label]
  sudo TCC_OFFSET=4 ./pl1probe.py 18 180 "clean PL1 test"

Read the tail-half mean, not the whole-run mean. PL1 is an average over its time
window (~28 s here), so a run from idle spends its first ~33 s at PL2 and any
mean that includes that phase reads high -- which is exactly how a 90 s run at
PL1 22 W once produced 24.87 W and made this look like an open question. The
0x64F column says which limiter is active, so you need not infer it from watts.

Writes: MMIO PL1 and the TCC offset, both restored on exit including on Ctrl-C,
and neither survives a reboot. Every MSR access is a read. Requires `stress`.

Why a watchdog and not an observer: the firmware claw-back can move both limits
mid-run, which silently turns the rest of the run into a different experiment.
Anything that drifts is put back and stamped with the time it happened, so a
revert shows up as a logged event rather than as a contaminated tail.
"""
import glob
import os
import shutil
import signal
import struct
import subprocess
import sys
import time

MSR_RAPL_UNIT, MSR_PKG_LIMIT, MSR_PKG_ENERGY = 0x606, 0x610, 0x611
# 0x64F is the one populated on this part; 0x690 reads 0 here. The kernel
# defines both (MSR_PERF_LIMIT_REASONS / MSR_CORE_PERF_LIMIT_REASONS), so log
# both rather than assume which generation's layout applies.
MSR_LIMIT_REASONS, MSR_CORE_LIMIT_REASONS = 0x64F, 0x690
MMIO_PL1 = ("/sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0"
            "/constraint_0_power_limit_uw")

# Low 16 bits of 0x64F: which limiter is asserting right now. Bits 16+ are the
# sticky log copies of the same, which is why the high half never changes.
REASONS = {0: "prochot", 1: "thermal", 4: "residency", 5: "ratl", 6: "vr-therm",
           7: "vr-tdc", 8: "other", 10: "PL1", 11: "PL2", 12: "max-turbo",
           13: "turbo-atten"}


def rdmsr(msr, cpu=0):
    with open(f"/dev/cpu/{cpu}/msr", "rb") as f:
        f.seek(msr)
        return struct.unpack("<Q", f.read(8))[0]


def read(path):
    with open(path) as f:
        return f.read().strip()


def write(path, val):
    with open(path, "w") as f:
        f.write(str(val))


def first(pattern):
    hits = glob.glob(pattern)
    return hits[0] if hits else None


def mhz():
    v = [int(read(p)) for p in
         glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq")]
    return sum(v) / len(v) / 1000 if v else 0


def why(raw):
    """Name the limiters asserting in the low half of a 0x64F value."""
    names = [n for b, n in REASONS.items() if raw & (1 << b)]
    return ",".join(names) if names else "-"


if len(sys.argv) < 3:
    sys.exit(__doc__)
if os.geteuid() != 0:
    sys.exit("Run as root (MSR reads and powercap writes need it).")
if shutil.which("stress") is None:
    sys.exit("`stress` is not installed.")

want_w, dur = float(sys.argv[1]), int(sys.argv[2])
label = sys.argv[3] if len(sys.argv) > 3 else f"pl1-{want_w:g}W"
want_uw = int(want_w * 1e6)

unit = rdmsr(MSR_RAPL_UNIT)
PU = 1.0 / (1 << (unit & 0xF))           # power unit, W
EU = 1.0 / (1 << ((unit >> 8) & 0x1F))   # energy unit, J

TEMP = first("/sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input")
TCC = first("/sys/devices/pci0000:00/*/tcc_offset_degree_celsius")
# Default 4 (throttle at 96 C) so the thermal trip cannot bind and be mistaken
# for the power limit -- the mistake that wasted one run of this experiment.
want_tcc = os.environ.get("TCC_OFFSET", "4")

orig_pl1, orig_tcc = read(MMIO_PL1), read(TCC)
fan = subprocess.run(["sed", "-n", "2p", "/proc/acpi/ibm/fan"],
                     capture_output=True, text=True).stdout.strip()
print(f"# {label}: MMIO PL1 {int(orig_pl1)/1e6:g} W -> {want_w:g} W, {dur}s, "
      f"{os.cpu_count()} threads")
print(f"# units: power {PU} W, energy {EU*1e6:.3f} uJ")
print(f"# AC={read('/sys/class/power_supply/AC/online')} "
      f"EPP={read('/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference')} "
      f"TCC={orig_tcc} {fan}")

write(TCC, want_tcc)
write(MMIO_PL1, want_uw)
got = int(read(MMIO_PL1))
print(f"# set TCC {read(TCC)} (throttle at {100 - int(read(TCC))} C), "
      f"MMIO PL1 {got/1e6:g} W"
      + ("" if got == want_uw else "  *** WRITE DID NOT STICK ***"))

load = subprocess.Popen(["stress", "-c", str(os.cpu_count())],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
restored = False


def restore(*_):
    # Both limits, not just the one under test: this script writes TCC too, and
    # leaving a machine at throttle-at-96C because a run was interrupted is not
    # a state anyone asked for.
    global restored
    if restored:
        return
    restored = True
    try:
        load.terminate()
    except Exception:
        pass
    write(MMIO_PL1, orig_pl1)
    write(TCC, orig_tcc)
    print(f"# restored MMIO PL1 {int(read(MMIO_PL1))/1e6:g} W, TCC {read(TCC)}")


signal.signal(signal.SIGINT, lambda *a: (restore(), sys.exit(130)))

rows, events = [], []
print(f"\n{'t':>5} {'PkgW':>7} {'MHz':>7} {'C':>4} {'mmioPL1':>8} {'msrPL1':>7} "
      f"{'TCC':>4} {'en/cl':>6} {'0x64F':>12}  limiter")
try:
    e0, t0 = rdmsr(MSR_PKG_ENERGY) & 0xFFFFFFFF, time.monotonic()
    start = t0
    while time.monotonic() - start < dur:
        time.sleep(5)
        e1, t1 = rdmsr(MSR_PKG_ENERGY) & 0xFFFFFFFF, time.monotonic()
        watts = ((e1 - e0) & 0xFFFFFFFF) * EU / (t1 - t0)

        raw610 = rdmsr(MSR_PKG_LIMIT)
        msr_pl1 = (raw610 & 0x7FFF) * PU
        en, clamp = (raw610 >> 15) & 1, (raw610 >> 16) & 1
        reasons = rdmsr(MSR_LIMIT_REASONS)
        cur_pl1, cur_tcc = int(read(MMIO_PL1)), int(read(TCC))

        if cur_pl1 != want_uw:
            events.append((t1 - start, "MMIO PL1", cur_pl1 / 1e6, want_w))
            write(MMIO_PL1, want_uw)
        if cur_tcc != int(want_tcc):
            events.append((t1 - start, "TCC offset", cur_tcc, int(want_tcc)))
            write(TCC, want_tcc)

        rows.append((t1 - start, watts, int(read(TEMP)) / 1000 if TEMP else 0,
                     cur_pl1 / 1e6, cur_tcc, reasons,
                     rdmsr(MSR_CORE_LIMIT_REASONS)))
        print(f"{t1-start:5.0f} {watts:7.2f} {mhz():7.0f} {rows[-1][2]:4.0f} "
              f"{cur_pl1/1e6:8.2f} {msr_pl1:7.2f} {cur_tcc:4d} "
              f"{en}/{clamp:<4} 0x{reasons:010x}  {why(reasons & 0xFFFF)}",
              flush=True)
        e0, t0 = e1, t1
finally:
    restore()

if rows:
    tail = [r for r in rows if r[0] >= rows[-1][0] * 0.5]
    print(f"\n# whole-run mean  {sum(r[1] for r in rows)/len(rows):6.2f} W  "
          f"({len(rows)} samples)")
    print(f"# tail-half mean  {sum(r[1] for r in tail)/len(tail):6.2f} W  "
          f"({len(tail)} samples, t>={tail[0][0]:.0f}s)   <- compare this one")
    print(f"# requested PL1   {want_w:6.2f} W")
    print(f"# max PkgTmp      {max(r[2] for r in rows):6.0f} C")
    print(f"# 0x690 seen      {sorted({hex(r[6]) for r in rows})}")
    for t, what, was, wanted in events:
        print(f"# REVERT t={t:.0f}s  {what} was {was} (wanted {wanted}) -- rewrote")
    tccs, pl1s = sorted({r[4] for r in rows}), sorted({r[3] for r in rows})
    print(f"# TCC seen {tccs}  MMIO PL1 seen {pl1s}"
          + ("   *** CLAWED BACK MID-RUN ***" if len(tccs) > 1 or len(pl1s) > 1
             else ""))
