# Next test: the one run still owed on the resume revert

Rewritten 2026-09-08 after the AC-idle arm was run. The original question — does
an AC idle resume revert? — is **answered**: it reverts MMIO PL1 and latches
`odvp0`, but spares the TCC offset. See "The AC resume revert is partial" in
FIRMWARE.md. The kernel-restore question below has since been answered too. **One
run is still owed**, it needs a reboot, and it needs `power-unlock` out of the
suspend path.

## 1. Clean confirmation of the TCC hold — needs a reboot

Neither AC run was individually clean. Run 1 had `odvp0 = 0` but only 8 s of
dwell; run 2 matched the battery arm's dwell but started with `odvp0` already
latched at 7. The defects do not overlap and the argument in FIRMWARE.md stands
on that, but one run settles it outright.

Reboot, then hold **every** precondition below and use a **long** dwell.

    cat /sys/bus/platform/devices/INT3400:00/odvp0            # MUST be 0
    cat /sys/devices/pci0000:00/*/tcc_offset_degree_celsius   # want 4
    cat /sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw
                                                              # want 22000000
    cat /sys/class/power_supply/AC/online                      # want 1
    cat /sys/class/power_supply/BAT0/charge_behaviour           # want [auto]
    cat /sys/class/power_supply/BAT0/status                     # must NOT be Discharging
    systemctl is-active thinkpad-power-unlock-watch.service     # want inactive

**Predicts TCC holds at 4.** A TCC of 30 would overturn the section instead, and
would mean the dwell/latch pair was hiding something after all.

## 2. ~~Is the kernel what restores MMIO PL1?~~ ANSWERED 2026-09-08

Run and confirmed: **yes, and it replays a cache.** MMIO PL1 was set to a
distinctive 19000000, `power-unlock` taken out of the suspend path, AC, idle,
14m41s deep suspend. Firmware reverted it to 15 W and **19 W came back**, not the
22 W the config holds. See "Confirmed by measurement" in FIRMWARE.md.

## A second battery resume would also be worth having

The asymmetry rests on three AC captures — two run as TCC arms plus the 19 W PL1
run, all with TCC untouched — against **one** battery capture with a per-row TCC
reading. A second battery idle resume, repairer removed, would move "battery
takes TCC, AC does not" off n=1 on the side that actually moves.

## The one step that needs a human

The classifier blocks Claude from changing systemd units:

    sudo rm /etc/systemd/system/suspend.target.wants/thinkpad-power-unlock.service
    sudo systemctl daemon-reload
    systemctl show suspend.target -p Wants | tr ' ' '\n' | grep power-unlock
    # expect NO output -- verify the runtime graph, not just the disk

## Run

    cd /home/vex/DEV/Thinkfan-Ex
    sudo ./clawwatch.py 600 <label> --no-load     # background it
    # let it take ~20s of baseline, then:
    sudo systemctl suspend
    # wake with the power button after TWO FULL MINUTES, not eight seconds

`time.monotonic()` excludes suspended time, so the 600 s budget survives the nap.
Stop the sampler with **SIGINT to the python pid** (not the sudo wrapper, and not
SIGTERM) or it dies without writing its capture summary:

    ps -eo pid,cmd | grep 'python3 ./clawwatch.py'
    sudo kill -INT <pid>

Read the revert off **TCC**, never off MMIO PL1: the kernel restores PL1 to its
pre-suspend value ~2 s after resume, so PL1 reads 22 W either way. `PkgW` in the
first post-resume sample and `SMI` from there on both lie across the boundary.

## Restore afterwards

    sudo systemctl reenable thinkpad-power-unlock.service
    sudo systemctl daemon-reload
    sudo /usr/local/sbin/thinkpad-power-unlock
    # verify TCC=4 and PL1=22000000

`reenable` restores the unit to **all four** sleep targets (suspend, hibernate,
hybrid-sleep, suspend-then-hibernate), while the removal step above takes it out
of `suspend.target` only. So after a removal the other three still hold it: a
plain `systemctl suspend` is unaffected, but a run that hibernates instead would
have `power-unlock` write the config value and fake the result. Use `systemctl
suspend` and check for `PM: suspend entry (deep)` in the journal.

The final `thinkpad-power-unlock` call rewrites PL1 from the config, so it also
undoes a distinctive-PL1 write; no separate undo is needed.

Note: `/usr/local/sbin/thinkpad-power-unlock` is behind `power-unlock.sh` in this
repo (an older comment block, no functional difference). Reinstall it from the
repo if you want the corrected resume comment on disk.
