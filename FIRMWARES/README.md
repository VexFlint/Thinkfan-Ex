# FIRMWARES

Working directory for the UEFI setup-form (IFR) extraction described in
[`../BIOS-MOD.md`](../BIOS-MOD.md).

Everything here is **read-only analysis of a vendor firmware image**. Nothing in
this directory has ever been written to the machine, and no tool here has a
write path to firmware.

Only `advanced-menu-digest.txt` is committed. The firmware image, the 157 MB
unpacked tree and the 1.3 MB raw IFR dump are ignored — large, derived, and not
ours to redistribute. Regenerate them in about two minutes:

```bash
# 1. tools
curl -sLO https://github.com/LongSoft/IFRExtractor-RS/releases/download/v1.6.1/ifrextractor_1.6.1_linux.zip
curl -sLO https://github.com/LongSoft/UEFITool/releases/download/A75/UEFIExtract_NE_A75_x64_linux.zip
unzip -o -q ifrextractor_1.6.1_linux.zip; unzip -o -q UEFIExtract_NE_A75_x64_linux.zip
chmod +x ifrextractor uefiextract

# 2. the BIOS package matching the running firmware
#    n24uj41w.exe == BIOS 1.54 == N24ET79W. Check yours first:
#      sudo dmidecode -s bios-version
#    Other builds: n24uj40w=1.53, n24uj42w=1.55, n24uj43w=1.56
#    Readmes at https://download.lenovo.com/pccbbs/mobiles/n24ur<NN>w.html
curl -sLO https://download.lenovo.com/pccbbs/mobiles/n24uj41w.exe
innoextract -e -s -d inno n24uj41w.exe
cp inno/code*/N24ET79W/*.FL1 N24ET79W.FL1

# 3. unpack, then extract the Setup module's forms
./uefiextract N24ET79W.FL1 all
cp "$(find N24ET79W.FL1.dump -type d -name '* Setup' | head -1)/body.bin" setup_body.bin
./ifrextractor setup_body.bin
```

That produces `setup_body.bin.1.0.en-US.uefi.ifr.txt` — 21,626 lines, one
formset titled **"Intel Advanced Menu"**, 1,727 `OneOf` and 1,147 `Numeric`
settings, and 791 `SuppressIf` blocks.

The offsets it reports are **firmware-version specific**. A number from a
different BIOS revision, or from someone else's T480, is not a number — it is a
coin flip against the thing that decides whether the laptop turns on.
