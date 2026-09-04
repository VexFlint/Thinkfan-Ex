#!/bin/bash
# sensors.sh - todos os sensores termicos em uma tabela so.
printf '%-13s %-26s %-9s %s\n' HWMON NOME LEITURA CAMINHO
printf '%.0s-' {1..96}; echo
for h in /sys/class/hwmon/hwmon*/; do
    n=$(cat "$h/name" 2>/dev/null) || continue
    b=$(basename "$h")
    found=0
    for f in "$h"temp*_input; do
        [ -f "$f" ] || continue
        v=$(cat "$f" 2>/dev/null); v=${v:-?}
        l=$(cat "${f%_input}_label" 2>/dev/null)
        printf '%-13s %-26s %-9s %s\n' "$b" "${n}${l:+ ($l)}" "$v" "$(basename "$f")"
        found=1
    done
    [ "$found" -eq 0 ] && printf '%-13s %-26s %-9s %s\n' "$b" "$n" "-" "sem temp*_input"
done
echo
printf '%-13s %-26s %s\n' ZONA TIPO LEITURA
printf '%.0s-' {1..96}; echo
for z in /sys/class/thermal/thermal_zone*/; do
    printf '%-13s %-26s %s\n' "$(basename "$z")" "$(cat "$z/type" 2>/dev/null)" "$(cat "$z/temp" 2>/dev/null)"
done
echo
echo "== ventoinha =="; cat /proc/acpi/ibm/fan | head -3
echo "== usados pela curva =="
for f in /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp*_input; do
    [ -f "$f" ] && echo "  $(cat "${f%_input}_label" 2>/dev/null): $(cat "$f")"
done
