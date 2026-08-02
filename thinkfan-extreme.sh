#!/bin/bash
# thinkfan-extreme-fix: Deploy the thinkfan-ex fan control script and ensure proper ThinkPad ACPI configuration.
#
# This script does the following:
#   1. Verifies that it is run as root.
#   2. Checks /etc/modprobe.d/thinkpad_acpi.conf for the line "fan_control=1".
#      If missing, it backs up the file and appends the line.
#   3. Ensures the kernel boot parameter "thinkpad_acpi.fan_control=1" is set in GRUB.
#   4. Creates/updates the "thinkfan-ex" script in /usr/local/bin.
#      The script reads sensor data (dynamically detecting the correct sensor paths),
#      maps temperatures to fan levels, and writes to /proc/acpi/ibm/fan using proper quoting.
#   5. Creates a systemd service unit file to run thinkfan-ex as a service.
#   6. Installs a bash completion file so that autocomplete is available for thinkfan-ex options.
#   7. Prints a reminder to reboot.
#
# Requirements:
#   - The thinkpad_acpi kernel module must be loaded with fan_control=1.
#   - This script (and the installed thinkfan-ex script) must be run as root.
# Version: 1.1
# Author: Bruno Bellizzi Grande
# Date: 2026-08-01

set -euo pipefail

LOG_FILE="/var/log/thinkfan-extreme-fix.log"
THINKFAN_EX_SCRIPT="/usr/local/bin/thinkfan-ex"
ACPI_CONF="/etc/modprobe.d/thinkpad_acpi.conf"
SYSTEMD_UNIT="/etc/systemd/system/thinkfan-extreme.service"
COMPLETION_FILE="/etc/bash_completion.d/thinkfan-ex"
fan_control_value=$(cat /sys/module/thinkpad_acpi/parameters/fan_control 2>/dev/null || echo "unknown")

# Log event function
log_event() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Ensure the script is run as root.
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root. Exiting."
    exit 1
fi

log_event "Starting Thinkfan-Extreme deployment."

# Check/update the ThinkPad ACPI configuration file.
if [ -f "$ACPI_CONF" ]; then
    if ! grep -q "fan_control=1" "$ACPI_CONF"; then
        log_event "fan_control=1 not found in $ACPI_CONF. Updating configuration."
        cp "$ACPI_CONF" "${ACPI_CONF}.bak_$(date +%Y%m%d%H%M%S)"
        echo "options thinkpad_acpi fan_control=1" >> "$ACPI_CONF"
        log_event "Updated $ACPI_CONF with 'fan_control=1'. Please reboot for changes to take effect."
    else
        log_event "$ACPI_CONF is correctly configured with fan_control=1."
    fi
else
    log_event "$ACPI_CONF not found. Creating configuration file."
    echo "options thinkpad_acpi fan_control=1" > "$ACPI_CONF"
    log_event "Created $ACPI_CONF. Please reboot for changes to take effect."
fi

# Ensure the kernel boot parameter is set for a permanent configuration.
GRUB_CONF="/etc/default/grub"
if grep -q "thinkpad_acpi.fan_control=1" "$GRUB_CONF"; then
    log_event "GRUB configuration already contains thinkpad_acpi.fan_control=1."
else
    log_event "Adding thinkpad_acpi.fan_control=1 to GRUB_CMDLINE_LINUX in $GRUB_CONF."
    # Append the parameter to the existing GRUB_CMDLINE_LINUX line.
    sed -i 's/^\(GRUB_CMDLINE_LINUX="\(.*\)\)"/\1 thinkpad_acpi.fan_control=1"/' "$GRUB_CONF"
    log_event "Updated GRUB configuration. Running update-grub..."
    update-grub
fi

# Check if thinkpad_acpi is loaded as a module.
if lsmod | grep -q "^thinkpad_acpi"; then
    echo "Reloading thinkpad_acpi module to apply fan_control option..."
    modprobe -r thinkpad_acpi && modprobe thinkpad_acpi
    sleep 2
    # Re-read fan control value after module reload.
    fan_control_value=$(cat /sys/module/thinkpad_acpi/parameters/fan_control 2>/dev/null || echo "unknown")
