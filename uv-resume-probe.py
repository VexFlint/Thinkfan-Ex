#!/usr/bin/env python3
"""Record the OC mailbox offsets at resume, BEFORE intel-undervolt re-applies.

That ordering is the whole point: "the offset survived S3" and "the offset was
restored for us" produce an identical reading if you look after the re-apply,
and they are different facts about the hardware. The unit is therefore
`Before=intel-undervolt.service` on the resume path.

It also tags each row `real` or `aborted`, because a suspend that FAILS still
fires suspend.target -- so this script still runs, on a machine that never lost
power to the core rail, and faithfully records the offset still in place. Two
such rows exist in this machine's log (2026-09-08 13:16 and 13:41, while a
stale nvme0 refused to suspend with -16) and read exactly like the offset
surviving suspend. Untagged, this log refutes the finding it exists to support.

The tag comes from one authority: the kernel's own /sys/power/suspend_stats
counters, diffed against the previous run. The BOOTTIME-MONOTONIC gap -- which
grows by exactly the time spent suspended and by nothing else -- is recorded
alongside as an independent witness, deliberately NOT folded into the tag. A
row tagged `real` with `slept=0s` is a disagreement between two sources, and
the point of this log is that such a thing stays visible instead of being
resolved silently in here.

Install: /usr/local/sbin/uv-resume-probe, run by uv-resume-probe.service.
"""
import json
import os
import struct
import time

LOG = "/var/log/uvsoak/resume-probe.log"
STATE = "/var/log/uvsoak/resume-probe.state"
STATS = "/sys/power/suspend_stats"
PLANES = ("core", "igpu", "cache", "sa", "aio")


def read_planes():
    """Read all five OC mailbox planes as signed millivolt offsets."""
    fd = os.open("/dev/cpu/0/msr", os.O_RDWR)
    try:
        out = []
        for plane in range(len(PLANES)):
            os.pwrite(fd, struct.pack("<Q", 0x8000001000000000 | (plane << 40)), 0x150)
            lo = struct.unpack("<Q", os.pread(fd, 8, 0x150))[0] & 0xFFFFFFFF
            if lo & 0x80000000:          # sign-extend the 32-bit half
                lo -= 1 << 32
            out.append(f"{(lo >> 21) / 1.024:+.2f}")
        return out
    finally:
        os.close(fd)


def suspended_seconds():
    """BOOTTIME counts time spent suspended; MONOTONIC does not. The gap
    between them therefore grows by exactly the sleep duration."""
    return (time.clock_gettime(time.CLOCK_BOOTTIME)
            - time.clock_gettime(time.CLOCK_MONOTONIC))


def read_int(name):
    with open(f"{STATS}/{name}") as f:
        return int(f.read().strip())


def classify():
    """Tag this resume from the kernel's suspend counters.

    Returns (fields, new_state). Never raises: a row that admits it does not
    know is worth more than no row, and no row is indistinguishable from no
    suspend having happened at all.
    """
    now = {
        "boot_id": open("/proc/sys/kernel/random/boot_id").read().strip(),
        "success": read_int("success"),
        "fail": read_int("fail"),
        "gap": suspended_seconds(),
    }

    try:
        with open(STATE) as f:
            prev = json.load(f)
    except (OSError, ValueError):
        prev = None

    # The counters reset to zero on every boot, so their magnitude cannot tell
    # a reboot from a rollback. The boot id can, and is the real discriminator.
    if prev is None or prev.get("boot_id") != now["boot_id"]:
        prev = {"success": 0, "fail": 0, "gap": 0.0}

    ds = now["success"] - prev["success"]
    df = now["fail"] - prev["fail"]
    slept = now["gap"] - prev["gap"]

    if ds > 0:
        tag = "real"
    elif df > 0:
        tag = "aborted"
    else:
        tag = "unknown"          # no counter moved: resume without a suspend?

    # round() returns an int, which keeps a sub-second float from printing as
    # the "-0s" that a bare format would give it.
    fields = [f"suspend={tag}", f"slept={round(slept)}s", f"stats=+{ds}s/+{df}f"]
    if tag == "aborted":
        try:
            dev = open(f"{STATS}/last_failed_dev").read().strip()
            errno = open(f"{STATS}/last_failed_errno").read().strip()
            step = open(f"{STATS}/last_failed_step").read().strip()
            fields.append(f"failed={step or '?'}:{dev or '?'}:{errno}")
        except OSError:
            pass
    return fields, now


def main():
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")

    try:
        vals = read_planes()
        planes = " ".join(f"{n}={v}" for n, v in zip(PLANES, vals))
    except OSError as e:
        planes = f"planes=unreadable({e.__class__.__name__}:{e.errno})"

    state = None
    try:
        fields, state = classify()
    except (OSError, ValueError) as e:
        fields = ["suspend=unknown", f"reason={e.__class__.__name__}"]

    with open(LOG, "a") as f:
        f.write(f"{stamp} pre-reapply {planes} {' '.join(fields)}\n")
        f.flush()
        os.fsync(f.fileno())

    if state is not None:
        tmp = STATE + ".new"
        with open(tmp, "w") as f:
            json.dump(state, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, STATE)   # never leave a half-written baseline behind


main()
