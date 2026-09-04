#!/usr/bin/env bash
#
# chargewatch.sh — USB-C PD charge-rate monitor for ThinkPad T480 / T480s
#
# Companion tool for the thinkfan-ex suite (github.com/VexFlint/Thinkfan-Ex).
# Read-only: no EC writes, no daemon, nothing to uninstall.
#
# WHAT THIS CAN AND CANNOT SEE
#
#   The T480 charges only over USB-C PD, but the embedded controller does the
#   PD negotiation in firmware and does NOT hand the negotiated contract (the
#   RDO) to the OS. The kernel exposes a generic "Mains" supply node.
#
#   Where the firmware DOES publish a UCSI device (USBC000 + ucsi_acpi bound,
#   which happens on newer kernels), /sys/class/typec/ carries the charger's
#   advertised source capabilities — the PDO menu it offers. That is not the
#   contract, but it is a hard upper bound, and it beats any inference: if the
#   brick advertises 100 W, no ceiling you hit is the brick's fault. This
#   script prints those PDOs when they exist and skips the guesswork.
#
#   Without UCSI the negotiated rate is INFERRED, not read:
#
#       adapter output  >=  (power into the batteries) + (SoC package power)
#
#   That is a floor. Platform overhead not covered by RAPL — panel, SSD, USB,
#   VRM losses — adds roughly 5-15 W on top. Use -probe for a tighter bound.
#
#   HOW SATURATION ACTUALLY LOOKS
#
#   When the adapter runs out of headroom the EC does NOT let the packs
#   discharge first — it tapers charge current to zero and the status goes
#   "Not charging". Discharging-while-plugged-in is the second stage, and on
#   a 45 W brick you may never reach it. So the first-stage signal is: on AC,
#   below the resume threshold, and still not taking charge. That is what
#   -probe trips on, and what the verdict line reports.
#
#   Power Bridge: the T480 has TWO batteries (internal BAT0 + external BAT1)
#   and the charge controller picks which to feed, so this sums ALL BAT*
#   nodes. Reading only BAT0 will happily report 0 W while BAT1 charges.
#
# Usage:
#   chargewatch [-once|-watch|-probe] [-interval N] [-csv FILE] [-help]
#   (or ./chargewatch.sh, when running from the cloned repo)
#
#   -once           one reading, then exit
#   -watch          refresh continuously (default)
#   -probe          load the CPU until the adapter saturates, to bound the
#                   negotiated ceiling empirically. HEATS THE MACHINE.
#   -interval N     seconds between samples (default: 2)
#   -csv FILE       append timestamped samples as CSV
#   -help           this text
#
# Optional config: /etc/chargewatch.conf, sourced only after `bash -n`
# passes — same guard thinkfan-ex uses so a typo can't wreck your shell.

set -euo pipefail

# ---- config (UPPERCASE, overridable via /etc/chargewatch.conf) ----
INTERVAL="${INTERVAL:-2}"
CSV_LOG="${CSV_LOG:-}"
MODE="watch"
PROBE_SECONDS="${PROBE_SECONDS:-45}"            # how long -probe holds load
PLATFORM_OVERHEAD_LOW="${PLATFORM_OVERHEAD_LOW:-5}"    # W invisible to RAPL, low
PLATFORM_OVERHEAD_HIGH="${PLATFORM_OVERHEAD_HIGH:-15}" # W invisible to RAPL, high
MACHINE_MAX_W="${MACHINE_MAX_W:-65}"            # most this chassis will ever
                                                # negotiate (T480: 20V/3.25A)
RAPL_MAX="${RAPL_MAX:-262143328850}"            # fallback only; main reads the
                                                # real max_energy_range_uj below

CONF="${CHARGEWATCH_CONF:-/etc/chargewatch.conf}"
if [[ -r "$CONF" ]]; then
    if bash -n "$CONF" 2>/dev/null; then
        # shellcheck disable=SC1090
        source "$CONF"
    else
        echo "chargewatch: WARNING — $CONF has a syntax error, ignoring it" >&2
    fi
fi