else
    echo "thinkpad_acpi module is not loadable (possibly built into the kernel)."
    echo "Please reboot for changes to take effect."
fi

# Optional: verify that fan_control is enabled.
if [ "$fan_control_value" = "Y" ] || [ "$fan_control_value" = "1" ]; then
    echo "Fan control enabled. Current /proc/acpi/ibm/fan output:"
    cat /proc/acpi/ibm/fan
else
    echo "Fan control is not enabled. Check your configuration."
fi

# Write the thinkfan-ex script into /usr/local/bin.
cat > "$THINKFAN_EX_SCRIPT" << 'EOF'
#!/bin/bash
# thinkfan-ex: Fan control script for ThinkPads based on temperature thresholds.
#
# This script adjusts the fan level by writing commands to /proc/acpi/ibm/fan.
# It dynamically detects temperature sensor files, maps temperature thresholds
# to fan levels, and switches to "level disengaged" (maximum fan speed) when a critical
# temperature is exceeded.
#
# Additionally, this script supports command-line options:
#   -status   : Display current fan status and temperature readings.
#   -uninstall: Remove the thinkfan-ex script, disable its systemd service,
#               revert the GRUB boot parameter change, and remove the bash completion file.
#
# Requirements:
#   - thinkpad_acpi must be loaded with fan_control=1.
#   - Run as root.
#
# The script restores automatic control ("level auto") on exit.
#
# Author: [Your Name]
# Date: 2025-03-10

set -euo pipefail

FAN_CONTROL_FILE="/proc/acpi/ibm/fan"
LOG_FILE="/var/log/thinkfan-extreme.log"

# Log event function: defined early for use in configuration debugging.
log_event() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# === Configuration File Handling ===
CONFIG_FILE="/etc/thinkfan-extreme.conf"

DEFAULT_CONFIG_CONTENT=$(cat <<'EOC'
# Example of how to set up your config file

# Critical temperature in millidegrees Celsius (75000 = 75°C)
#CRITICAL_TEMP=75000

# Temperature thresholds for each fan level (in millidegrees Celsius).
#declare -A level_threshold
#level_threshold[0]=40000
#level_threshold[1]=45000
#level_threshold[2]=50000
#level_threshold[3]=55000
#level_threshold[4]=60000
#level_threshold[5]=65000
#level_threshold[6]=70000
#level_threshold[7]=75000



# Critical temperature in millidegrees Celsius. TjMax on this CPU is 100C;
# measured full-load package temp post-repaste is 74C, so disengaged is a
# genuine emergency rung, not a normal operating point.
CRITICAL_TEMP=90000

# Downshift stickiness in millidegrees. Must be >= the gap between thresholds
# or the level flaps on every crossing.
HYSTERESIS=5000

# Temperature thresholds for each fan level (in millidegrees Celsius).
declare -A level_threshold
level_threshold[0]=45000
level_threshold[1]=50000
level_threshold[2]=55000
level_threshold[3]=60000
level_threshold[4]=65000
level_threshold[5]=70000
level_threshold[6]=78000
level_threshold[7]=85000
EOC
)

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file not found. Creating default configuration file at $CONFIG_FILE."
    echo "$DEFAULT_CONFIG_CONTENT" > "$CONFIG_FILE"
fi

if ! bash -n "$CONFIG_FILE" 2>/dev/null; then
    echo "Error: Configuration file $CONFIG_FILE has syntax errors. Falling back to default configuration." >&2
    CRITICAL_TEMP=90000
    HYSTERESIS=5000
    declare -A level_threshold
    level_threshold[0]=45000
    level_threshold[1]=50000
    level_threshold[2]=55000
    level_threshold[3]=60000
    level_threshold[4]=65000
    level_threshold[5]=70000
    level_threshold[6]=78000
    level_threshold[7]=85000
else
    . "$CONFIG_FILE"
fi
# === End of Configuration File Handling ===

# --- Debug Logging: Verify configuration values ---
log_event "DEBUG: CRITICAL_TEMP is set to $CRITICAL_TEMP"
for key in "${!level_threshold[@]}"; do
    log_event "DEBUG: level_threshold[$key] = ${level_threshold[$key]}"
