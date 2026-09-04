#!/bin/bash
# powerwatch - what is actually limiting this CPU, measured rather than assumed.
#
#   sudo ./powerwatch.sh            # watch until Ctrl-C
#   sudo ./powerwatch.sh 60         # watch for 60 seconds
#
# Run it while the CPU is loaded (stress -c $(nproc)) - idle numbers say nothing.

set -uo pipefail
[ "$EUID" -ne 0 ] && { echo "Run as root."; exit 1; }
DUR=${1:-0}
RAPL=/sys/class/powercap/intel-rapl:0
[ -d "$RAPL" ] || { echo "No intel-rapl at $RAPL"; exit 1; }
modprobe msr 2>/dev/null

rd() { # rdmsr via /dev/cpu/0/msr, prints decimal
    python3 - "$1" <<'PY'
import struct,sys
try:
    f=open("/dev/cpu/0/msr","rb"); f.seek(int(sys.argv[1],16)); print(struct.unpack("<Q",f.read(8))[0])
except Exception: print(0)
PY
}

# Static picture, printed once.
units=$(rd 0x606); pu_shift=$(( units & 0xf ))
pl=$(rd 0x610)
pl1=$(( (pl & 0x7fff) )); pl2=$(( (pl >> 32) & 0x7fff ))
lock=$(( (pl >> 63) & 1 ))
tt=$(rd 0x1a2); tjmax=$(( (tt >> 16) & 0xff )); tcc=$(( (tt >> 24) & 0x3f ))
ctl=$(rd 0x64b); nom=$(rd 0x648); lvl1=$(rd 0x649); lvl2=$(rd 0x64a)
printf 'cTDP: active level %s  locked=%s   nominal %s W  level1 %s W  level2 %s W\n' \
    "$(( ctl & 3 ))" "$(( (ctl >> 31) & 1 ))" \
    "$(python3 -c "print(f'{($nom & 0x7fff)/(2**$pu_shift):.0f}')")" \
    "$(python3 -c "print(f'{($lvl1 & 0x7fff)/(2**$pu_shift):.0f}')")" \
    "$(python3 -c "print(f'{($lvl2 & 0x7fff)/(2**$pu_shift):.0f}')")"
printf 'PL1 %s W   PL2 %s W   locked=%s   TjMax %sC (effective %sC)\n' \
    "$(python3 -c "print(f'{$pl1/(2**$pu_shift):.1f}')")" \
    "$(python3 -c "print(f'{$pl2/(2**$pu_shift):.1f}')")" \
    "$lock" "$tjmax" "$(( tjmax - tcc ))"
echo "------------------------------------------------------------------"
MMIO=/sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0
# Sub-domains: core = CPU cores, uncore = integrated GPU. They share the package
# budget, so an iGPU load takes watts away from the cores.
CORE=/sys/class/powercap/intel-rapl:0/intel-rapl:0:0
UNCORE=/sys/class/powercap/intel-rapl:0/intel-rapl:0:1
HAVE_NV=0; command -v nvidia-smi >/dev/null 2>&1 && HAVE_NV=1
sub_e() { cat "$1/energy_uj" 2>/dev/null || echo 0; }
c0=$(sub_e $CORE); u0=$(sub_e $UNCORE)
if [ "$HAVE_NV" -eq 1 ]; then
    printf '%6s %6s %6s %6s %5s %5s %6s  %s\n' pkgW coreW igpuW MHz degC dGPU dGPUW limiting
else
    printf '%6s %6s %6s %6s %5s  %s\n' pkgW coreW igpuW MHz degC limiting
fi
echo "------------------------------------------------------------------"

e0=$(cat $RAPL/energy_uj); t0=$(date +%s%N); elapsed=0
trap 'echo; exit 0' INT TERM
while :; do
    sleep 2
    e1=$(cat $RAPL/energy_uj); c1=$(sub_e $CORE); u1=$(sub_e $UNCORE); t1=$(date +%s%N)
    # energy_uj wraps; max_energy_range_uj gives the modulus
    max=$(cat $RAPL/max_energy_range_uj)
    de=$(( e1 - e0 )); [ "$de" -lt 0 ] && de=$(( de + max ))
    dt=$(( t1 - t0 ))
    watts=$(python3 -c "print(f'{$de/1e6/($dt/1e9):.1f}')")

    mhz=$(awk '/MHz/{s+=$4;n++} END{printf "%d", s/n}' /proc/cpuinfo)
    temp=0
    for f in /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input; do
        v=$(cat "$f" 2>/dev/null); v=${v:-0}; [ "$v" -gt "$temp" ] && temp=$v
    done

    r=$(rd 0x64f); why=""
    (( (r>>1)&1 ))  && why+="thermal "
    (( (r>>10)&1 )) && why+="PL1 "
    (( (r>>11)&1 )) && why+="PL2 "
    (( (r>>12)&1 )) && why+="max-turbo "
    (( (r>>0)&1 ))  && why+="PROCHOT "
    (( (r>>8)&1 ))  && why+="other "
    r19c=$(rd 0x19c)
    (( (r19c>>14)&1 )) && why+="CROSS-DOMAIN "
    [ -z "$why" ] && why="nothing"

    # Re-read the limits every sample: firmware may rewrite them under load,
    # and sysfs shows what we asked for, not necessarily what is in effect.
    plnow=$(rd 0x610)
    l1=$(python3 -c "print(f'{(($plnow)&0x7fff)/(2**$pu_shift):.0f}')")
    l2=$(python3 -c "print(f'{((($plnow)>>32)&0x7fff)/(2**$pu_shift):.0f}')")
    if [ -d "$MMIO" ]; then
        m1=$(( $(cat $MMIO/constraint_0_power_limit_uw 2>/dev/null || echo 0) / 1000000 ))
        m2=$(( $(cat $MMIO/constraint_1_power_limit_uw 2>/dev/null || echo 0) / 1000000 ))
    else
        m1="-"; m2="-"
    fi
    # counters were sampled next to e1 above, so dt applies to all three
    cmax=$(cat $CORE/max_energy_range_uj 2>/dev/null || echo 0)
    dc=$(( c1 - c0 )); [ "$dc" -lt 0 ] && dc=$(( dc + cmax ))
    [ "$dc" -lt 0 ] && dc=0
    umax=$(cat $UNCORE/max_energy_range_uj 2>/dev/null || echo 0)
    du=$(( u1 - u0 )); [ "$du" -lt 0 ] && du=$(( du + umax ))
    [ "$du" -lt 0 ] && du=0
    cw=$(python3 -c "print(f'{$dc/1e6/($dt/1e9):.1f}')")
    uw=$(python3 -c "print(f'{$du/1e6/($dt/1e9):.1f}')")
    c0=$c1; u0=$u1

    if [ "$HAVE_NV" -eq 1 ]; then
        nv=$(nvidia-smi --query-gpu=temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
        ntemp=${nv%%,*}; npow=${nv##*,}
        [ -z "$ntemp" ] && ntemp="-"; [ -z "$npow" ] && npow="-"
        printf '%6s %6s %6s %6s %5s %5s %6s  %s\n' \
            "$watts" "$cw" "$uw" "$mhz" "$(( temp / 1000 ))" "$ntemp" "$npow" "$why"
    else
        printf '%6s %6s %6s %6s %5s  %s\n' \
            "$watts" "$cw" "$uw" "$mhz" "$(( temp / 1000 ))" "$why"
    fi

    e0=$e1; t0=$t1
    elapsed=$(( elapsed + 2 ))
    [ "$DUR" -gt 0 ] && [ "$elapsed" -ge "$DUR" ] && break
done
