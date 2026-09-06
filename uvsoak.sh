#!/bin/bash
# uvsoak - hold a voltage offset for hours under mixed load and record, durably,
# whether the machine keeps producing *correct answers*.
#
#   sudo ./uvsoak.sh                    # 2h at -120 mV, AC
#   sudo ./uvsoak.sh 7200 -120          # same, explicit
#   sudo ./uvsoak.sh 2700 -120 battery  # battery leg, stops at 30% capacity
#   sudo ./uvsoak.sh 600 0              # 0 mV control run
#
# Why this exists. Everything in FIRMWARE.md up to -120 mV was minutes of
# hashing, and the file says so in every section: the failure that matters with
# an undervolt is not a hang, it is a wrong answer under a workload nobody ran.
# -140 mV then froze the machine with the display lit and took the last five
# minutes of the journal with it. So this logs to its own file and fsyncs every
# line -- if the machine hangs, the last line on disk is the last thing that was
# true, including which phase it died in.
#
# What it checks, and why three of them. SHA-256 on this part goes through
# SHA-NI, a narrow fixed-function path and one of the most voltage-tolerant
# things the core can do -- part of why 4625 passes cleared -120 in minutes and
# proved less than it looked like. So the digest chain is joined by an AVX2
# float path (numpy matmul) and an integer-multiplier path (modular
# exponentiation on 2048-bit values). Each has a known answer, compared
# bit-for-bit, counted separately.
#
# The references are computed at 0 mV before the offset goes on, recomputed at
# 0 mV after it comes off, and written into the log header as constants so any
# machine can recompute them. A reference the device under test produced and
# kept only in RAM proves nothing if the device was already wrong.
set -uo pipefail
[ "$EUID" -ne 0 ] && { echo "Run as root (MSR writes need it)."; exit 1; }

DUR=${1:-7200}
MV=${2:--120}
MODE=${3:-ac}
LOGDIR=${LOGDIR:-/var/log/uvsoak}
mkdir -p "$LOGDIR"
LOG="$LOGDIR/soak-$(date +%Y%m%d-%H%M%S).log"

# The offset lives in the OC mailbox until power is lost, so a hang clears it on
# reboot -- but a crash of the python below would not, and leaving the machine
# undervolted after an unattended run is exactly the trap this repo keeps
# warning about. Belt and braces: the python clears it too, this catches the
# case where the python is not around to.
cleanup() {
    python3 -c '
import struct
f = open("/dev/cpu/0/msr", "r+b", 0)
for p in (0, 2):
    f.seek(0x150); f.write(struct.pack("<Q", 0x8000001100000000 | (p << 40)))
' 2>/dev/null && echo "cleanup: core and cache planes set back to 0 mV"
}
trap cleanup EXIT INT TERM

echo "uvsoak: ${MV} mV, ${DUR}s, mode ${MODE}"
echo "log:    ${LOG}"

# BLAS thread count has to be pinned before numpy is imported, not inside the
# workers -- the matmul reference is only bit-for-bit repeatable at a fixed
# thread count, and each worker is meant to be one thread anyway. Not exec'd:
# the trap above is the safety net if the python below dies badly.
export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1
python3 - "$DUR" "$MV" "$MODE" "$LOG" <<'PY'
import hashlib, multiprocessing as mp, os, struct, sys, time
import numpy as np

DUR, MV, MODE, LOGPATH = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3], sys.argv[4]
NCPU = os.cpu_count()

# Python 3.14 defaults to forkserver, which re-imports __main__ -- and __main__
# here is a heredoc on stdin, so there is nothing to re-import. fork is also
# what this wants anyway: the workers inherit the reference answers, the shared
# counter array and the open MSR descriptors.
mp.set_start_method("fork", force=True)

# ---------------------------------------------------------------- MSR plumbing
MSR_OC          = 0x150   # OC mailbox (voltage offsets)
MSR_PLATFORM    = 0x0CE   # base ratio in 15:8
MSR_MPERF       = 0x0E7
MSR_APERF       = 0x0E8
MSR_MCG_CAP     = 0x179   # bank count in 7:0
MSR_THERM_PKG   = 0x1B1   # package digital readout in 22:16
MSR_TEMP_TARGET = 0x1A2
MSR_RAPL_UNIT   = 0x606
MSR_PKG_ENERGY  = 0x611
MSR_PP0_ENERGY  = 0x639

_fds = {}
def msr(cpu):
    if cpu not in _fds:
        _fds[cpu] = os.open(f"/dev/cpu/{cpu}/msr", os.O_RDWR)
    return _fds[cpu]

def rd(reg, cpu=0):
    return struct.unpack("<Q", os.pread(msr(cpu), 8, reg))[0]

