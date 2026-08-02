# Thinkfan-Extreme Deployment Script

## Overview

This script automates the deployment and configuration of a custom fan control solution for ThinkPad laptops. It performs the following actions:

- **Root Access & ACPI Verification:** Ensures the script runs as root and that the ThinkPad ACPI module is configured with `fan_control=1`.
- **GRUB Boot Parameter Update:** Adds `thinkpad_acpi.fan_control=1` to the kernel boot parameters and runs `update-grub`.
- **Kernel Module Reloading:** Attempts to reload the `thinkpad_acpi` module (or advises a reboot if it’s built into the kernel).
- **Installation of Custom Fan Control Script:** Installs `thinkfan-ex` which:
  - Monitors temperature sensor files.
  - Maps temperatures to fan levels.
  - Supports command-line options:
    - **`-status`**: Displays current fan status and sensor temperature readings.
    - **`-config`**: Opens the configuration file (`/etc/thinkfan-extreme.conf`) for editing.
    - **`-uninstall`**: Removes the fan control setup (script, systemd service, GRUB changes, and bash completion).
    - **`-help` / `--help`**: Displays usage information.
- **Systemd Service Unit & Bash Completion:** Creates and enables a systemd service (`thinkfan-extreme.service`) and installs bash completion for ease of use.
- **Logging:** Detailed logs are written to `/var/log/thinkfan-extreme.log`.

<h2>Installation</h2>
<ol>
  <li>
    <strong>Download the Script:</strong> Save the deployment script (for example, as <code>/home/$USER/Downloads/thinkfan-extreme.sh</code>).
  </li>
  <li>
    <strong>Make It Executable:</strong>
    <pre><code>sudo chmod +x /home/$USER/Downloads/thinkfan-extreme.sh</code></pre>
  </li>
  <li>
    <strong>Run the Script as Root:</strong>
    <pre><code>sudo /home/$USER/Downloads/thinkfan-extreme.sh</code></pre>
  </li>
  <li>
    <strong>Reboot the System:</strong> A reboot is recommended to ensure all kernel and module changes are applied.
  </li>
</ol>
<h2>Example of config file</h2>
<p>Defaults live in <code>/etc/thinkfan-extreme.conf</code>. Every temperature is in
millidegrees Celsius (<code>70000</code> = 70&deg;C).</p>
<pre><code># Critical temperature. Above this the fan goes to "level disengaged",
# which bypasses the EC's RPM ceiling and runs the fan flat out.
# Set this as a genuine emergency rung, not a normal operating point:
# compare it against your CPU's TjMax (usually 100C), not against idle temps.
CRITICAL_TEMP=90000

# Downshift stickiness, in millidegrees. See "Hysteresis" below.
# Must be >= the gap between adjacent thresholds, or levels will flap.
HYSTERESIS=5000

# Temperature thresholds for each fan level.
declare -A level_threshold
level_threshold[0]=45000
level_threshold[1]=50000
level_threshold[2]=55000
level_threshold[3]=60000
level_threshold[4]=65000
level_threshold[5]=70000
level_threshold[6]=78000
level_threshold[7]=85000
</code></pre>
<p>Levels may be omitted &mdash; the ladder is built from whichever keys you define,
so skipping <code>level_threshold[4]</code> simply means level 4 is never used.</p>

<h2>Hysteresis</h2>
<p>A bare threshold is a single line: crossed going up, crossed going down, at the
same temperature. Because CPU temperature jitters by several degrees between reads,
any wobble sitting on a threshold makes the fan change level every polling interval &mdash;
audible pulsing and needless wear.</p>
<p><code>HYSTERESIS</code> splits that one line into two: a higher line to move
<em>up</em> a level, a lower line to fall back <em>down</em>. At level 5 with a
threshold of <code>70000</code> and <code>HYSTERESIS=5000</code>, the fan enters
level 5 at 70&deg;C but will not drop to level 4 until the temperature actually
reaches 65&deg;C.</p>
<p>Upward transitions are never delayed. Adding cooling quickly is safe; removing it
slowly is safe; the reverse would not be.</p>
<p>Pick a value at least as large as your typical temperature swing between polls,
otherwise the jitter still crosses both lines and the level flaps anyway. Larger
values make the fan quieter and lazier, but slower to wind down after a load ends.</p>

