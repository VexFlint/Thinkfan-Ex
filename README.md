<h1>Thinkfan-Extreme Deployment Script</h1>

  <p>This Bash script automates the deployment and configuration of a custom fan control solution for ThinkPad laptops. It ensures proper ACPI settings and installs a custom fan control script (<code>thinkfan-ex</code>), a systemd service unit, and bash completion for enhanced command-line usability.</p>

  <h2>Features</h2>
  <ul>
    <li><strong>Root Privilege Verification:</strong> The script checks that it’s run as root.</li>
    <li><strong>ACPI Configuration:</strong> Ensures <code>/etc/modprobe.d/thinkpad_acpi.conf</code> contains <code>fan_control=1</code> (with backup).</li>
    <li><strong>GRUB Boot Parameter Update:</strong> Appends <code>thinkpad_acpi.fan_control=1</code> to the kernel boot parameters and runs <code>update-grub</code>.</li>
    <li><strong>Kernel Module Management:</strong> Reloads the <code>thinkpad_acpi</code> module if possible or advises a reboot.</li>
    <li><strong>Custom Fan Control Script:</strong> Installs <code>thinkfan-ex</code> which:
      <ul>
        <li>Dynamically reads temperature sensor files.</li>
        <li>Maps temperatures to discrete fan levels (0, 3, 5, and 7, or “level disengaged” for critical temperatures).</li>
        <li>Supports command-line options for displaying status and uninstallation.</li>
      </ul>
    </li>
    <li><strong>Systemd Service Unit:</strong> Creates and enables <code>thinkfan-extreme.service</code> to run <code>thinkfan-ex</code> continuously at boot.</li>
    <li><strong>Bash Completion:</strong> Installs a bash completion file for streamlined command usage.</li>
    <li><strong>Logging:</strong> Writes detailed logs to <code>/var/log/thinkfan-extreme.log</code>.</li>
  </ul>

  <h2>Requirements</h2>
  <ul>
    <li><strong>ThinkPad ACPI Kernel Module:</strong> Must be loaded with <code>fan_control=1</code>.</li>
    <li><strong>Root Access:</strong> Both the deployment script and the installed components require root privileges.</li>
    <li><strong>GRUB Update:</strong> Kernel boot parameter changes will need a reboot to take effect.</li>
  </ul>

  <h2>Installation</h2>
  <ol>
    <li>
      <strong>Download the Script:</strong>
      Save the script (for example, as <code>/usr/local/bin/thinkfan-extreme.sh</code>).
    </li>
    <li>
      <strong>Make It Executable:</strong>
      <pre><code>sudo chmod +x /usr/local/bin/thinkfan-extreme.sh</code></pre>
    </li>
    <li>
      <strong>Run the Script as Root:</strong>
      <pre><code>sudo /usr/local/bin/thinkfan-extreme.sh</code></pre>
    </li>
    <li>
      <strong>Reboot the System:</strong>  
      A reboot is recommended to ensure all kernel and module changes are applied.
    </li>
  </ol>

  <h2>Usage</h2>
  <p>Once installed, the custom fan control script (<code>thinkfan-ex</code>) will run as a service at boot. It continuously monitors the temperature sensors and adjusts fan speeds accordingly.</p>

  <h3>Command-Line Options for <code>thinkfan-ex</code></h3>
  <ul>
    <li>
      <strong><code>-status</code></strong>: Display the current fan control status and sensor temperature readings.
    </li>
    <li>
      <strong><code>-uninstall</code></strong>: Remove the <code>thinkfan-ex</code> script, disable its systemd service, revert GRUB changes, and remove the bash completion file.
    </li>
    <li>
      <strong><code>-help</code> or <code>--help</code></strong>: Show usage information and details on available options.
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
  <p>All events during the deployment are logged to <code>/var/log/thinkfan-extreme.log</code>. Review this log file for troubleshooting or to verify successful configuration.</p>

  <h2>Notes</h2>
  <ul>
    <li>
      <strong>Module Reloading:</strong> If the <code>thinkpad_acpi</code> module is built into your kernel (and thus not reloadable), a reboot is required for the configuration changes to take effect.
    </li>
    <li>
      <strong>Fan Control Verification:</strong> The script prints the current fan settings from <code>/proc/acpi/ibm/fan</code> after configuration.
    </li>
  </ul>

  <h2>License</h2>
  <p>This project is licensed under the MIT License.</p>

  <h2>Author</h2>
  <p>Bruno Bellizzi Grande</p>

  <p><em>Last updated: March 10, 2025</em></p>

</body>
</html>