# ---- paths (overridable for testing against a synthetic sysfs tree) ----
PS_ROOT="${CHARGEWATCH_PS_ROOT:-/sys/class/power_supply}"
RAPL_ROOT="${CHARGEWATCH_RAPL_ROOT:-/sys/class/powercap}"
TYPEC_ROOT="${CHARGEWATCH_TYPEC_ROOT:-/sys/class/typec}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -once)     MODE="once" ;;
        -watch)    MODE="watch" ;;
        -probe)    MODE="probe" ;;
        -interval) INTERVAL="${2:?-interval needs a number}"; shift ;;
        -csv)      CSV_LOG="${2:?-csv needs a file path}"; shift ;;
        -help|-h|--help)
            # Print the header block: line 2 until the first non-comment line,
            # so growing the header can never leak code into the help text.
            sed -n '2,${/^#/!q; s/^# \{0,1\}//p;}' "$0"
            exit 0
            ;;
        *)  echo "chargewatch: unknown option '$1' (see -help)" >&2; exit 1 ;;
    esac
    shift
done

if [[ ! "$INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "chargewatch: -interval wants seconds, got '$INTERVAL'" >&2
    exit 1
fi

# ---- primitives ----

# `read` is a builtin, so this costs no fork — there are ~20 nodes per refresh.
# sysfs nodes are single-line; a file with no trailing newline still fills $v,
# so read's exit status is deliberately ignored.
read_raw() {
    local v=""
    [[ -r "$1" ]] || { echo ""; return 0; }
    { read -r v < "$1"; } 2>/dev/null || :
    echo "$v"
}

# microunits -> base units, 3dp. Empty/garbage reads collapse to 0 rather
# than blowing up the arithmetic downstream.
to_unit() {
    local v="${1:-}"
    [[ "$v" =~ ^-?[0-9]+$ ]] || { echo "0.000"; return; }
    awk -v v="$v" 'BEGIN { printf "%.3f", v / 1000000 }'
}

fadd() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { printf "%.3f", a + b }'; }
fgt()  { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { exit !(a > b) }'; }

# ---- battery discovery (ALL packs — Power Bridge) ----

list_batteries() {
    local d found=0
    for d in "$PS_ROOT"/BAT*; do
        [[ -d "$d" ]] || continue
        echo "$d"
        found=1
    done
    # Some kernels name ThinkPad packs differently; fall back to type=Battery
    if [[ "$found" -eq 0 ]]; then
        for d in "$PS_ROOT"/*; do
            [[ -d "$d" ]] || continue
            [[ "$(read_raw "$d/type")" == "Battery" ]] && echo "$d"
        done
    fi
}

# Echoes "watts volts amps" for one pack. Watts is SIGNED against the pack:
# positive = energy going in, negative = pack is being drained.
battery_power() {
    local b="$1" status volts amps watts
    status="$(read_raw "$b/status")"
    volts="$(to_unit "$(read_raw "$b/voltage_now")")"
    amps="$(to_unit "$(read_raw "$b/current_now")")"

    if [[ -r "$b/power_now" ]]; then
        watts="$(to_unit "$(read_raw "$b/power_now")")"
        # Some ThinkPad packs populate power_now but leave current_now at 0.
        # W/V is exact for DC, and beats printing "34.988 W at 0.000 A".
        if [[ "$amps" == "0.000" ]] && fgt "$volts" 0; then
            amps="$(awk -v w="$watts" -v v="$volts" 'BEGIN { printf "%.3f", w/v }')"
        fi
    else
        watts="$(awk -v v="$volts" -v a="$amps" 'BEGIN { printf "%.3f", v*a }')"
    fi

    # ACPI on ThinkPads reports magnitude only; direction lives in status.
    # Normalise so callers can just sum.
    watts="${watts#-}"
    amps="${amps#-}"
    if [[ "$status" == "Discharging" ]]; then
        watts="-$watts"
    elif [[ "$status" != "Charging" ]]; then
        # Full / Not charging / Unknown — not moving energy. Zero the current
        # too: some ECs leave a stale current_now, and "0.000 W / 1.500 A" on
        # the same row just makes the table look broken.
        watts="0.000"
        amps="0.000"
    fi

    echo "$watts $volts $amps"
}

# Capacity below which this pack SHOULD be accepting charge while on AC.
# With conservation mode the EC idles anywhere inside the start..end band, so
# the start (resume) threshold is the honest floor, not the end threshold.
resume_below() {
    local b="$1" start end
    start="$(read_raw "$b/charge_control_start_threshold")"
    if [[ "$start" =~ ^[0-9]+$ ]] && (( start > 0 )); then
        echo "$start"
        return 0
    fi
    end="$(read_raw "$b/charge_control_end_threshold")"
    if [[ "$end" =~ ^[0-9]+$ ]] && (( end > 0 )); then
        echo "$end"
        return 0
    fi
    echo 100
}

# Echoes 1 if NO pack is charging while at least one sits below its resume
# threshold — the EC withholding current is the first stage of adapter
# saturation, well before anything starts discharging. Caller must already
# know AC is online.
#
# Power Bridge feeds ONE pack at a time, so an idle pack next to a charging
# one is normal sequencing, not a starved adapter: a single "Charging" pack
# anywhere proves the EC still has headroom to give. The blind spot that
# leaves is a pack charging at a trickle because the budget is nearly spent —
# that shows up as falling charge power, not in the status field.
packs_starved() {
    local b status cap idle=0
    while read -r b; do
        [[ -n "$b" ]] || continue
        status="$(read_raw "$b/status")"
        if [[ "$status" == "Charging" ]]; then
            echo 0
            return 0
        fi
        [[ "$status" == "Discharging" ]] && continue
        cap="$(read_raw "$b/capacity")"
        if [[ "$cap" =~ ^[0-9]+$ ]] && (( cap < $(resume_below "$b") )); then
            idle=1
        fi
    done < <(list_batteries)
    echo "$idle"
}

ac_online() {
    local d type
    for d in "$PS_ROOT"/*; do
        [[ -d "$d" ]] || continue
        type="$(read_raw "$d/type")"
        case "$type" in
            Mains|USB*)
                if [[ "$(read_raw "$d/online")" == "1" ]]; then
                    echo "$d"
                    return 0
                fi
                ;;
        esac
    done
    echo ""
}

# ---- SoC package power via RAPL (same source powerwatch.sh uses) ----

RAPL_PKG=""
find_rapl() {
    local d
    for d in "$RAPL_ROOT"/intel-rapl:*; do
        [[ -d "$d" ]] || continue
        [[ "$(read_raw "$d/name")" == "package-0" ]] || continue
        [[ -r "$d/energy_uj" ]] || continue   # root-only on post-PLATYPUS kernels
        echo "$d/energy_uj"
        return 0
    done
    echo ""
}

# Samples package power over $1 seconds. Echoes watts, or "" if RAPL is
# unreadable (very common as non-root — that is why powerwatch.sh wants sudo).
package_watts() {
    local window="${1:-0.5}" f e1 e2 t1 t2
    f="$RAPL_PKG"
    [[ -n "$f" && -r "$f" ]] || { echo ""; return; }

    e1="$(read_raw "$f")"; t1="$(date +%s.%N)"
    sleep "$window"
    e2="$(read_raw "$f")"; t2="$(date +%s.%N)"

    [[ "$e1" =~ ^[0-9]+$ && "$e2" =~ ^[0-9]+$ ]] || { echo ""; return; }

    awk -v e1="$e1" -v e2="$e2" -v t1="$t1" -v t2="$t2" -v max="$RAPL_MAX" 'BEGIN {
        d = e2 - e1
        if (d < 0) d += max             # counter wrap (max_energy_range_uj)
        dt = t2 - t1
        if (dt <= 0) { print ""; exit }
        printf "%.2f", (d / 1000000) / dt
    }'
}

# ---- reporting ----

conservation_note() {
    local b="$1" start end resume=""
    end="$(read_raw "$b/charge_control_end_threshold")"
    start="$(read_raw "$b/charge_control_start_threshold")"
    if [[ -n "$end" && "$end" != "100" ]]; then
        if [[ -n "$start" && "$start" != "0" ]]; then
            resume=" (resumes below ${start}%)"
        fi
        echo "charge cap ${end}%${resume}"
    fi
    return 0
}

classify_adapter() {
    # $1 = floor estimate of adapter output in watts
    # $2 = 1 if the packs have stopped taking charge (no headroom left, either
    #      because the EC cut charge current or because they are discharging)
    # $3 = highest advertised PDO in watts, when UCSI exposes one
    local floor="$1" no_headroom="${2:-0}" advertised="${3:-}"

    # A read beats an estimate: if the charger told us what it can supply,
    # the only open question is who is imposing the ceiling.
    if [[ "$advertised" =~ ^[0-9]+$ ]] && (( advertised > 0 )); then
        if (( advertised >= MACHINE_MAX_W )); then
            echo "charger advertises ${advertised} W, at or above this machine's ${MACHINE_MAX_W} W ceiling — any limit you hit here is the EC's, not the adapter's"
        else
            echo "charger advertises only ${advertised} W, below the ${MACHINE_MAX_W} W this machine could take — the adapter is your ceiling"
        fi
        return 0
    fi

    if fgt "$floor" 65; then
        echo "above 65 W — check for a >65 W PD source or a bad reading"
    elif fgt "$floor" 45; then
        echo "must be a 65 W adapter (20V/3.25A) — floor already exceeds 45 W"
    elif [[ "$no_headroom" == "1" ]]; then
        echo "at its ceiling — the packs stopped taking charge at this load, so a 45 W or weaker PD source"
    elif fgt "$floor" 20; then
        echo "consistent with either 45 W or 65 W — load the CPU or run -probe to separate them"
    else
        echo "too little draw to tell — batteries near full or system idle"
    fi
}

sample_once() {
    local ts supply pkg
    ts="$(date '+%H:%M:%S')"
    supply="$(ac_online)"
    pkg="$(package_watts 0.4)"

    local total="0.000" any=0 charging=0
    local lines=()

    local b name watts volts amps status cap note
    while read -r b; do
        [[ -n "$b" ]] || continue
        any=1
        name="$(basename "$b")"
        read -r watts volts amps <<<"$(battery_power "$b")"
        status="$(read_raw "$b/status")"
        cap="$(read_raw "$b/capacity")"
        note="$(conservation_note "$b")"
        [[ "$status" == "Charging" ]] && charging=1
        total="$(fadd "$total" "$watts")"
        lines+=("$(printf '  %-5s %3s%%  %-11s %7s W  %6s V  %5s A%s' \
            "$name" "${cap:-?}" "${status:-?}" "$watts" "$volts" "$amps" \
            "${note:+   [$note]}")")
    done < <(list_batteries)

    if [[ "$any" -eq 0 ]]; then
        echo "chargewatch: no battery nodes under $PS_ROOT — nothing to read" >&2
        return 1
    fi

    if [[ -n "$supply" ]]; then
        echo "[$ts]  AC: online via $(basename "$supply") — USB-C PD (EC-negotiated)"
    else
        echo "[$ts]  AC: offline — running on battery"
    fi
    echo
    printf '%s\n' "${lines[@]}"
    echo
    printf '  %-5s        %-11s %7s W   <- power into the packs\n' "TOTAL" "" "$total"

    if [[ -n "$pkg" ]]; then
        printf '  %-5s        %-11s %7s W   <- SoC package (RAPL)\n' "CPU" "" "$pkg"
    else
        printf '  %-5s        %-11s %7s     <- RAPL unreadable (try sudo)\n' "CPU" "" "n/a"
    fi

    # Inferred adapter output — only meaningful while actually plugged in.
    local advertised; advertised="$(pd_max_watts "$(pd_caps_dir)")"

    local no_headroom=0
    if [[ -n "$supply" ]]; then
        if fgt "0" "$total"; then
            no_headroom=1                      # stage 2: already discharging
        else
            no_headroom="$(packs_starved)"     # stage 1: EC withholding current
        fi
    fi

    if [[ -n "$supply" && -n "$pkg" ]]; then
        local floor lo hi
        floor="$(fadd "$total" "$pkg")"
        lo="$(fadd "$floor" "$PLATFORM_OVERHEAD_LOW")"
        hi="$(fadd "$floor" "$PLATFORM_OVERHEAD_HIGH")"
        echo
        printf '  Adapter is delivering at least %s W (est. %s-%s W with platform overhead)\n' \
            "$floor" "$lo" "$hi"
        printf '  Verdict: %s\n' "$(classify_adapter "$floor" "$no_headroom" "$advertised")"

        # Two stages, in the order the EC actually goes through them.
        if fgt "0" "$total" ; then
            echo '  !! Batteries are DRAINING while plugged in — the adapter is saturated.'
            echo '     You are at the negotiated ceiling right now.'
        elif [[ "$no_headroom" == "1" ]]; then
            echo '  !! A pack is below its resume threshold and still NOT charging on AC —'
            echo '     the EC is withholding charge current. No headroom left at this load.'
        fi
    elif [[ -n "$supply" ]]; then
        echo
        echo '  (run as root for RAPL, otherwise the adapter estimate is unavailable)'
    fi

    if [[ "$charging" -eq 1 ]]; then
        local eta
        eta="$(eta_to_full "$total")"
        [[ -n "$eta" ]] && printf '\n  ETA to charge target: %s\n' "$eta"
    fi

    dump_pd_contract

    if [[ -n "$CSV_LOG" ]]; then
        [[ -f "$CSV_LOG" ]] || echo "timestamp,total_charge_w,package_w,ac_online" > "$CSV_LOG"
        echo "$(date '+%Y-%m-%d %H:%M:%S'),$total,${pkg:-},$([[ -n "$supply" ]] && echo 1 || echo 0)" >> "$CSV_LOG"
    fi
}

# Sums remaining capacity across ALL packs, divides by total charge power.
# "Full" means the conservation-mode cap when one is set — charging stops
# there, so counting up to 100% would inflate every estimate.
eta_to_full() {
    local total_w="$1" remaining=0 b now full end
    fgt "$total_w" 0 || { echo ""; return; }

    while read -r b; do
        [[ -n "$b" ]] || continue
        if [[ -r "$b/energy_now" && -r "$b/energy_full" ]]; then
            now="$(read_raw "$b/energy_now")"; full="$(read_raw "$b/energy_full")"
        elif [[ -r "$b/charge_now" && -r "$b/charge_full" ]]; then
            # µAh -> µWh using the pack's own voltage
            local v; v="$(read_raw "$b/voltage_now")"
            now="$(awk -v c="$(read_raw "$b/charge_now")" -v v="$v" 'BEGIN{printf "%.0f", c*(v/1000000)}')"
            full="$(awk -v c="$(read_raw "$b/charge_full")" -v v="$v" 'BEGIN{printf "%.0f", c*(v/1000000)}')"
        else
            continue
        fi
        [[ "$now" =~ ^[0-9]+$ && "$full" =~ ^[0-9]+$ ]] || continue

        end="$(read_raw "$b/charge_control_end_threshold")"
        if [[ "$end" =~ ^[0-9]+$ ]] && (( end > 0 && end < 100 )); then
            full="$(awk -v f="$full" -v e="$end" 'BEGIN{printf "%.0f", f*e/100}')"
        fi

        # A pack already above its cap (cap lowered after charging) must not
        # subtract from the total.
        remaining="$(awk -v r="$remaining" -v n="$now" -v f="$full" \
            'BEGIN{ d = f - n; if (d < 0) d = 0; printf "%.3f", r + d/1000000 }')"
    done < <(list_batteries)

    awk -v r="$remaining" -v w="$total_w" 'BEGIN {
        if (r <= 0 || w <= 0) { print ""; exit }
        m = (r / w) * 60
        if (m < 1) { print "<1 min"; exit }
        printf "~%d min", m
    }'
}

# Path of the partner's advertised source capabilities, or "" if no UCSI.
pd_caps_dir() {
    local d
    for d in "$TYPEC_ROOT"/*-partner/usb_power_delivery/source-capabilities; do
        if [[ -d "$d" ]]; then
            echo "$d"
            return 0
        fi
    done
    echo ""
}

# One "label volts amps watts" line per advertised PDO. The attributes sit
# three levels below usb_power_delivery/ — a shallower walk finds the
# directory and prints nothing, which is how this started out broken.
pd_pdos() {
    local caps="$1" d v a mn mx
    for d in "$caps"/*:fixed_supply; do
        [[ -d "$d" ]] || continue
        v="$(read_raw "$d/voltage")"; a="$(read_raw "$d/maximum_current")"
        [[ -n "$v" && -n "$a" ]] || continue
        awk -v v="${v%mV}" -v a="${a%mA}" \
            'BEGIN { printf "fixed %.1f %.2f %.0f\n", v/1000, a/1000, v*a/1000000 }'
    done
    for d in "$caps"/*:programmable_supply; do
        [[ -d "$d" ]] || continue
        mn="$(read_raw "$d/minimum_voltage")"; mx="$(read_raw "$d/maximum_voltage")"
        a="$(read_raw "$d/maximum_current")"
        [[ -n "$mx" && -n "$a" ]] || continue
        awk -v n="${mn%mV}" -v x="${mx%mV}" -v a="${a%mA}" \
            'BEGIN { printf "pps %.1f-%.1f %.2f %.0f\n", n/1000, x/1000, a/1000, x*a/1000000 }'
    done
}

# Highest advertised power in whole watts, or "" when UCSI is absent.
# Fixed PDOs only: a PPS APDO's V*A is a corner of its range, not a rating,
# and a PD 2.0 link cannot request one anyway.
pd_max_watts() {
    local caps="$1" kind v a w max=""
    [[ -n "$caps" ]] || { echo ""; return 0; }
    while read -r kind v a w; do
        [[ "$kind" == "fixed" ]] || continue
        [[ "$w" =~ ^[0-9]+$ ]] || continue
        [[ -z "$max" || "$w" -gt "$max" ]] && max="$w"
    done < <(pd_pdos "$caps")
    echo "$max"
}

dump_pd_contract() {
    local caps kind v a w printed=0
    caps="$(pd_caps_dir)"
    if [[ -z "$caps" ]]; then
        echo
        echo "  PD capabilities: not exposed (no UCSI partner node — the EC keeps it)"
        return 0
    fi

    echo
    echo "  Charger advertises (UCSI source capabilities — offered, not negotiated):"
    while read -r kind v a w; do
        [[ -n "$kind" ]] || continue
        printf '    %-5s %11s V  %5s A  %4s W\n' "$kind" "$v" "$a" "$w"
        printed=1
    done < <(pd_pdos "$caps")

    # Never print a bare header again: if the layout shifts, show the raw tree.
    if [[ "$printed" -eq 0 ]]; then
        echo "    (no PDOs parsed — raw dump below)"
        while read -r v; do
            printf '    %-42s %s\n' "${v#"$caps"/}" "$(read_raw "$v")"
        done < <(find "$caps" -maxdepth 3 -type f 2>/dev/null | grep -vE '/power/|uevent')
    fi
    return 0
}

# ---- probe: find the negotiated ceiling by saturating the adapter ----

LOAD_PIDS=()
stop_load() {
    local p
    for p in "${LOAD_PIDS[@]:-}"; do
        if [[ -n "$p" ]]; then
            # negative PID would need a process group; timeout forwards TERM
            # to its child, so killing the timeout wrapper is enough
            kill "$p" 2>/dev/null || true
        fi
    done
    LOAD_PIDS=()
}

cleanup() {
    stop_load
    tput cnorm 2>/dev/null || true
}
trap cleanup EXIT INT TERM

run_probe() {
    local supply
    supply="$(ac_online)"
    if [[ -z "$supply" ]]; then
        echo "chargewatch: -probe needs the charger plugged in." >&2
        exit 1
    fi
    if [[ -z "$RAPL_PKG" ]]; then
        echo "chargewatch: -probe needs RAPL access — re-run with sudo." >&2
        exit 1
    fi

    local cores; cores="$(nproc)"
    # A read still beats an estimate here: if UCSI already gave us the
    # advertised ceiling, the probe's own floor is corroborating evidence,
    # not the only evidence, and classify_adapter should say so.
    local advertised; advertised="$(pd_max_watts "$(pd_caps_dir)")"
    cat <<EOF
chargewatch -probe

Loading all $cores threads for up to ${PROBE_SECONDS}s to push the adapter to its
limit. The moment the batteries start DISCHARGING while plugged in, the
adapter has run out of headroom — that point bounds the negotiated contract.

This will get hot and spin the fan up. Ctrl+C aborts cleanly.

EOF
    sleep 2

    # If the packs are already being held off charge before any load, the
    # starvation signal is meaningless (full packs, a cap just reached, a
    # sleeping EC) and only the discharge test is left.
    local baseline_starved; baseline_starved="$(packs_starved)"
    if [[ "$baseline_starved" == "1" ]]; then
        echo "  note: packs are already not charging at idle — falling back to"
        echo "        the discharge test alone, which a 45 W brick may never hit."
        echo
    fi

    # Each worker carries its own hard deadline. If this script is SIGKILLed
    # (which no trap can catch), the loops still die on their own instead of
    # pegging every core until the user notices — worth the extra process.
    # The deadline is wall-clock, so it must clear the sampling loop with room
    # to spare: each pass is a 1 s RAPL window plus sysfs reads, and it is
    # slowest exactly when every core is pegged.
    local i deadline=$((PROBE_SECONDS * 2 + 15))
    for ((i = 0; i < cores; i++)); do
        timeout "$deadline" bash -c 'while :; do :; done' &
        LOAD_PIDS+=("$!")
    done

    local peak="0.000" trip="" total pkg combined b watts
    # Wall clock, not an iteration count: a pass costs more than the 1 s window
    # it sleeps, so counting passes silently overruns the workers' deadline.
    local t0=$SECONDS elapsed=0
    while (( elapsed < PROBE_SECONDS )); do
        pkg="$(package_watts 1)"
        total="0.000"
        while read -r b; do
            [[ -n "$b" ]] || continue
            read -r watts _ _ <<<"$(battery_power "$b")"
            total="$(fadd "$total" "$watts")"
        done < <(list_batteries)

        combined="$(fadd "$total" "${pkg:-0}")"
        fgt "$combined" "$peak" && peak="$combined"

        printf '\r  t=%2ds  packs %+7.3f W   cpu %5s W   adapter >= %6s W  ' \
            "$elapsed" "$total" "${pkg:-n/a}" "$combined"

        if fgt "0" "$total"; then
            trip="draining"
            break
        fi
        if [[ "$baseline_starved" != "1" && "$(packs_starved)" == "1" ]]; then
            trip="starved"
            break
        fi
        elapsed=$((SECONDS - t0))
    done

    stop_load
    echo; echo

    if [[ "$trip" == "draining" ]]; then
        cat <<EOF
  SATURATED (stage 2). The packs began discharging with the charger connected,
  so the adapter hit its ceiling at roughly ${peak} W measured (plus ${PLATFORM_OVERHEAD_LOW}-${PLATFORM_OVERHEAD_HIGH} W of
  platform overhead RAPL cannot see).

  $(classify_adapter "$peak" 1 "$advertised")
EOF
    elif [[ "$trip" == "starved" ]]; then
        cat <<EOF
  SATURATED (stage 1). The EC cut charge current to zero while a pack was still
  below its resume threshold — the adapter has no headroom left at roughly
  ${peak} W measured (plus ${PLATFORM_OVERHEAD_LOW}-${PLATFORM_OVERHEAD_HIGH} W of platform overhead RAPL cannot see).

  $(classify_adapter "$peak" 1 "$advertised")
EOF
    else
        cat <<EOF
  Never saturated — peak observed draw was ${peak} W, the packs kept charging
  and the EC never cut charge current. The adapter supplies at least that much.

  $(classify_adapter "$peak" 0 "$advertised")
EOF
    fi
}

# ---- main ----

RAPL_PKG="$(find_rapl)"
if [[ -n "$RAPL_PKG" ]]; then
    _rapl_max="$(read_raw "${RAPL_PKG%/energy_uj}/max_energy_range_uj")"
    if [[ "$_rapl_max" =~ ^[0-9]+$ ]] && (( _rapl_max > 0 )); then
        RAPL_MAX="$_rapl_max"
    fi
fi

case "$MODE" in
    once)  sample_once ;;
    probe) run_probe ;;
    watch)
        tput civis 2>/dev/null || true
        while true; do
            clear
            echo "chargewatch — T480 USB-C PD — refresh ${INTERVAL}s — Ctrl+C quits"
            echo
            sample_once || true
            sleep "$INTERVAL"
        done
        ;;
esac