<h2>Tuning to your machine</h2>
<p>The shipped defaults are a starting point, not a universal curve. To calibrate:</p>
<pre><code>{ for z in /sys/class/thermal/thermal_zone*/; do echo "$z $(cat $z/type) $(cat $z/temp)"; done
  cat /proc/acpi/ibm/fan
  grep MHz /proc/cpuinfo
  sudo rdmsr 0x1b1; } 2>&amp;1 | tee ~/thermal-snapshot.txt
</code></pre>
<p>Run it once at idle and again after several minutes at full load
(<code>stress -c $(nproc)</code>), so the heatsink has saturated. Set the thresholds
across the range between those two figures, and set <code>CRITICAL_TEMP</code>
well above your sustained load temperature.</p>
<p>Bit 0 of MSR <code>0x1b1</code> tells you whether the package is thermally
throttling; bit 10 tells you whether it is merely power limited. A machine that is
power limited rather than thermally limited does not benefit from a more aggressive
fan curve.</p>

<h1>Thinkfan-Extreme Deep Dive</h1>
<p>This Bash script automates the deployment and configuration of a custom fan control solution for ThinkPad laptops. It ensures proper ACPI settings and installs a custom fan control script (<code>thinkfan-ex</code>), a systemd service unit, and bash completion for enhanced command-line usability.</p>
<h2>Features</h2>
<ul>
  <li><strong>Root Privilege Verification:</strong> The script checks that it’s run as root.</li>
  <li><strong>ACPI Configuration:</strong> Ensures <code>/etc/modprobe.d/thinkpad_acpi.conf</code> contains <code>fan_control=1</code> (with backup creation if needed).</li>
  <li><strong>GRUB Boot Parameter Update:</strong> Appends <code>thinkpad_acpi.fan_control=1</code> to the kernel boot parameters and runs <code>update-grub</code>.</li>
  <li><strong>Kernel Module Management:</strong> Reloads the <code>thinkpad_acpi</code> module if possible, or advises a reboot if the module is built into the kernel.</li>
  <li><strong>Custom Fan Control Script:</strong> Installs <code>thinkfan-ex</code> which:
    <ul>
      <li>Dynamically reads temperature sensor files.</li>
      <li>Maps temperatures to discrete fan levels (0 to 7, or “level disengaged” for critical temperatures).</li>
      <li>Supports command-line options:
        <ul>
          <li><code>-status</code>: Displays current fan status and sensor temperature readings.</li>
          <li><code>-config</code>: Opens the configuration file (<code>/etc/thinkfan-extreme.conf</code>) for editing.</li>
          <li><code>-uninstall</code>: Uninstalls the fan control setup, disables its systemd service, reverts GRUB changes, and removes bash completion.</li>
          <li><code>-help</code> or <code>--help</code>: Shows usage information.</li>
        </ul>
      </li>
    </ul>
  </li>
  <li><strong>Systemd Service Unit:</strong> Creates and enables <code>thinkfan-extreme.service</code> to run <code>thinkfan-ex</code> continuously at boot.</li>
  <li><strong>Bash Completion:</strong> Installs a bash completion file for streamlined command usage.</li>
  <li><strong>Logging:</strong> Detailed events are logged to <code>/var/log/thinkfan-extreme.log</code> for troubleshooting.</li>
</ul>
<h2>Requirements</h2>
<ul>
  <li><strong>ThinkPad ACPI Kernel Module:</strong> Must be loaded with <code>fan_control=1</code>.</li>
  <li><strong>Root Access:</strong> Both the deployment script and the installed components require root privileges.</li>
  <li><strong>GRUB Update:</strong> Kernel boot parameter changes will need a reboot to take effect.</li>