done
# --- End Debug Logging ---

# Command-line option handling.
if [ "$#" -gt 0 ]; then
    case "$1" in
        -status)
            echo "Current fan control file contents:"
            cat "$FAN_CONTROL_FILE"
            echo "Current temperature readings from sensors:"
            sensor_files=( "/sys/devices/platform/coretemp.0/hwmon/hwmon*/temp*_input" \
                           "/sys/class/hwmon/hwmon*/temp*_input" \
                           "/sys/class/thermal/thermal_zone*/temp" )
            for pattern in "${sensor_files[@]}"; do
                for file in $pattern; do
                    if [ -f "$file" ]; then
                        echo "$file: $(cat "$file" 2>/dev/null)"
                    fi
                done
            done
            exit 0
            ;;
        -config)
            if [ ! -f "$CONFIG_FILE" ]; then
                echo "$DEFAULT_CONFIG_CONTENT" > "$CONFIG_FILE"
                chmod 644 "$CONFIG_FILE"
                log_event "Created default config at $CONFIG_FILE"
            fi
            ${EDITOR:-nano} "$CONFIG_FILE"
            exit 0
            ;;

        -uninstall)
            # Ensure this branch is run as root.
            if [ "$EUID" -ne 0 ]; then
                echo "The uninstall option must be run as root. Exiting."
                exit 1
            fi
            echo "Uninstalling Thinkfan-Extreme..."
            systemctl stop thinkfan-extreme.service || true
            systemctl disable thinkfan-extreme.service || true
            rm -f /etc/systemd/system/thinkfan-extreme.service
            systemctl daemon-reload
            rm -f /usr/local/bin/thinkfan-ex
            # Revert GRUB boot parameter change.
            GRUB_CONF="/etc/default/grub"
            if grep -q "thinkpad_acpi.fan_control=1" "$GRUB_CONF"; then
                echo "Reverting GRUB configuration..."
                sed -i 's/ thinkpad_acpi.fan_control=1//' "$GRUB_CONF"
                update-grub
            fi
            # Remove bash completion file if exists.
            if [ -f "/etc/bash_completion.d/thinkfan-ex" ]; then
                rm -f "/etc/bash_completion.d/thinkfan-ex"
            fi
            echo "Uninstallation complete. Please remove any configuration files if desired and reboot."
            exit 0
            ;;
        -help|--help)
            echo "Usage: thinkfan-ex [option]"
            echo "Options:"
            echo "  -status   : Display current fan status and sensor temperature readings."
            echo "  -config   : Create or edit the config file at \$CONFIG_FILE."
            echo "  -uninstall: Uninstall thinkfan-ex, disable its systemd service, revert GRUB changes, and remove bash completion."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -help for usage information."
            exit 1
            ;;
    esac
fi

if [ "$EUID" -ne 0 ]; then
    echo "Must be run as root." >&2
    exit 1
fi

if ! grep -q "enabled" "$FAN_CONTROL_FILE"; then
    log_event "Warning: Fan control file may not be enabled for manual control."
fi

# On exit, restore automatic fan control.
cleanup() {
    log_event "Restoring automatic fan control (level auto)."
    echo "level auto" > "$FAN_CONTROL_FILE" || log_event "Failed to restore automatic mode."
}
trap cleanup EXIT

# Set the fan level.
set_fan_level() {
    local target="$1"
    local current error_code
    # ponytail: grep miss returns 1 and set -e would abort the whole loop
    current=$(grep -m1 "^level:" "$FAN_CONTROL_FILE" 2>/dev/null | awk '{print $2}' || true)
    current=${current:-unknown}

    # ponytail: no-op writes every 3s just spam the log
    if [ "level $current" = "$target" ]; then
        return 0
    fi

    log_event "Attempting to change fan level: $current → $target"
    if printf "%s\n" "$target" > "$FAN_CONTROL_FILE" 2>>"$LOG_FILE"; then
        log_event "Fan level change succeeded: $current → $target"
    else
        error_code=$?
        log_event "Fan level change FAILED: $current → $target (Error: $error_code)"
        log_event "Fan control file details: $(ls -l "$FAN_CONTROL_FILE" 2>/dev/null)"
        log_event "Fan control file contents: $(cat "$FAN_CONTROL_FILE" 2>/dev/null)"
    fi
}

