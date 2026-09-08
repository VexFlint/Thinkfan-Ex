#!/usr/bin/env python3
"""clawwatch - arm every witness at once and wait for the firmware to move.

The claw-back fires in roughly one run in five and cannot be provoked on demand,
so there is no going back to add an instrument after it happens. This arms all
of them together: if a revert lands in a run, that one capture carries the
evidence for several open questions at once rather than one.

  sudo ./clawwatch.py <seconds> [label]        # load + witness
  sudo ./clawwatch.py 600 idle --no-load       # witness only (resume, idle)

What it witnesses, and which question each is there for:

  TCC offset, MMIO PL1, MSR_PKG_POWER_LIMIT   the revert itself, and whether the
                                              MSR copy moves with it (Q1)
  odvp0..19                                   firmware policy variables the
                                              power-unlock watchdog does NOT
                                              repair, so they survive a revert
                                              as evidence (Q2), and the proxy
                                              for DYTC being invoked (Q3)
  INT3400 mode + current_uuid                 whether firmware enables DPTF on
                                              its own (Q6)
  MSR_SMI_COUNT (0x34)                        whether the revert arrives through
                                              an SMI, and the counter Q11 is
                                              about. Cumulative; turbostat's SMI
                                              column is its per-interval delta.
                                              RESETS ACROSS S3 -- the delta goes
                                              negative and stays meaningless from
                                              a resume onward (measured 2026-09-08).
  core/package throttle counters              CoreThr, the other half of Q11
  MSR_PERF_LIMIT_REASONS                      which limiter is active

**This script never writes a machine register.** That is the point: the whole
value of a capture is that the reverted state was left standing to be read. Set
the limits first (`thinkpad-power-unlock`), stop the watch unit, then run this.
A watchdog anywhere in the picture repairs the evidence in 0.5 s -- FIRMWARE.md
warns about exactly that trap, and it is why this is a separate script from
`pl1probe.py` rather than a flag on it.

Every line is flushed and fsynced. If the machine hangs, the last line on disk
is the last thing that was true -- the lesson uvsoak.sh already paid for.

Across a suspend, two columns lie and the register columns do not. PkgW is
garbage in the first post-resume sample (the RAPL energy counter resets while
time.monotonic() correctly excludes the suspended time, so that one delta is
nonsense -- 56981.38 W in the capture of 2026-09-08), and SMI is wrong from there
on for the reason above. TCC, both PL1 copies and odvp are unaffected, which is
what a resume capture is actually for.
"""
import glob
import os
import shutil
import signal
import struct
import subprocess
import sys
import time

MSR_RAPL_UNIT, MSR_PKG_ENERGY, MSR_PKG_LIMIT = 0x606, 0x611, 0x610
MSR_SMI_COUNT, MSR_LIMIT_REASONS = 0x34, 0x64F
MMIO_PL1 = ("/sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0"
            "/constraint_0_power_limit_uw")
INT3400 = glob.glob("/sys/bus/platform/devices/INT3400:*")
ZONE = "/sys/class/thermal/thermal_zone1"
REASONS = {0: "prochot", 1: "thermal", 4: "residency", 5: "ratl", 6: "vr-therm",
           7: "vr-tdc", 8: "other", 10: "PL1", 11: "PL2", 12: "max-turbo",
           13: "turbo-atten"}


def rdmsr(msr, cpu=0):
    with open(f"/dev/cpu/{cpu}/msr", "rb") as f:
        f.seek(msr)
        return struct.unpack("<Q", f.read(8))[0]


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except Exception:
        return default


def first(pattern):
    hits = glob.glob(pattern)
    return hits[0] if hits else None


def why(raw):
    names = [n for b, n in REASONS.items() if raw & (1 << b)]
    return "+".join(names) if names else "-"


def odvp():
    if not INT3400:
        return ""
    return ",".join(read(f"{INT3400[0]}/odvp{i}", "?") for i in range(20))


def throttles():
    c = p = 0
    for d in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/thermal_throttle"):
        c += int(read(f"{d}/core_throttle_count", "0") or 0)
        p += int(read(f"{d}/package_throttle_count", "0") or 0)
    return c, p