def wr(reg, val, cpu=0):
    os.pwrite(msr(cpu), struct.pack("<Q", val), reg)

def plane_read(p):
    wr(MSR_OC, 0x8000001000000000 | (p << 40))
    lo = rd(MSR_OC) & 0xFFFFFFFF
    if lo & 0x80000000:
        lo -= 1 << 32
    return (lo >> 21) / 1.024

def plane_write(p, mv):
    packed = (int(round(mv * 1.024)) << 21) & 0xFFFFFFFF
    wr(MSR_OC, 0x8000001100000000 | (p << 40) | packed)

BASE_MHZ = ((rd(MSR_PLATFORM) >> 8) & 0xFF) * 100
TJMAX    = (rd(MSR_TEMP_TARGET) >> 16) & 0xFF
E_UNIT   = 0.5 ** ((rd(MSR_RAPL_UNIT) >> 8) & 0x1F)
NBANK    = rd(MSR_MCG_CAP) & 0xFF

def pkg_temp():
    return TJMAX - ((rd(MSR_THERM_PKG) >> 16) & 0x7F)

def mce_nonzero():
    # A logged machine check sets the valid bit in the bank's status register.
    # Reading them is cheap and it is the one hardware witness that survives a
    # workload producing wrong answers quietly.
    hits = []
    for b in range(NBANK):
        for cpu in range(NCPU):
            v = rd(0x401 + 4 * b, cpu)
            if v >> 63:
                hits.append(f"cpu{cpu}/bank{b}=0x{v:016x}")
    return hits

def energy():
    return rd(MSR_PKG_ENERGY) & 0xFFFFFFFF, rd(MSR_PP0_ENERGY) & 0xFFFFFFFF

def aperf_mperf():
    a = sum(rd(MSR_APERF, c) for c in range(NCPU))
    m = sum(rd(MSR_MPERF, c) for c in range(NCPU))
    return a, m

# ------------------------------------------------------- the three known answers
# Fixed seeds, fixed sizes, no machine-specific input: the expected digests below
# are reproducible anywhere, which is what makes them evidence rather than an
# assertion about this box.
SHA_SEED, SHA_ITERS = b"uvsoak/sha/v1", 120_000
MOD_SEED, MOD_ITERS = b"uvsoak/int/v1", 24
MAT_SEED, MAT_N     = 20260906, 384

def check_sha():
    h = hashlib.sha256(SHA_SEED).digest()
    for _ in range(SHA_ITERS):
        h = hashlib.sha256(h).digest()
    return h.hex()