# Function to dynamically detect temperature sensor files and return the highest reading.
get_current_temp() {
    local temp=0
    local sensor_files=()
    local patterns=( "/sys/devices/platform/coretemp.0/hwmon/hwmon*/temp*_input" \
                     "/sys/class/hwmon/hwmon*/temp*_input" \
                     "/sys/class/thermal/thermal_zone*/temp" )
    for pattern in "${patterns[@]}"; do
        for file in $pattern; do
            if [ -f "$file" ]; then
                sensor_files+=("$file")
            fi
        done
    done
    if [ ${#sensor_files[@]} -eq 0 ]; then
        echo 50000
        return
    fi
    for file in "${sensor_files[@]}"; do
        # ponytail: some hwmon nodes return empty (cat exits 0), so ||echo 0 never fires
        value=$(cat "$file" 2>/dev/null || true)
        value=${value:-0}
        if [ "$value" -gt "$temp" ]; then
            temp=$value
        fi
    done
    echo "$temp"
}

# Main loop: read temperature, decide fan level, and set it.
# ponytail: without hysteresis the level flaps on every threshold crossing (audible fan pulsing)
HYSTERESIS=${HYSTERESIS:-5000}
last_level=""
while true; do
    current_temp=$(get_current_temp)

    desired_level="level auto"
    crit=$CRITICAL_TEMP
    [ "$last_level" = "disengaged" ] && crit=$(( CRITICAL_TEMP - HYSTERESIS ))

    if (( current_temp >= crit )); then
        desired_level="level disengaged"
        last_level="disengaged"
    else
        # Collect defined levels and sort them in descending order.
        mapfile -t sorted_levels < <(printf '%s\n' "${!level_threshold[@]}" | sort -rn)

        for level in "${sorted_levels[@]}"; do
            thr=${level_threshold[$level]}
            # Sticky downward: hold the current level until temp falls HYSTERESIS below it.
            if [[ "$last_level" =~ ^[0-9]+$ ]] && (( level <= last_level )); then
                thr=$(( thr - HYSTERESIS ))
            fi
            if (( current_temp >= thr )); then
                desired_level="level $level"
                last_level="$level"
                break
            fi
        done
    fi

    set_fan_level "$desired_level"
    sleep 3
done
EOF

chmod +x "$THINKFAN_EX_SCRIPT"
log_event "Installed thinkfan-ex script to $THINKFAN_EX_SCRIPT."

# Create a systemd service unit file for Thinkfan-Extreme.
cat > "$SYSTEMD_UNIT" << 'EOF'
[Unit]
Description=Thinkfan-Extreme Fan Control Service
After=multi-user.target

[Service]
Type=simple
# Clear the Thinkfan-Extreme log file before starting for a clean session.
ExecStartPre=/bin/sh -c 'echo "" > /var/log/thinkfan-extreme.log'
ExecStart=/usr/local/bin/thinkfan-ex
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

log_event "Created systemd service unit file at $SYSTEMD_UNIT."

# Create bash completion file for thinkfan-ex.
cat > "$COMPLETION_FILE" << 'EOF'
#!/bin/bash
# Bash completion for thinkfan-ex

_thinkfan_ex_completions() {
    local cur opts
    cur="${COMP_WORDS[COMP_CWORD]}"
    opts="-status -config -uninstall -help"
    COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
    return 0
}
complete -F _thinkfan_ex_completions thinkfan-ex
EOF

chmod +x "$COMPLETION_FILE"
log_event "Installed bash completion file to $COMPLETION_FILE."

# Reload systemd daemon and enable the service.
systemctl daemon-reload
systemctl enable --now thinkfan-extreme.service
log_event "Enabled and started thinkfan-extreme.service."

echo "Better reboot the machine for Thinkfan-Extreme to work properly."
log_event "Thinkfan-Extreme deployment complete. Please reboot."
