#!/bin/bash
# burnboth - load the CPU and the MX150 at once and record what the shared
# heatpipe does about it.
#
#   sudo ./burnboth.sh            # 120s, default backend
#   sudo ./burnboth.sh 300        # 300s
#   sudo ./burnboth.sh 120 gears  # force a GPU backend
#   sudo THREADS=2 ./burnboth.sh 120 cpu  # few-core turbo, no dGPU in the heatpipe
#
# What can and cannot be measured on this machine:
#   CPU package / iGPU watts  RAPL, accurate.
#   dGPU watts                NOT AVAILABLE. The MX150's VBIOS exposes no power
#                             management object, so nvidia-smi reports N/A for
#                             power.draw no matter what. Only temperature and
#                             the hardware slowdown flags are readable.
#   total system watts        Only while on battery, from power_now. On AC the
#                             battery reports 0 and there is no other rail
#                             counter, so the dGPU's draw is invisible.
# So: the AC run shows you thermals and CPU power. The battery run is the only
# one that puts a number on the whole machine. Run both.
set -uo pipefail
[ "$EUID" -ne 0 ] && { echo "Run as root (MSR reads need it)."; exit 1; }

DUR=${1:-120}
BACKEND=${2:-auto}
STAGGER=${3:-0}          # seconds to delay the GPU load behind the CPU load
# All cores is the power-limited case; 2-4 cores is the one that reaches 4.2GHz
# single-core turbo, where package power stays under PL1 and only the thermal
# trip ever engages. Env var, not a positional, so old invocations still work.
THREADS=${THREADS:-$(nproc)}

# Bail out before the hardware has to. The CPU protects itself at TjMax 100 and
# the GPU slows at 97 / shuts down at 102, so this is about not cooking the
# chassis unattended, not about preventing damage.
#
# 99, not 97: with TCC offset 4 the hardware clamps at 96 and the per-core
# reading overshoots that by a degree, so a 97 abort ends every run the instant
# the cap does its job. 99 only fires if the clamp itself failed.
CPU_ABORT=99
GPU_ABORT=95

GPU_PIDFILE=$(mktemp)    # the respawn wrapper's pid; see cleanup()
RUN_USER=${SUDO_USER:-}
UID_OF_USER=$(id -u "${RUN_USER:-root}" 2>/dev/null || echo 0)

pick_backend() {
    if command -v clpeak >/dev/null 2>&1; then echo clpeak; return; fi
    if command -v vkcube  >/dev/null 2>&1; then echo vkcube; return; fi
    if command -v glxgears >/dev/null 2>&1; then echo gears; return; fi
    echo none
}
[ "$BACKEND" = auto ] && BACKEND=$(pick_backend)

# clpeak is OpenCL and runs headless as root. The GL/Vulkan backends need the
# user's compositor, so they get dropped back to that user with their session
# environment. Both benchmarks terminate, so each is wrapped in a loop.
gpu_load_start() {
    case "$BACKEND" in
    clpeak)
        bash -c 'while :; do clpeak >/dev/null 2>&1 || sleep 1; done' &
        echo $! > "$GPU_PIDFILE"
        ;;
    vkcube|gears)
        [ -z "$RUN_USER" ] && { echo "Need SUDO_USER for the $BACKEND backend; run via sudo, not as root directly."; return 1; }
        local env_pfx="XDG_RUNTIME_DIR=/run/user/$UID_OF_USER WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0} DISPLAY=${DISPLAY:-:0} __GL_SYNC_TO_VBLANK=0 vblank_mode=0"
        if [ "$BACKEND" = vkcube ]; then
            local cmd="prime-run vkcube"
        else
            # one instance is driver-overhead bound; a few together actually
            # keep the shaders busy
            local cmd="for i in 1 2 3; do prime-run glxgears -geometry 1600x1200 & done; wait"
        fi
        sudo -u "$RUN_USER" env $env_pfx bash -c "while :; do $cmd >/dev/null 2>&1 || sleep 1; done" &
        echo $! > "$GPU_PIDFILE"
        ;;
    cpu)
        return 0    # CPU only, on purpose
        ;;
    none)
        echo "No GPU load tool found (looked for clpeak, vkcube, glxgears)."
        return 1
        ;;
    esac
    return 0
}

echo "backend: $BACKEND    threads: $THREADS    duration: ${DUR}s    abort: CPU ${CPU_ABORT}C / GPU ${GPU_ABORT}C"
nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sed 's/^/dGPU:    /'
printf 'limits:  TCC offset %s (TjMax effective %s)  MMIO PL1 %s W\n' \
    "$(cat /sys/devices/pci0000:00/*/tcc_offset_degree_celsius 2>/dev/null)" \
    "$(( 100 - $(cat /sys/devices/pci0000:00/*/tcc_offset_degree_celsius 2>/dev/null || echo 0) ))" \
    "$(( $(cat /sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw) / 1000000 ))"

