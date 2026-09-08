# Next test: a second battery idle resume

Rewritten 2026-09-08 after the clean AC run landed. **The AC arm is closed.** Run
3 — fresh boot, `odvp0 = 0`, every precondition held — showed firmware reverting
MMIO PL1 and latching `odvp0` while the TCC offset never moved, which is the
clean confirmation the note used to owe. See "The AC resume revert is partial" in
FIRMWARE.md.

One thing is still owed, and it is on the other arm.

## The asymmetry rests on n=1 where it moves

"Battery takes TCC, AC does not" now stands on **four** AC idle resumes with TCC
untouched — three run as TCC arms plus the 19 W PL1 test — against **one**
battery capture with a per-row TCC reading. The side that actually moves is the
single observation. A second battery idle resume, repairer removed, is what takes
it off n=1.

**Predicts TCC goes 4 → 30 and stays 30**, with `odvp0` latching to 7 and MMIO
PL1 dipping 22 → 15 → 22. A TCC that holds at 4 would mean the battery capture
was the outlier and the asymmetry is not real.

## It needs a reboot

`odvp0` is spent at 7 on the current boot, and a run that starts latched is the
exact confound that spoiled AC run 2. Reboot first, then confirm **every** line
below before suspending:

    cat /sys/bus/platform/devices/INT3400:00/odvp0            # MUST be 0
    cat /sys/devices/pci0000:00/*/tcc_offset_degree_celsius   # want 4
    cat /sys/class/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw
                                                              # want 22000000
    cat /sys/class/power_supply/BAT0/charge_behaviour          # want [force-discharge]
    cat /sys/class/power_supply/BAT0/status                    # want Discharging
    systemctl is-active thinkpad-power-unlock-watch.service    # want inactive
    systemctl show suspend.target -p Wants | tr ' ' '\n' | grep power-unlock
                                                              # expect NO output

The original battery arm ran on `force-discharge` with the adapter physically
attached; match that rather than unplugging, so the only difference from the AC
arms is the power source the firmware sees.

## Clear the suspend path before the reboot, not after

    sudo rm /etc/systemd/system/suspend.target.wants/thinkpad-power-unlock.service
    systemctl show suspend.target -p Wants | tr ' ' '\n' | grep power-unlock
    # expect NO output -- verify the runtime graph, not just the disk

That symlink is persistent on disk, so removing it survives the reboot, while the
boot path (`multi-user.target.wants`, a separate symlink) still applies TCC 4 and
PL1 22 W at startup — the state this test needs anyway. Doing it pre-reboot means
the machine comes up already armed and the run needs no systemd step at all.
`daemon-reload` is redundant if you reboot straight after; the reboot reloads from
disk.

Note that `systemctl reenable` restores the unit to **all four** sleep targets
while this `rm` clears only `suspend.target` — see the restore section.

On tooling: `sudo systemctl reenable` ran fine from Claude on 2026-09-08, so the
old "the classifier blocks Claude from changing systemd units" warning is at
least not absolute. The `rm` step above has not been tried from Claude; if it is
refused, run it yourself.

## Dwell

Match the original battery arm's **12m15s**, or go longer — `time.monotonic()`
excludes suspended time, so a long sleep costs nothing against the 600 s budget.

Dwell is less load-bearing than it looked. AC run 3 reverted at 7m45s and the
19 W run at 14m41s, so the firmware acts across that whole range and there is no
untested band on AC. What makes a run informative is that firmware demonstrably
*acted* — PL1 caught at 15 W, `odvp0` latching — not the number on the clock. A
run where nothing moves at all is the uninformative one, which is what an 8 s
dwell risks.

## Run

    cd /home/vex/DEV/Thinkfan-Ex
    sudo ./clawwatch.py 600 resume-battery-idle-2 --no-load    # background it
    # let it take ~20s of baseline, re-check odvp0 is still 0, then:
    sudo systemctl suspend
    # wake with the power button after the full dwell

Stop the sampler with **SIGINT to the python pid** (not the sudo wrapper, and not
SIGTERM) or it dies without writing its capture summary:

    ps -eo pid,cmd | grep 'python3 ./clawwatch.py'
    sudo kill -INT <pid>

Read the revert off **TCC**, never off MMIO PL1: the kernel restores PL1 to its
pre-suspend value ~2 s after resume, so PL1 reads 22 W either way. `PkgW` in the
first post-resume sample and `SMI` from there on both lie across the boundary.

Use `systemctl suspend` and check for `PM: suspend entry (deep)` in the journal —
a run that hibernates instead would have `power-unlock` write the config value
and fake the result, since the `rm` above clears only `suspend.target`.

## Restore afterwards

    sudo systemctl reenable thinkpad-power-unlock.service
    sudo systemctl daemon-reload
    sudo /usr/local/sbin/thinkpad-power-unlock
    # verify TCC=4 and PL1=22000000
    # put BAT0 back: echo auto | sudo tee /sys/class/power_supply/BAT0/charge_behaviour

`reenable` restores the unit to all four sleep targets (suspend, hibernate,
hybrid-sleep, suspend-then-hibernate). The final `thinkpad-power-unlock` call
rewrites PL1 from the config, so it also undoes a distinctive-PL1 write; no
separate undo is needed. `odvp0` stays at 7 until the next reboot — that is the
latch, not a failure to restore.

Note: `/usr/local/sbin/thinkpad-power-unlock` is behind `power-unlock.sh` in this
repo (an older comment block, no functional difference). Reinstall it from the
repo if you want the corrected resume comment on disk.