def _bigint(tag, bits):
    out, i = b"", 0
    while len(out) * 8 < bits:
        out += hashlib.sha256(MOD_SEED + tag + str(i).encode()).digest()
        i += 1
    return int.from_bytes(out[: bits // 8], "big") | 1

def check_int():
    # Modular exponentiation on 2048-bit values: the integer multiplier and the
    # carry chains, which SHA-NI never touches.
    base, exp, mod = _bigint(b"b", 2048), _bigint(b"e", 512), _bigint(b"m", 2048)
    acc = 0
    for i in range(MOD_ITERS):
        acc ^= pow(base + i, exp, mod)
    return hashlib.sha256(acc.to_bytes(256, "big")).hexdigest()

def check_avx():
    # float64 matmul goes to AVX2 FMA through the BLAS. Bit-for-bit repeatable
    # on a fixed thread count, which is why the worker pins BLAS to one thread.
    rng = np.random.default_rng(MAT_SEED)
    a = rng.standard_normal((MAT_N, MAT_N))
    b = rng.standard_normal((MAT_N, MAT_N))
    c = a @ b
    for _ in range(3):
        c = (c / np.linalg.norm(c)) @ b
    return hashlib.sha256(np.ascontiguousarray(c).tobytes()).hexdigest()

MEM_SEED, MEM_MB = 4242, 64
_membuf = None

def check_mem():
    # A private 64 MB buffer per worker, regenerated after the fork so each one
    # holds its own physical pages, hashed whole every round. This is the only
    # check that streams data out across the ring and into DRAM -- the path a
    # blocky display artifact implicates and the three register-resident checks
    # above would never see. A flipped bit here is persistent: once the buffer
    # is wrong it stays wrong, and every later round reports it.
    global _membuf
    if _membuf is None:
        rng = np.random.default_rng(MEM_SEED)
        _membuf = bytearray(rng.integers(0, 256, size=MEM_MB << 20, dtype=np.uint8).tobytes())
    return hashlib.sha256(memoryview(_membuf)).hexdigest()

CHECKS = [("sha", check_sha), ("int", check_int), ("avx", check_avx), ("mem", check_mem)]
NSLOT = len(CHECKS) + 1          # per-worker: one counter per check, plus mismatches

# ------------------------------------------------------------------- the workers
# Each worker owns four slots in a shared array -- three pass counters and a
# mismatch counter -- so no lock is needed and counter reads never perturb the
# load being measured.
def worker(idx, counters, refs, stop, duty_on, duty_off, pin):
    for v in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS"):
        os.environ[v] = "1"
    if pin is not None:
        os.sched_setaffinity(0, {pin})
    global _membuf
    _membuf = None               # rebuild after the fork, do not share the parent's
    fault = open(LOGPATH + ".mismatch", "a", buffering=1)
    while not stop.is_set():
        t0 = time.monotonic()
        while time.monotonic() - t0 < duty_on and not stop.is_set():
            for k, (name, fn) in enumerate(CHECKS):
                got = fn()
                if got == refs[name]:
                    counters[idx * NSLOT + k] += 1
                else:
                    counters[idx * NSLOT + len(CHECKS)] += 1
                    fault.write(
                        f"{time.time():.3f} worker{idx} {name} "
                        f"expected={refs[name]} got={got}\n"
                    )
                    os.fsync(fault.fileno())
                if stop.is_set():
                    break
        if duty_off:
            stop.wait(duty_off)

# --------------------------------------------------------------------- the run
# Phases, in a repeating cycle. An undervolt does not fail uniformly: the
# all-core phase is the high-current, power-limited case; the single-thread
# bursts sit at the highest voltage-frequency point with idle gaps between them;
# the idle dwell drops into deep C-states, and the exits from those are where
# these fail first. A soak that is only phase A tests one corner of three.
SCALE = float(os.environ.get("PHASE_SCALE", "1"))   # shrink the cycle for smoke tests
PHASES = [
    (n, max(5, int(d * SCALE)), w, max(1, int(on * SCALE)) if on else 0, off, pin)
    for n, d, w, on, off, pin in [
        ("all-core",    240, NCPU, 240, 0, None),
        ("turbo-burst", 120, 1,    5,   5, 0),
        ("idle",         60, 0,    0,   0, None),
        ("mixed",       120, 3,    120, 0, None),
    ]
]

def log_open():
    f = open(LOGPATH, "a", buffering=1)
    return f

def say(f, line):
    f.write(line + "\n")
    f.flush()
    os.fsync(f.fileno())

def read_state():
    def cat(p):
        try:
            return open(p).read().strip()
        except OSError:
            return "?"
    return {
        "ac": cat("/sys/class/power_supply/AC/online"),
        "batt": cat("/sys/class/power_supply/BAT0/capacity"),
        "epp": cat("/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"),
        "maxfreq": cat("/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq"),
        "pl1_uw": cat("/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw"),
        "mmio_uw": cat("/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw"),
        "tcc": str((rd(MSR_TEMP_TARGET) >> 24) & 0x3F),
    }

f = log_open()
st = read_state()
say(f, "# uvsoak v1")
say(f, f"# started        {time.strftime('%Y-%m-%d %H:%M:%S')}  ({time.time():.0f})")
say(f, f"# target offset  {MV:+.0f} mV on core (plane 0) and cache (plane 2)")
say(f, f"# duration       {DUR:.0f} s, mode {MODE}")
say(f, f"# machine        AC={st['ac']} batt={st['batt']}% EPP={st['epp']} "
       f"max={st['maxfreq']} PL1={st['pl1_uw']}uW MMIO_PL1={st['mmio_uw']}uW "
       f"TCC={st['tcc']} "
       f"base={BASE_MHZ}MHz TjMax={TJMAX} banks={NBANK}")
say(f, "# NOTE this attests the offset *with the power configuration recorded")
say(f, "#      above*, not the offset in isolation. Under an all-core load the")
say(f, "#      part is power-limited, so the undervolt spends itself on clock:")
say(f, "#      the cores run faster, and hotter, than a stock-voltage run would.")

say(f, "# computing reference answers at 0 mV before applying the offset")
for p in (0, 2):
    plane_write(p, 0)
refs = {}
t0 = time.monotonic()
for name, fn in CHECKS:
    refs[name] = fn()
    say(f, f"# ref {name:3s} {refs[name]}")
say(f, f"# reference pass took {time.monotonic() - t0:.1f} s at 0 mV")

pre_mce = mce_nonzero()
say(f, f"# machine-check banks before: {pre_mce if pre_mce else 'all clear'}")

for p in (0, 2):
    plane_write(p, MV)
core_mv, cache_mv = plane_read(0), plane_read(2)
say(f, f"# applied        core {core_mv:+.2f} mV  cache {cache_mv:+.2f} mV")
if MV != 0 and (abs(core_mv - MV) > 1.5 or abs(cache_mv - MV) > 1.5):
    say(f, "# ABORT the readback does not match the request")
    for p in (0, 2):
        plane_write(p, 0)
    sys.exit(1)

say(f, "ts elapsed phase core_mv cache_mv Bzy_MHz PkgW CorW PkgTmp mmioW batt "
       "sha int avx mem mismatch")

counters = mp.Array("l", NCPU * NSLOT, lock=False)
stop = mp.Event()
verdict, procs = "completed", []
start = time.monotonic()
last_e, last_t = energy(), time.monotonic()
last_am = aperf_mperf()

def totals():
    return [sum(counters[i * NSLOT + k] for i in range(NCPU)) for k in range(NSLOT)]

try:
    ci = 0
    while time.monotonic() - start < DUR and verdict == "completed":
        name, plen, nw, on, off, pin = PHASES[ci % len(PHASES)]
        ci += 1
        stop.clear()
        procs = [
            mp.Process(target=worker,
                       args=(i, counters, refs, stop, on, off,
                             pin if pin is not None else None))
            for i in range(nw)
        ]
        for p_ in procs:
            p_.start()
        pend = time.monotonic() + plen
        while time.monotonic() < pend and time.monotonic() - start < DUR:
            time.sleep(5)
            now = time.monotonic()
            e = energy()
            dt = now - last_t
            pkg_w = ((e[0] - last_e[0]) % (1 << 32)) * E_UNIT / dt
            cor_w = ((e[1] - last_e[1]) % (1 << 32)) * E_UNIT / dt
            last_e, last_t = e, now
            am = aperf_mperf()
            da = (am[0] - last_am[0]) % (1 << 64)
            dm = (am[1] - last_am[1]) % (1 << 64)
            last_am = am
            mhz = BASE_MHZ * da / dm if dm else 0
            cmv, kmv = plane_read(0), plane_read(2)
            tmp = pkg_temp()
            s = read_state()
            sha_n, int_n, avx_n, mem_n, bad = totals()
            say(f, f"{time.time():.0f} {now - start:7.1f} {name:11s} "
                   f"{cmv:+7.2f} {kmv:+7.2f} {mhz:7.1f} {pkg_w:5.2f} {cor_w:5.2f} "
                   f"{tmp:3d} {int(s['mmio_uw']) // 1000000 if s['mmio_uw'].isdigit() else 0:3d} "
                   f"{s['batt']:>3s} {sha_n:6d} {int_n:6d} {avx_n:6d} {mem_n:6d} {bad:d}")
            if bad:
                verdict = "MISMATCH"; break
            if tmp >= 99:
                verdict = "thermal-abort"; break
            hits = [h for h in mce_nonzero() if h not in pre_mce]
            if hits:
                say(f, f"# MACHINE CHECK {hits}")
                verdict = "machine-check"; break
            if abs(cmv - MV) > 1.5 or abs(kmv - MV) > 1.5:
                verdict = "offset-drifted"; break
            if MODE == "battery":
                if s["ac"] == "1":
                    verdict = "ac-reconnected"; break
                if s["batt"].isdigit() and int(s["batt"]) <= 30:
                    verdict = "battery-floor"; break
        stop.set()
        for p_ in procs:
            p_.join(timeout=30)
            if p_.is_alive():
                p_.terminate()
except KeyboardInterrupt:
    verdict = "interrupted"
finally:
    stop.set()
    for p_ in procs:
        if p_.is_alive():
            p_.terminate()
    for p in (0, 2):
        plane_write(p, 0)

elapsed = time.monotonic() - start
sha_n, int_n, avx_n, mem_n, bad = totals()
say(f, f"# offset cleared, core {plane_read(0):+.2f} mV cache {plane_read(2):+.2f} mV")

# The closing baseline. If the references do not reproduce at 0 mV after the
# run, the run says nothing about the undervolt -- it says something worse.
say(f, "# recomputing references at 0 mV after the run")
post_ok = all(fn() == refs[name] for name, fn in CHECKS)
say(f, f"# post-run baseline at 0 mV: {'reproduces' if post_ok else 'DOES NOT REPRODUCE'}")
post_mce = [h for h in mce_nonzero() if h not in pre_mce]
say(f, f"# machine-check banks after: {post_mce if post_mce else 'all clear (no new)'}")
say(f, f"# verdict        {verdict}")
say(f, f"# ran            {elapsed:.0f} s at {MV:+.0f} mV")
say(f, f"# passes         sha={sha_n} int={int_n} avx={avx_n} mem={mem_n} mismatches={bad}")
f.close()
print(f"verdict {verdict}: {elapsed:.0f}s, sha={sha_n} int={int_n} avx={avx_n} mem={mem_n} mismatches={bad}")
sys.exit(0 if verdict in ("completed", "battery-floor", "interrupted") and not bad and post_ok else 2)
PY