# The previous run of this script took the machine down hard at t+2s and left no
# trace: the console output died with the shell and /tmp went with the reboot.
# So mark the attempt in the journal, and hand the sampler a path it can fsync.
OUT=${OUT:-/var/log/burnboth-$(date +%Y%m%d-%H%M%S).log}
export OUT
{
    echo "backend $BACKEND  threads $THREADS  duration ${DUR}s  stagger ${STAGGER}s"
    echo "TCC offset $(cat /sys/devices/pci0000:00/*/tcc_offset_degree_celsius 2>/dev/null)  PL1 $(( $(cat /sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw) / 1000000 ))W"
    echo "power: AC online=$(cat /sys/class/power_supply/AC/online 2>/dev/null) PD $(( $(cat /sys/class/power_supply/ucsi-source-psy-USBC000:001/voltage_now 2>/dev/null || echo 0) / 1000000 ))V/$(( $(cat /sys/class/power_supply/ucsi-source-psy-USBC000:001/current_now 2>/dev/null || echo 0) / 1000000 ))A"
} >> "$OUT"
logger -t burnboth "RUN START backend=$BACKEND dur=${DUR}s stagger=${STAGGER}s out=$OUT"
sync                            # flush everything already dirty; a cut from here loses only this run

modprobe msr 2>/dev/null
stress -c "$THREADS" >/dev/null 2>&1 &
CPU_PID=$!
# Bringing CPU and GPU up in the same instant is what the machine died on. With
# STAGGER>0 the dGPU joins a CPU that has already settled out of its PL2 burst,
# so a run that survives staggered but not simultaneous points at load onset
# rather than at heat.
#
# The delay has to run in the background: sleeping here would hold off the
# sampler too, leaving the staggered window unmonitored -- which is the whole
# thing we are trying to observe.
[ "$BACKEND" = none ] && { echo "No GPU load tool found."; kill $CPU_PID 2>/dev/null; exit 1; }
if [ "$STAGGER" -gt 0 ]; then
    echo "GPU joins at t+${STAGGER}s"
    { sleep "$STAGGER"; gpu_load_start; } &
    STAGGER_PID=$!
else
    gpu_load_start || { kill $CPU_PID 2>/dev/null; exit 1; }
fi

# The GPU load is a `while :` wrapper around a benchmark that terminates, so
# killing the benchmark alone just makes the wrapper start another one. Kill the
# wrapper FIRST, then whatever it had running -- the previous order leaked a
# clpeak loop that ran unattended for nine minutes after the script exited.
cleanup() {
    [ -n "${STAGGER_PID:-}" ] && kill "$STAGGER_PID" 2>/dev/null
    gp=$(cat "$GPU_PIDFILE" 2>/dev/null)
    if [ -n "$gp" ]; then
        kill "$gp" 2>/dev/null          # stop the respawn
        pkill -P "$gp" 2>/dev/null      # then its current child
    fi
    rm -f "$GPU_PIDFILE"
    kill $CPU_PID 2>/dev/null
    pkill -x stress 2>/dev/null
    pkill -x clpeak 2>/dev/null
    pkill -x glxgears 2>/dev/null
    pkill -x vkcube 2>/dev/null
}
trap 'cleanup' EXIT INT TERM

# One persistent sampler rather than a shell loop respawning python each tick:
# this script is measuring CPU power, so the monitor's own cost has to stay
# small enough not to show up in the number.
python3 - "$DUR" "$CPU_ABORT" "$GPU_ABORT" <<'PY'
import glob, os, struct, subprocess, sys, time

dur, cpu_abort, gpu_abort = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])

RAPL   = "/sys/class/powercap/intel-rapl:0"
CORE   = RAPL + "/intel-rapl:0:0"
UNCORE = RAPL + "/intel-rapl:0:1"

def rd(addr):
    try:
        with open("/dev/cpu/0/msr", "rb") as f:
            f.seek(addr)
            return struct.unpack("<Q", f.read(8))[0]
    except Exception:
        return 0

def energy(path):
    try:
        return int(open(path + "/energy_uj").read())
    except Exception:
        return 0

def maxrange(path):
    try:
        return int(open(path + "/max_energy_range_uj").read())
    except Exception:
        return 0

