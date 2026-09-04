#!/bin/bash
# fanbench - interactive fan level bench for ThinkPads.
# Live RPM readout, change level by keypress, builds the observed level->RPM table.
#
#   sudo systemctl stop thinkfan-extreme
#   sudo ./fanbench.sh
#
# Keys: 0-7 set level, a=auto, d=disengaged, f=full-speed, r=reset table, q=quit.

set -uo pipefail
FAN=${FAN:-/proc/acpi/ibm/fan}
[ "$EUID" -ne 0 ] && { echo "Run as root."; exit 1; }
[ -e "$FAN" ] || { echo "No $FAN"; exit 1; }
systemctl is-active --quiet thinkfan-extreme.service 2>/dev/null &&
    { echo "Stop thinkfan-extreme first: sudo systemctl stop thinkfan-extreme"; exit 1; }

declare -A seen                     # level -> "min/max/last" observed RPM
lvl=$(awk '/^level:/{print $2}' "$FAN")
skip=0                              # polls to ignore after a level change
SETTLE=${SETTLE:-4}

restore() { echo "level auto" > "$FAN" 2>/dev/null; printf '\e[?25h\n'; }
trap restore EXIT INT TERM
printf '\e[?25l'

cpu() {
    local hot=0 v
    for f in /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input; do
        v=$(cat "$f" 2>/dev/null); v=${v:-0}; [ "$v" -gt "$hot" ] && hot=$v
    done
    echo $(( hot / 1000 ))
}

while :; do
    rpm=$(awk '/^speed:/{print $2}' "$FAN")
    # The EC returns 0xFFFF and stops updating the tachometer mid-transition,
    # so drop the sentinel and ignore SETTLE polls after every level change.
    case "$rpm" in ''|*[!0-9]*|65535) rpm=""; skip=$SETTLE ;; esac
    if [ "$skip" -gt 0 ]; then
        skip=$(( skip - 1 ))
    elif [ -n "$rpm" ]; then
        IFS=/ read -r lo hi _ <<< "${seen[$lvl]:-$rpm/$rpm/$rpm}"
        [ "$rpm" -lt "$lo" ] && lo=$rpm; [ "$rpm" -gt "$hi" ] && hi=$rpm
        seen[$lvl]="$lo/$hi/$rpm"
    fi

    clear
    [ "$skip" -gt 0 ] && tag="settling ${skip}" || tag=""
    echo "fanbench   cpu $(cpu)C   level ${lvl}   ${rpm:-----} RPM   $tag"
    echo "-------------------------------------------------"
    printf "%-12s %7s %7s %7s\n" level min max last
    for k in 0 1 2 3 4 5 6 7 auto disengaged full-speed; do
        [ -n "${seen[$k]:-}" ] || continue
        IFS=/ read -r lo hi la <<< "${seen[$k]}"
        printf "%-12s %7s %7s %7s\n" "$k" "$lo" "$hi" "$la"
    done
    echo "-------------------------------------------------"
    echo "0-7 level  a auto  d disengaged  f full-speed  r reset  q quit"

    # The 1s poll doubles as the keypress timeout, so no background reader is needed.
    read -rsn1 -t 1 key || continue
    case "$key" in
        [0-7]) lvl=$key ;;
        a) lvl=auto ;;
        d) lvl=disengaged ;;
        f) lvl=full-speed ;;
        r) seen=(); continue ;;
        q) exit 0 ;;
        *) continue ;;
    esac
    skip=$SETTLE
    echo "level $lvl" > "$FAN" 2>/dev/null || echo "level $lvl rejected"
done
