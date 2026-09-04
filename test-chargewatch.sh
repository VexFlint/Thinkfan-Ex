#!/usr/bin/env bash
#
# test-chargewatch.sh — regression suite for chargewatch.sh
#
# chargewatch reads sysfs through four overridable roots:
#
#   CHARGEWATCH_PS_ROOT     /sys/class/power_supply
#   CHARGEWATCH_RAPL_ROOT   /sys/class/powercap
#   CHARGEWATCH_TYPEC_ROOT  /sys/class/typec
#   CHARGEWATCH_CONF        /etc/chargewatch.conf
#
# so every battery, adapter and PD state can be faked in a temp directory and
# asserted against. That is the whole point of this file: the interesting bugs
# in this tool are all "what does it say when the hardware is in state X", and
# state X is usually one you cannot reproduce on demand with a real charger.
#
# Usage:  ./test-chargewatch.sh [path/to/chargewatch.sh]
#
# No sudo, no real hardware, no CPU load — -probe is not exercised here
# because it pegs every core for PROBE_SECONDS. Test that one by hand.

set -uo pipefail          # deliberately not -e: a failed assertion must not
                          # abort the remaining cases

SCRIPT="${1:-./chargewatch.sh}"
[[ -r "$SCRIPT" ]] || { echo "cannot read $SCRIPT" >&2; exit 1; }
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0 CASE=""

# ---- fixture builders ----

reset_tree() {
    rm -rf "$TMP/ps" "$TMP/rapl" "$TMP/typec"
    mkdir -p "$TMP/ps/AC" "$TMP/rapl/intel-rapl:0" "$TMP/typec"
    printf 'Mains\n'      > "$TMP/ps/AC/type"
    printf '1\n'          > "$TMP/ps/AC/online"
    printf 'package-0\n'  > "$TMP/rapl/intel-rapl:0/name"
    printf '1000000000\n' > "$TMP/rapl/intel-rapl:0/energy_uj"
    printf '262143328850\n' > "$TMP/rapl/intel-rapl:0/max_energy_range_uj"
}

# pack NAME STATUS CAPACITY POWER_uW VOLTAGE_uV [END_THRESHOLD] [START_THRESHOLD]
# current_now is deliberately left at 0: the real T480 packs populate power_now
# and leave current_now empty, and the display derives amps from W/V.
pack() {
    local d="$TMP/ps/$1"
    mkdir -p "$d"
    printf 'Battery\n' > "$d/type"
    printf '%s\n' "$2" > "$d/status"
    printf '%s\n' "$3" > "$d/capacity"
    printf '%s\n' "$4" > "$d/power_now"
    printf '%s\n' "$5" > "$d/voltage_now"
    printf '0\n'       > "$d/current_now"
    printf '24000000\n' > "$d/energy_now"
    printf '45000000\n' > "$d/energy_full"
    [[ -n "${6:-}" ]] && printf '%s\n' "$6" > "$d/charge_control_end_threshold"
    [[ -n "${7:-}" ]] && printf '%s\n' "$7" > "$d/charge_control_start_threshold"
    return 0
}

# pdo INDEX VOLTAGE_mV CURRENT_mA   (fixed supply advertised by the charger)
pdo() {
    local d="$TMP/typec/port1-partner/usb_power_delivery/source-capabilities/$1:fixed_supply"
    mkdir -p "$d"
    printf '%s\n' "$2" > "$d/voltage"
    printf '%s\n' "$3" > "$d/maximum_current"
}

# pps MIN_mV MAX_mV MAX_mA
pps() {
    local d="$TMP/typec/port1-partner/usb_power_delivery/source-capabilities/9:programmable_supply"
    mkdir -p "$d"
    printf '%s\n' "$1" > "$d/minimum_voltage"
    printf '%s\n' "$2" > "$d/maximum_voltage"
    printf '%s\n' "$3" > "$d/maximum_current"
}

# The real charger from the T480 this was developed against: a 100 W PD source.
charger_100w() { pdo 1 5000mV 3000mA; pdo 2 9000mV 3000mA; pdo 3 12000mV 3000mA
                 pdo 4 15000mV 3000mA; pdo 5 20000mV 5000mA; pps 3300mV 21000mV 5000mA; }
charger_45w()  { pdo 1 5000mV 3000mA; pdo 2 9000mV 3000mA; pdo 3 12000mV 3000mA
                 pdo 4 15000mV 3000mA; }

run() {
    CHARGEWATCH_CONF=/nonexistent \
    CHARGEWATCH_PS_ROOT="$TMP/ps" \
    CHARGEWATCH_RAPL_ROOT="$TMP/rapl" \
    CHARGEWATCH_TYPEC_ROOT="$TMP/typec" \
    bash "$SCRIPT" "$@" 2>&1
}

# ---- assertions ----

case_start() { CASE="$1"; printf '\n%s\n' "-- $CASE"; }

