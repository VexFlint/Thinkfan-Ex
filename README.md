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
</ul>

<h2>License</h2>
<p>This project is licensed under the MIT License.</p>
<h2>Author</h2>
<p>Bruno Bellizzi Grande</p>
<p><em>Last updated: March 10, 2025</em></p>