def cpu_temp():
    vals = [int(open(f).read()) for f in
            glob.glob("/sys/devices/platform/coretemp.0/hwmon/hwmon*/temp*_input")]
    return max(vals) // 1000 if vals else 0

def sys_watts():
    # Only meaningful while discharging; on AC power_now reads 0.
    tot, discharging = 0, False
    for b in ("BAT0", "BAT1"):
        try:
            st = open(f"/sys/class/power_supply/{b}/status").read().strip()
            p  = int(open(f"/sys/class/power_supply/{b}/power_now").read())
        except Exception:
            continue
        if st == "Discharging":
            discharging = True
        tot += p
    return (tot / 1e6) if discharging else None

def gpu():
    """temp, and the hardware's own reason for holding the GPU back."""
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=temperature.gpu,clocks_throttle_reasons.hw_thermal_slowdown,"
             "clocks_throttle_reasons.sw_thermal_slowdown,clocks_throttle_reasons.hw_power_brake_slowdown,"
             "clocks.sm", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=3).stdout.strip()
        t, hwt, swt, brake, sm = [x.strip() for x in out.split(",")]
        why = []
        if hwt.lower()  in ("active", "1", "true"): why.append("hw-thermal")
        if swt.lower()  in ("active", "1", "true"): why.append("sw-thermal")
        if brake.lower() in ("active", "1", "true"): why.append("pwr-brake")
        return int(t), (sm if sm.isdigit() else "-"), ("+".join(why) or "-")
    except Exception:
        return 0, "-", "?"

TCC_PATH = glob.glob("/sys/devices/pci0000:00/*/tcc_offset_degree_celsius")
PL1_PATH = "/sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw"

def limits():
    """The unit applies these at boot, verifies them, and exits 0 -- which says
    nothing about whether they survive. They were seen back at the firmware
    defaults mid-run once in three runs, and held for a full 300s run after that,
    so the revert is real but intermittent. Nothing reverts them at idle: sample
    every tick and note the exact second, since that is the only way to catch it."""
    try:
        tcc = open(TCC_PATH[0]).read().strip() if TCC_PATH else "?"
    except Exception:
        tcc = "?"
    try:
        pl1 = int(open(PL1_PATH).read()) // 1000000
    except Exception:
        pl1 = "?"
    return f"tcc{tcc}/pl1 {pl1}W"

def batt():
    """Ground truth on whether the adapter is still carrying the load.
    ucsi-source-psy reports the vSafe5V default on this firmware and never
    tracks the live PD contract, so it cannot answer that. A battery flipping
    to Discharging while on AC is the EC saying the wall stopped keeping up --
    which is exactly the state we expect just before an OCP cut."""
    states, tot = set(), 0.0
    for b in ("BAT0", "BAT1"):
        try:
            st = open(f"/sys/class/power_supply/{b}/status").read().strip()
            tot += int(open(f"/sys/class/power_supply/{b}/power_now").read()) / 1e6
        except Exception:
            continue
        states.add(st)
    # Strongest state across both packs, not the last one iterated: BAT0 can go
    # Discharging while BAT1 sits Full, and overwriting the flag each pass hid
    # exactly the signal this column exists to catch.
    flag = ("D" if "Discharging" in states else
            "C" if "Charging" in states else
            "N" if states else "-")
    return f"{flag}{tot:.1f}"

def pd():
    """Logged for completeness, not trusted -- see batt()."""
    try:
        d = "/sys/class/power_supply/ucsi-source-psy-USBC000:001"
        return (f'{int(open(d + "/voltage_now").read()) / 1e6:.0f}V'
                f'/{int(open(d + "/current_now").read()) / 1e6:.1f}A')
    except Exception:
        return "-"

def fan():
    """The one thing this repo actually controls, and the sampler was not recording it."""
    try:
        lvl = spd = "-"
        for line in open("/proc/acpi/ibm/fan"):
            k, _, v = line.partition(":")
            v = v.strip()
            if k == "level":
                lvl = v
            elif k == "speed":
                spd = v if v.isdigit() and v != "65535" else "-"
        return lvl, spd
    except Exception:
        return "?", "?"

def cpu_why():
    r = rd(0x64f)
    w = []
    if (r >> 1) & 1:  w.append("thermal")
    if (r >> 10) & 1: w.append("PL1")
    if (r >> 11) & 1: w.append("PL2")
    if (r >> 12) & 1: w.append("max-turbo")
    if (r >> 0) & 1:  w.append("PROCHOT")
    return "+".join(w) or "nothing"

