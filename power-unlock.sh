#!/bin/bash
# Re-apply CPU power/thermal limits that Lenovo's firmware programs
# conservatively and reprograms at every boot.
#
# Resume is covered too (the unit is WantedBy=suspend.target), and it earns its
# place: suspending an *idle* T480 leaves both limits untouched, but a machine
# suspended under load came back at the firmware defaults, and this unit put them
# right 0.5s later. Idle resume needs nothing; loaded resume does.
#
#   TCC offset   how far BELOW TjMax the CPU starts throttling. The firmware
#                ships a large offset on some chassis (30 on a T480, i.e. throttle
#                at 70C); lowering it lets the chip run closer to TjMax.
#   MMIO PL1     sustained package power. The hardware enforces min(MSR, MMIO),
#                so on machines where the MSR copy is already generous only the
#                MMIO copy needs raising.
#
# This script does NOTHING without /etc/thinkpad-power-unlock.conf. That is
# deliberate: raising these limits makes a machine run hotter, the right values
# are chassis- and cooler-specific, and no default is safe to guess for someone
# else's hardware. Install the unit, write the config, then it applies.
set -u

CONF=${POWER_UNLOCK_CONF:-/etc/thinkpad-power-unlock.conf}

if [ ! -f "$CONF" ]; then
    echo "No $CONF -- nothing to apply."
    echo "Write one to raise the limits. See 'Raising the power limits' in the README."
    exit 0
fi

# Sourced as shell, but only after bash -n passes -- the same guard thinkfan-ex
# and chargewatch use, so a typo in the config cannot wreck the shell.
if ! bash -n "$CONF" 2>/dev/null; then
    echo "FAIL $CONF is not valid shell; refusing to source it."
    exit 1
fi
# shellcheck disable=SC1090
. "$CONF"

TCC_OFFSET=${TCC_OFFSET:-}
PL1_UW=${PL1_UW:-}

if [ -z "$TCC_OFFSET" ] && [ -z "$PL1_UW" ]; then
    echo "$CONF sets neither TCC_OFFSET nor PL1_UW -- nothing to apply."
    exit 0
fi

TCC=$(echo /sys/devices/pci0000:00/*/tcc_offset_degree_celsius)
PL1=/sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw

# The powercap and processor_thermal devices are bound by drivers that may not
# have probed yet when this unit runs. Wait, briefly, rather than failing.
for _ in $(seq 1 20); do
    [ -w "$TCC" ] && [ -w "$PL1" ] && break
    sleep 0.5
    TCC=$(echo /sys/devices/pci0000:00/*/tcc_offset_degree_celsius)
done

# TjMax is not 100 on every part, so read it rather than assuming: the offset is
# relative to whatever this chassis actually uses.
tjmax() {
    local f
    for f in /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_crit; do
        [ -f "$f" ] && { echo $(( $(cat "$f") / 1000 )); return; }
    done
    echo ""
}

rc=0
apply() { # path wanted label
    [ -z "$2" ] && return 0
    printf '%s\n' "$2" > "$1" 2>/dev/null
    got=$(cat "$1" 2>/dev/null)
    if [ "$got" = "$2" ]; then
        echo "ok   $3 = $got"
    else
        echo "FAIL $3 = ${got:-<unreadable>} (wanted $2)"
        rc=1
    fi
}

apply "$TCC" "$TCC_OFFSET" "TCC offset"
apply "$PL1" "$PL1_UW" "MMIO PL1 (uW)"

tj=$(tjmax)
if [ -n "$tj" ] && [ -n "$TCC_OFFSET" ]; then
    echo "     throttle point is now $(( tj - TCC_OFFSET ))C (TjMax $tj - offset $TCC_OFFSET)"
fi

# Firmware can claw these back under sustained load, not just at boot. It is
# intermittent: observed once in three identical runs, then absent across a full
# 300s all-core + dGPU run. Re-run this unit to reapply; see the README.
exit $rc
