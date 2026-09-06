#!/bin/bash
# fwmap - enumerate every firmware/hardware control surface this machine exposes,
# and write the lot to a directory you can diff against a later run.
#
#   sudo ./fwmap.sh [outdir]        # default /var/log/fwmap-<date>
#
# READ-ONLY BY CONSTRUCTION. There is no write path in this script, not even a
# commented-out one. Poking these registers is a separate job with its own gate:
# some of them (EC RAM especially) do not come back without a full power drain.
#
# The report header stamps BIOS, EC, microcode and kernel versions, because any
# of those changing invalidates a comparison against an older run -- and that is
# exactly the sort of thing you want stated rather than inferred three months on.
set -u
[ "$EUID" -ne 0 ] && { echo "Run as root (MSR, EC and efivar reads need it)."; exit 1; }

OUT=${1:-/var/log/fwmap-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"/{acpi,msr,pci,efi,ec}
echo "writing to $OUT"

have() { command -v "$1" >/dev/null 2>&1; }
note() { echo "$*" | tee -a "$OUT/report.txt"; }

# Load the EC window before the header, not with the rest of the EC section:
# the header reports the EC firmware string, and it cannot read it otherwise.
modprobe ec_sys write_support=0 2>/dev/null
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null

{
    echo "fwmap $(date '+%F %H:%M:%S')"
    echo "vendor    $(dmidecode -s system-manufacturer 2>/dev/null) $(dmidecode -s system-product-name 2>/dev/null)"
    echo "product   $(dmidecode -s system-version 2>/dev/null)"
    echo "BIOS      $(dmidecode -s bios-version 2>/dev/null) ($(dmidecode -s bios-release-date 2>/dev/null))"
    echo "EC        $(strings /sys/kernel/debug/ec/ec0/io 2>/dev/null | grep -oE 'N[0-9]{2}[A-Z]{2}[0-9]{2}[A-Z]' | head -1)"
    echo "CPU       $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)"
    echo "microcode $(grep -m1 microcode /proc/cpuinfo | cut -d: -f2- | xargs)"
    echo "kernel    $(uname -r)"
} > "$OUT/report.txt"

# ---- ACPI: the tables are where the OEM's real policy lives ----------------
if have acpidump && have acpixtract && have iasl; then
    ( cd "$OUT/acpi" && acpidump > acpidump.txt 2>/dev/null && acpixtract -a acpidump.txt >/dev/null 2>&1
      for f in *.dat; do iasl -d "$f" >/dev/null 2>&1; done )
    note "acpi      $(ls "$OUT"/acpi/*.dsl 2>/dev/null | wc -l) tables decompiled, $(cat "$OUT"/acpi/*.dsl 2>/dev/null | wc -l) lines"
else
    note "acpi      SKIPPED (need acpica: acpidump/acpixtract/iasl)"
fi

# ---- MSRs: read by name so the report says what each one means -------------
modprobe msr 2>/dev/null
python3 - "$OUT/msr/msr.txt" <<'PY'
import struct, sys
def rd(a, cpu=0):
    try:
        with open("/dev/cpu/%d/msr" % cpu, "rb") as f:
            f.seek(a); return struct.unpack("<Q", f.read(8))[0]
    except Exception:
        return None
REGS = [(0x0ce,"PLATFORM_INFO"),(0x150,"OC_MAILBOX"),(0x19c,"THERM_STATUS"),
        (0x1a0,"IA32_MISC_ENABLE"),(0x1a2,"TEMPERATURE_TARGET"),(0x1ad,"TURBO_RATIO_LIMIT"),
        (0x1b0,"ENERGY_PERF_BIAS"),(0x1fc,"POWER_CTL"),(0x606,"RAPL_POWER_UNIT"),
        (0x610,"PKG_POWER_LIMIT"),(0x614,"PKG_POWER_INFO"),(0x638,"PP0_POWER_LIMIT"),
        (0x64c,"TURBO_ACTIVATION_RATIO"),(0x64f,"CORE_PERF_LIMIT_REASONS"),
        (0x690,"RING_PERF_LIMIT_REASONS")]
out = open(sys.argv[1], "w")
for a, n in REGS:
    v = rd(a)
    out.write("0x%03x %-26s %s\n" % (a, n, ("0x%016x" % v) if v is not None else "unreadable"))
u = rd(0x606)
if u:
    pu = 1.0/(1 << (u & 0xf))
    l, i, t = rd(0x610), rd(0x614), rd(0x1a2)
    if l: out.write("\nPL1 %.2f W (en=%d clamp=%d)  PL2 %.2f W (en=%d)  LOCK=%d\n" %
                    ((l & 0x7fff)*pu, (l>>15)&1, (l>>16)&1, ((l>>32)&0x7fff)*pu, (l>>47)&1, (l>>63)&1))
    if i: out.write("TDP (thermal spec) %.2f W\n" % ((i & 0x7fff)*pu))
    if t: out.write("TjMax %d C, TCC offset %d C\n" % ((t>>16)&0xff, (t>>24)&0x3f))
p = rd(0xce)
if p: out.write("PLATFORM_INFO: prog TDP=%d prog ratio=%d prog TjMax=%d (1 = the knob exists)\n"
                % ((p>>29)&1, (p>>28)&1, (p>>30)&1))
out.close()
PY
note "msr       $(wc -l < "$OUT/msr/msr.txt") lines; PL1 lock state in msr/msr.txt"

# ---- powercap / DPTF / thermal --------------------------------------------
{
    for c in /sys/class/powercap/*/; do
        [ -f "$c/name" ] || continue
        echo "== $(basename "$c") ($(cat "$c/name"))"
        for f in "$c"constraint_*_name; do
            [ -e "$f" ] || continue
            b=${f%_name}
            echo "   $(cat "$f") = $(cat "${b}_power_limit_uw" 2>/dev/null) uW  max=$(cat "${b}_max_power_uw" 2>/dev/null)"
        done
    done
    echo; echo "== thermal zones"
    for z in /sys/class/thermal/thermal_zone*; do
        echo "   $(basename "$z") $(cat "$z/type" 2>/dev/null) $(cat "$z/temp" 2>/dev/null)"
    done
    P=/sys/bus/platform/devices/INT3400:00
    if [ -d "$P" ]; then
        echo; echo "== INT3400 DPTF"
        echo "   current_uuid: $(cat "$P"/uuids/current_uuid 2>/dev/null)"
        echo "   production_mode: $(cat "$P"/production_mode 2>/dev/null)"
        # ODVP are firmware-set policy variables. The power-unlock watchdog does
        # NOT correct these, so they survive a claw-back as evidence -- log them
        # alongside a burnboth run with the watchdog stopped.
        for i in $(seq 0 19); do [ -e "$P/odvp$i" ] && printf '   odvp%-3s %s\n' "$i" "$(cat "$P/odvp$i")"; done
        [ -r "$P/data_vault" ] && cp "$P/data_vault" "$OUT/acpi/data_vault.bin" 2>/dev/null
    fi
    # The data vault is the OEM's own thermal policy: an LZMA-alone stream after
    # a "REPO" marker, holding one row of power limits per named configuration.
    # It is the most useful single artefact on the machine and it is unreadable
    # without unpacking, so unpack it here rather than leaving a blob behind.
    if [ -s "$OUT/acpi/data_vault.bin" ]; then
        python3 - "$OUT/acpi/data_vault.bin" "$OUT/dptf_policy.txt" <<'PYDV'
import sys, re, lzma, collections
raw = open(sys.argv[1], "rb").read()
i = raw.find(b"REPO")
if i < 0:
    sys.exit(0)
try:
    d = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(raw[i+4:])
except Exception as e:
    open(sys.argv[2], "w").write("decompress failed: %s\n" % e); sys.exit(0)
toks = [m.group().decode() for m in re.finditer(rb"[\x20-\x7e]{2,40}", d)]
tbl = collections.defaultdict(dict)
i = 0
while i < len(toks) - 3:
    if toks[i].startswith("\\_SB_"):
        key, val, cfg = toks[i+1], toks[i+2], toks[i+3]
        if re.fullmatch(r"[0-9]{1,6}", val) and re.fullmatch(r"[A-Z][A-Z0-9_]*", cfg):
            tbl[cfg][key] = int(val); i += 4; continue
    i += 1
KEYS = ["PL1PowerLimit","PL1MAX","PL1MIN","PL2PowerLimit","PL4PowerLimit","PL1TimeWindow","TccOffset"]
out = open(sys.argv[2], "w")
out.write("OEM DPTF policy, decoded from data_vault (%d bytes -> %d)\n" % (len(raw), len(d)))
out.write("_DC = on battery, _IA = Intel adaptive, _VGA = discrete GPU present\n\n")
out.write("%-24s%s\n" % ("config", "".join("%14s" % k for k in KEYS)))
for cfg in sorted(tbl):
    out.write("%-24s%s\n" % (cfg, "".join("%14s" % tbl[cfg].get(k, "-") for k in KEYS)))
out.close()
PYDV
        note "dptf      OEM policy decoded -> dptf_policy.txt ($(grep -c . "$OUT/dptf_policy.txt" 2>/dev/null || echo 0) lines)"
    fi
    PT=/sys/bus/pci/devices/0000:00:04.0
    if [ -d "$PT" ]; then
        echo; echo "== processor thermal device"
        echo "   tcc_offset = $(cat "$PT"/tcc_offset_degree_celsius 2>/dev/null)"
        for f in "$PT"/power_limits/*; do [ -e "$f" ] && echo "   $(basename "$f") = $(cat "$f")"; done
    fi
} > "$OUT/thermal.txt"
note "thermal   powercap + DPTF + zones -> thermal.txt"

# ---- EC: read-only window. write_support=1 is a different job entirely -----
# (module loaded near the top, so the header could report the EC version)
if [ -r /sys/kernel/debug/ec/ec0/io ]; then
    cp /sys/kernel/debug/ec/ec0/io "$OUT/ec/ec0.bin" 2>/dev/null
    hexdump -C "$OUT/ec/ec0.bin" > "$OUT/ec/ec0.hex" 2>/dev/null
    note "ec        256 bytes -> ec/ec0.bin (read-only)"
else
    note "ec        NOT READABLE (ec_sys missing?)"
fi
ls /proc/acpi/ibm/ > "$OUT/ec/thinkpad_acpi.txt" 2>/dev/null
for f in /proc/acpi/ibm/*; do echo "== $f"; cat "$f" 2>/dev/null; done >> "$OUT/ec/thinkpad_acpi.txt" 2>/dev/null

# ---- PCI / EFI / DMI -------------------------------------------------------
have lspci && { lspci -nn > "$OUT/pci/lspci.txt" 2>/dev/null; lspci -xxx > "$OUT/pci/config.txt" 2>/dev/null; }
note "pci       $(grep -c . "$OUT/pci/lspci.txt" 2>/dev/null || echo 0) devices"
ls /sys/firmware/efi/efivars/ > "$OUT/efi/varnames.txt" 2>/dev/null
note "efi       $(wc -l < "$OUT/efi/varnames.txt" 2>/dev/null || echo 0) variables (names only; values not dumped)"
have dmidecode && dmidecode > "$OUT/dmi.txt" 2>/dev/null
ls /sys/bus/wmi/devices/ > "$OUT/wmi.txt" 2>/dev/null
note "wmi       $(wc -l < "$OUT/wmi.txt" 2>/dev/null || echo 0) ACPI-WMI devices"

note ""
note "done. diff two runs with:  diff -r <old> <new>"