</ul>
<h2>Usage</h2>
<p>Once installed, the custom fan control script (<code>thinkfan-ex</code>) will run as a service at boot. It continuously monitors temperature sensors and adjusts fan speeds accordingly.</p>
<h3>Command-Line Options for <code>thinkfan-ex</code></h3>
<ul>
  <li>
    <strong><code>-status</code></strong>: Display the current fan control status and sensor temperature readings.
  </li>
  <li>
    <strong><code>-config</code></strong>: Open the configuration file (<code>/etc/thinkfan-extreme.conf</code>) for editing.
  </li>
  <li>
    <strong><code>-uninstall</code></strong>: Uninstall <code>thinkfan-ex</code>, disable its systemd service, revert GRUB changes, and remove bash completion.
  </li>
  <li>
    <strong><code>-help</code> or <code>--help</code></strong>: Show usage information and available options.
  </li>
</ul>
<h2>Uninstallation</h2>
<p>To remove the fan control setup, run:</p>
<pre><code>sudo thinkfan-ex -uninstall</code></pre>
<p>This command will:</p>
<ul>
  <li>Stop and disable the systemd service.</li>
  <li>Remove the <code>thinkfan-ex</code> script and bash completion.</li>
  <li>Revert the GRUB boot parameter changes.</li>
</ul>
<h2>Logging</h2>
<p>All events during deployment are logged to <code>/var/log/thinkfan-extreme.log</code>. Check this file for troubleshooting or to verify successful configuration. To continuously monitor the log, use:</p>
<pre><code>tail -f /var/log/thinkfan-extreme.log</code></pre>

<h2>Notes</h2>
<ul>
  <li>
    <strong>Module Reloading:</strong> If the <code>thinkpad_acpi</code> module is built into your kernel (and thus cannot be reloaded), a reboot is required for configuration changes to take effect.
  </li>
  <li>
    <strong>Fan Control Verification:</strong> After configuration, the script displays current fan settings from <code>/proc/acpi/ibm/fan</code>.
  </li>
  <li>
    <strong>Restoring automatic control:</strong> <code>thinkfan-ex</code> restores <code>level auto</code> via an <code>EXIT</code> trap, but <code>-uninstall</code> exits before that trap is installed, and a <code>SIGKILL</code> will not run it either. If the fan is left at a fixed level or disengaged, restore it manually:
    <pre><code>echo "level auto" | sudo tee /proc/acpi/ibm/fan</code></pre>
    For unattended machines, consider arming the EC watchdog so firmware reclaims control if the daemon dies:
    <pre><code>echo "watchdog 120" | sudo tee /proc/acpi/ibm/fan</code></pre>
  </li>
</ul>

<h2>Changelog</h2>
<h3>1.1</h3>
<ul>
  <li><strong>Fixed:</strong> an empty sensor read (some <code>hwmon</code> nodes return nothing while <code>cat</code> still exits 0) produced an empty value that aborted the control loop under <code>set -e</code>.</li>
  <li><strong>Fixed:</strong> reading <code>/sys/module/thinkpad_acpi/parameters/fan_control</code> aborted the installer when <code>thinkpad_acpi</code> is built into the kernel rather than loaded as a module.</li>
  <li><strong>Fixed:</strong> the default fan command was <code>auto</code>, which <code>/proc/acpi/ibm/fan</code> rejects; the valid command is <code>level auto</code>.</li>
  <li><strong>Fixed:</strong> a <code>grep</code> miss while reading the current level aborted the loop under <code>set -e</code>.</li>
  <li><strong>Fixed:</strong> <code>local error_code=$?</code> always captured 0, since <code>local</code> resets <code>$?</code>.</li>
  <li><strong>Fixed:</strong> <code>systemctl enable</code> armed the service for the next boot but never started it; now <code>enable --now</code>.</li>
  <li><strong>Fixed:</strong> the fallback configuration used when the config file fails its syntax check no longer diverges from the shipped defaults.</li>
  <li><strong>Added:</strong> <code>HYSTERESIS</code>, preventing the fan level from flapping on every threshold crossing.</li>
  <li><strong>Changed:</strong> redundant writes are skipped, so the log records real level changes instead of one entry per poll.</li>
  <li><strong>Changed:</strong> level sorting uses <code>mapfile</code> with <code>printf | sort</code> instead of an <code>IFS</code>-prefixed array assignment.</li>
</ul>

<h2>License</h2>
<p>This project is licensed under the MIT License.</p>
<h2>Author</h2>
<p>Bruno Bellizzi Grande</p>
<p><em>Last updated: August 1, 2026</em></p>