# Written and fsynced per sample. The point is that if the box cuts power again,
# the last line on disk is the last state the machine was actually in.
out = open(os.environ.get("OUT", "/dev/null"), "a", buffering=1)
def record(line):
    print(line, flush=True)
    out.write(line + "\n")
    out.flush()
    os.fsync(out.fileno())

lim0 = limits()

pmax, cmax, umax = maxrange(RAPL), maxrange(CORE), maxrange(UNCORE)
e0, c0, u0 = energy(RAPL), energy(CORE), energy(UNCORE)
t0 = time.monotonic()

on_battery = sys_watts() is not None
record("-" * 104)
hdr = (f'{"t":>5} {"pkgW":>6} {"coreW":>6} {"igpuW":>6} {"maxMHz":>6} {"cpuC":>5} {"gpuC":>5} '
       f'{"gpuMHz":>7} {"fan":>5} {"rpm":>5} {"bat":>7} {"pd":>9}  {"cpu-limit":<18} {"gpu-limit"}')
record(hdr)
record("-" * 104)

peak = {"pkg": 0.0, "cpuC": 0, "gpuC": 0, "sys": 0.0}
samples, aborted = [], None
elapsed = 0

# The machine died at about t+2s and produced not one sample. Tick fast through
# the load-onset window, then settle down so the monitor does not show up in the
# power figure it is measuring.
FAST_UNTIL, FAST_IV, SLOW_IV = 20.0, 0.5, 2.0

while elapsed < dur:
    iv = FAST_IV if elapsed < FAST_UNTIL else SLOW_IV
    time.sleep(iv)
    e1, c1, u1 = energy(RAPL), energy(CORE), energy(UNCORE)
    t1 = time.monotonic()
    dt = t1 - t0

    def delta(a, b, m):
        d = b - a
        return d + m if d < 0 else d

    pw = delta(e0, e1, pmax) / 1e6 / dt
    cw = delta(c0, c1, cmax) / 1e6 / dt
    uw = delta(u0, u1, umax) / 1e6 / dt
    e0, c0, u0, t0 = e1, c1, u1, t1

    mhz = 0
    try:
        f = [float(l.split(":")[1]) for l in open("/proc/cpuinfo") if "MHz" in l]
        mhz = int(max(f))
    except Exception:
        pass

    ct = cpu_temp()
    gt, gsm, gwhy = gpu()
    flvl, frpm = fan()
    cwhy = cpu_why()
    sw = sys_watts()

    peak["pkg"] = max(peak["pkg"], pw)
    peak["cpuC"] = max(peak["cpuC"], ct)
    peak["gpuC"] = max(peak["gpuC"], gt)
    if sw: peak["sys"] = max(peak["sys"], sw)
    samples.append((pw, cw, uw, ct, gt, sw, elapsed))

    elapsed += iv
    line = (f'{elapsed:>5.1f} {pw:>6.1f} {cw:>6.1f} {uw:>6.1f} {mhz:>6} '
            f'{ct:>5} {gt:>5} {gsm:>7} {flvl:>5} {frpm:>5} {batt():>7} {pd():>9}'
            f'  {cwhy:<18} {gwhy}')
    if sw is not None:
        line += f'   sys {sw:.1f}W'
    record(line)

    lim = limits()
    if lim != lim0:
        record(f'  >>> LIMITS CHANGED at t={elapsed:.1f}s: {lim0} -> {lim}')
        lim0 = lim

    if ct >= cpu_abort:
        aborted = f"CPU hit {ct}C (limit {cpu_abort})"; break
    if gt >= gpu_abort:
        aborted = f"GPU hit {gt}C (limit {gpu_abort})"; break

record("-" * 104)
if aborted:
    print(f"ABORTED: {aborted}")
n = len(samples) or 1
# The first samples are the turbo burst, not the sustained state; average the
# tail so the number means "what this machine holds", not "what it peaks".
# Slice by elapsed time, not by sample count: the onset window ticks 4x faster,
# so a count-based midpoint would land early and quietly inflate the average
# against earlier runs.
tail = [x for x in samples if x[6] >= dur / 2] or samples
print(f'peak package {peak["pkg"]:.1f} W   sustained {sum(s[0] for s in tail)/len(tail):.1f} W')
print(f'peak CPU {peak["cpuC"]}C   peak GPU {peak["gpuC"]}C')
print(f'limits at end: {limits()}')
if on_battery:
    print(f'peak total system {peak["sys"]:.1f} W   sustained {sum(s[5] for s in tail if s[5])/max(1,len([s for s in tail if s[5]])):.1f} W')
else:
    print('total system power: unavailable on AC. Re-run on battery for the whole-machine number.')
PY