def mhz():
    v = [int(read(p, "0")) for p in
         glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq")]
    v = [x for x in v if x]
    return sum(v) / len(v) / 1000 if v else 0


def fan():
    return (read("/proc/acpi/ibm/fan").split("speed:")[-1].split()[0]
            if "speed:" in read("/proc/acpi/ibm/fan") else "?")


if len(sys.argv) < 2:
    sys.exit(__doc__)
if os.geteuid() != 0:
    sys.exit("Run as root (MSR reads need it).")

dur = int(sys.argv[1])
label = next((a for a in sys.argv[2:] if not a.startswith("--")), "clawwatch")
load_wanted = "--no-load" not in sys.argv

# A repairing watchdog anywhere destroys the capture. Refuse rather than produce
# a log that looks clean because something else quietly fixed the evidence.
if subprocess.run(["systemctl", "is-active", "--quiet",
                   "thinkpad-power-unlock-watch.service"]).returncode == 0:
    sys.exit("thinkpad-power-unlock-watch is ACTIVE -- it repairs reverts in "
             "0.5 s and there would be nothing left to witness. Stop it first.")
if load_wanted and shutil.which("stress") is None:
    sys.exit("`stress` is not installed (or pass --no-load).")

TCC = first("/sys/devices/pci0000:00/*/tcc_offset_degree_celsius")
TEMP = first("/sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input")

# Nothing to witness if the limits already sit at the firmware defaults: a
# revert to 30/15000000 is only visible as a change if they start somewhere else.
tcc0, pl1_0 = read(TCC), read(MMIO_PL1)
if tcc0 == "30" or pl1_0 == "15000000":
    sys.exit(f"Limits are already at firmware defaults (TCC={tcc0} "
             f"PL1={pl1_0}). Run thinkpad-power-unlock first, or there is "
             f"nothing for a claw-back to change.")

unit = rdmsr(MSR_RAPL_UNIT)
PU, EU = 1.0 / (1 << (unit & 0xF)), 1.0 / (1 << ((unit >> 8) & 0x1F))

stamp = time.strftime("%Y%m%d-%H%M%S")
logdir = os.environ.get("LOGDIR", "/var/log/clawwatch")
os.makedirs(logdir, exist_ok=True)
logpath = f"{logdir}/{stamp}-{label.replace(' ', '_')}.log"
log = open(logpath, "w")


def say(line):
    print(line, flush=True)
    log.write(line + "\n")
    log.flush()
    os.fsync(log.fileno())


say(f"# clawwatch {label}: {dur}s, load={'yes' if load_wanted else 'no'}")
say(f"# {time.strftime('%Y-%m-%d %H:%M:%S')}  log={logpath}")
say(f"# start: TCC={tcc0} MMIO_PL1={pl1_0} "
    f"AC={read('/sys/class/power_supply/AC/online')} "
    f"EPP={read('/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference')} "
    f"zone1={read(ZONE + '/mode')} "
    f"uuid={read(INT3400[0] + '/uuids/current_uuid') if INT3400 else '?'}")
say(f"# odvp0..19 = {odvp()}")
say(f"# SMI count at start = {rdmsr(MSR_SMI_COUNT)}")

load = None
if load_wanted:
    load = subprocess.Popen(["stress", "-c", str(os.cpu_count())],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def stop(*_):
    if load:
        try:
            load.terminate()
        except Exception:
            pass


signal.signal(signal.SIGINT, lambda *a: (stop(), say("# interrupted"),
                                         sys.exit(130)))

say("")
say("    t   PkgW  MHz   C  TCC   mmioPL1  msrPL1  SMI  cThr  limiter")
prev = None
events = []
try:
    e0, t0 = rdmsr(MSR_PKG_ENERGY) & 0xFFFFFFFF, time.monotonic()
    start, smi0 = t0, rdmsr(MSR_SMI_COUNT)
    cthr0, pthr0 = throttles()
    while time.monotonic() - start < dur:
        time.sleep(1)
        e1, t1 = rdmsr(MSR_PKG_ENERGY) & 0xFFFFFFFF, time.monotonic()
        watts = ((e1 - e0) & 0xFFFFFFFF) * EU / (t1 - t0)
        raw610 = rdmsr(MSR_PKG_LIMIT)
        cthr, pthr = throttles()
        now = {
            "tcc": read(TCC), "pl1": read(MMIO_PL1),
            "msr_pl1": (raw610 & 0x7FFF) * PU, "odvp": odvp(),
            "zone": read(ZONE + "/mode"),
            "uuid": read(INT3400[0] + "/uuids/current_uuid") if INT3400 else "",
        }
        smi, reasons = rdmsr(MSR_SMI_COUNT), rdmsr(MSR_LIMIT_REASONS)
        t = t1 - start
        say(f"{t:5.0f} {watts:6.2f} {mhz():4.0f} "
            f"{int(read(TEMP, '0') or 0)/1000:3.0f} {now['tcc']:>3}  "
            f"{int(now['pl1'])/1e6:7.2f} {now['msr_pl1']:7.2f} "
            f"{smi - smi0:4d} {cthr - cthr0:5d}  {why(reasons & 0xFFFF)}")

        if prev:
            for k, v in now.items():
                if v != prev[k]:
                    events.append((t, k, prev[k], v))
                    say(f"### t={t:.0f}s  {k}: {prev[k]}  ->  {v}")
        prev = now
        e0, t0 = e1, t1
finally:
    stop()
    say("")
    say(f"# end: TCC={read(TCC)} MMIO_PL1={read(MMIO_PL1)} "
        f"SMI total={rdmsr(MSR_SMI_COUNT) - smi0} "
        f"coreThr={throttles()[0] - cthr0} pkgThr={throttles()[1] - pthr0}")
    say(f"# odvp0..19 = {odvp()}")
    if events:
        say(f"# {len(events)} STATE CHANGES -- this run is a capture:")
        for t, k, a, b in events:
            say(f"#   t={t:.0f}s  {k}: {a} -> {b}")
    else:
        say("# no state change: nothing moved this run")
    say(f"# log: {logpath}")
    log.close()