check() {  # check LABEL PATTERN OUTPUT   — pattern must appear
    if grep -qE "$2" <<<"$3"; then PASS=$((PASS+1)); printf '   ok    %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '   FAIL  %s\n         wanted /%s/\n' "$1" "$2"; fi
}

check_not() {  # check_not LABEL PATTERN OUTPUT — pattern must NOT appear
    if grep -qE "$2" <<<"$3"; then
        FAIL=$((FAIL+1)); printf '   FAIL  %s\n         did not want /%s/\n' "$1" "$2"
        grep -E "$2" <<<"$3" | sed 's/^/         got: /'
    else PASS=$((PASS+1)); printf '   ok    %s\n' "$1"; fi
}

# ---------------------------------------------------------------------------

case_start "both packs charging, no PD data"
reset_tree
pack BAT0 Charging 62 17100000 11400000
pack BAT1 Charging 55 10260000 11400000
out="$(run -once)"
check     "totals both packs"        'TOTAL +27\.360 W' "$out"
check     "prints an ETA"            'ETA to charge target' "$out"
check_not "no false saturation"      '!!' "$out"

case_start "Power Bridge: one pack idle while the other charges"
# The regression that mattered most. An idle pack next to a charging one is
# the EC feeding them in sequence, NOT a starved adapter.
reset_tree
pack BAT0 "Not charging" 14 0        10378000 85
pack BAT1 Charging       28 34737000 11476000 85
out="$(run -once)"
check_not "no starvation warning"    '!!' "$out"
check_not "no ceiling verdict"       'at its ceiling' "$out"
check     "amps derived from W/V"    'BAT1.*3\.0[0-9]{2} A' "$out"
check     "idle pack keeps 0 A"      'BAT0.*0\.000 W.*0\.000 A' "$out"

case_start "genuine stage-1 starvation: nothing charging, both below cap"
reset_tree
pack BAT0 "Not charging" 14 0 10378000 85
pack BAT1 "Not charging" 28 0 11476000 85
out="$(run -once)"
check     "warns about withheld charge" 'NOT charging on AC' "$out"

case_start "conservation hysteresis band is not starvation"
reset_tree
pack BAT0 "Not charging" 78 0 11400000 80 75
pack BAT1 Full           85 0 11400000 85
out="$(run -once)"
check_not "no false alarm in band"   '!!' "$out"

case_start "stage 2: discharging while plugged in"
reset_tree
pack BAT0 Discharging 62 17100000 11400000
pack BAT1 Discharging 55 10260000 11400000
out="$(run -once)"
check     "warns about draining"     'DRAINING while plugged in' "$out"

case_start "UCSI present: 100 W charger"
reset_tree
pack BAT0 Charging 62 17100000 11400000
charger_100w
out="$(run -once)"
check     "reads advertised ceiling" 'advertises 100 W' "$out"
check     "blames the EC not the PSU" "machine's 65 W ceiling" "$out"
check     "lists the 20V PDO"        'fixed +20\.0 V +5\.00 A +100 W' "$out"
check     "shows PPS range"          'pps +3\.3-21\.0 V' "$out"
check_not "skips the inference path" 'consistent with either' "$out"

case_start "UCSI present: 45 W charger is the real ceiling"
reset_tree
pack BAT0 Charging 62 17100000 11400000
charger_45w
out="$(run -once)"
check     "names the adapter as limit" 'advertises only 45 W' "$out"

case_start "no UCSI node: falls back to inference"
reset_tree
# Needs both packs: the 45-vs-65 branch only engages above a 20 W floor.
pack BAT0 Charging 62 17100000 11400000
pack BAT1 Charging 55 10260000 11400000
out="$(run -once)"
check     "inference ladder runs"    'consistent with either 45 W or 65 W' "$out"
check     "explains the missing node" 'not exposed' "$out"

case_start "charge cap is respected by the ETA"
reset_tree
# 24 Wh of 45 Wh, capped at 50% -> target is 22.5 Wh, which the pack is ALREADY
# past. Remaining must clamp at zero, and with nothing left to charge the ETA
# line is suppressed rather than printed as 0 or, worse, negative.
pack BAT0 Charging 62 17100000 11400000 50
out="$(run -once)"
check_not "no ETA once past the cap" 'ETA to charge target' "$out"
check_not "never prints a minus ETA" 'ETA.*-[0-9]' "$out"

# Same pack, cap at 85%: now there IS something left, so the ETA reappears.
reset_tree
pack BAT0 Charging 62 17100000 11400000 85
out="$(run -once)"
check     "ETA returns below the cap" 'ETA to charge target: ~[0-9]+ min' "$out"

case_start "argument handling"
reset_tree
pack BAT0 Charging 62 17100000 11400000
out="$(run -once -interval abc)"
check     "rejects a non-numeric interval" 'interval wants seconds' "$out"
out="$(run -help)"
check     "help prints the header"   'chargewatch' "$out"
check_not "help leaks no code"       'set -euo pipefail|INTERVAL=' "$out"

# ---------------------------------------------------------------------------

printf '\n%s\n' "----------------------------------------"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
