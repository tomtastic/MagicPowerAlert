#!/usr/bin/env bash
#
# 1. Save locally, chmod +x <file>
#
# 2. Add a cron entry to run it, for example:
#   30 9 * * * /Users/dougb/MagicPower/MagicPowerAlert.sh
#
# 3. Or, run frequently but set the muting and inactivity vars
#   */30 * * * * /Users/dougb/MagicPower/MagicPowerAlert.sh

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
LOG_PATH="${SCRIPT_PATH}.log"
MUTE_FILE="${SCRIPT_PATH}.mute"

# You can change the default (35) threshold by passing a value as the first argument to the script.
DEFAULT_THRESHOLD=35
THRESHOLD="${1:-$DEFAULT_THRESHOLD}"

# Set to mute consecutive alerts for a period of hours. Makes it practical to schedule
# MagicPowerAlert to run frequently, say every 30 minutes. Really, two alerts per day are
# probably enough of a reminder. So a good value is maybe 4 hours.
MUTE_CONSECUTIVE_ALERTS_HOURS=4

# Inactivity detection. If user is afk, don't continue and possibly spam the desktop with alerts.
# For example, no alerts during the night when running other automated tasks.
INACTIVITY_THRESHOLD_MINS=5

# You can change the message, if coffee is not your thing.
MESSAGE="Get a coffee and charge:"

# You can change the time the alert shows.
DIALOG_TIMEOUT=60

# You can pick an appropriate icon colour if you have Space Gray devices.
SPACE_GRAY=1

# Set to 1 to create a log file for debugging. Log file is ./MagicPowerAlert.sh.log.
LOGFILE=0

MOUSE_LIGHT="/Library/Application Support/Apple/BezelServices/AppleHSBluetooth.plugin/Contents/Resources/Mouse.icns"
MOUSE_DARK="/Library/Application Support/Apple/BezelServices/AppleHSBluetooth.plugin/Contents/Resources/MouseSpaceGray.icns"

messages=()

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME [THRESHOLD]
  $SCRIPT_NAME status
  $SCRIPT_NAME --help

Examples:
  $SCRIPT_NAME 35
  $SCRIPT_NAME status
EOF
}

logger() {
    if [[ $LOGFILE -eq 1 ]]; then
        printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_PATH"
    fi
}

require_commands() {
    local missing=()
    local command

    for command in /usr/sbin/ioreg /usr/bin/xmllint /usr/bin/osascript /usr/bin/stat /usr/bin/touch /bin/rm; do
        [[ -x "$command" ]] || missing+=("$command")
    done

    if (( ${#missing[@]} > 0 )); then
        printf '[!] Missing required command(s): %s\n' "${missing[*]}" >&2
        exit 1
    fi
}

resolve_icon() {
    if [[ $SPACE_GRAY -eq 1 && -f "$MOUSE_DARK" ]]; then
        MOUSE_ICON="$MOUSE_DARK"
    elif [[ -f "$MOUSE_LIGHT" ]]; then
        MOUSE_ICON="$MOUSE_LIGHT"
    elif [[ -f "$MOUSE_DARK" ]]; then
        MOUSE_ICON="$MOUSE_DARK"
    else
        printf '[!] No mouse icons found\n' >&2
        exit 1
    fi
}

parse_args() {
    local arg="${1:-$DEFAULT_THRESHOLD}"

    arg="${arg/\%/}"

    case "$arg" in
        status)
            GET_STATUS=true
            THRESHOLD="$DEFAULT_THRESHOLD"
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            if [[ "$arg" =~ ^[0-9]+$ ]]; then
                if (( arg < 1 || arg > 100 )); then
                    printf '[!] Alert threshold must be between 1%% and 100%%\n' >&2
                    exit 1
                fi
                GET_STATUS=false
                THRESHOLD="$arg"
            else
                printf '[!] Invalid argument: %s\n' "$arg" >&2
                usage >&2
                exit 1
            fi
            ;;
    esac
}

get_inactivity_minutes() {
    local ioreg_idle inactivity inactivity_seconds

    ioreg_idle=$(/usr/sbin/ioreg -k HIDIdleTime -a -r)
    inactivity=$(/usr/bin/xmllint --xpath "
        /plist/
          array/
            dict/
              key[.='HIDIdleTime']/
              following-sibling::*[1]/
                text()" - 2>/dev/null <<< "$ioreg_idle")

    if [[ ! "$inactivity" =~ ^[0-9]+$ ]]; then
        printf '0'
        return
    fi

    inactivity_seconds=$(( inactivity / 1000000000 ))
    printf '%s' $(( inactivity_seconds / 60 ))
}

should_skip_for_inactivity() {
    local inactivity_minutes

    [[ "$GET_STATUS" == true ]] && return 1

    inactivity_minutes="$(get_inactivity_minutes)"
    if (( inactivity_minutes >= INACTIVITY_THRESHOLD_MINS )); then
        logger "skip because of inactivity for ${inactivity_minutes} m [threshold is ${INACTIVITY_THRESHOLD_MINS} m]"
        return 0
    fi

    return 1
}

clear_or_honor_mute() {
    local file_age_in_seconds file_age_in_minutes file_age_in_hours

    [[ "$GET_STATUS" == true ]] && return 1
    [[ -f "$MUTE_FILE" ]] || return 1

    file_age_in_seconds=$(( $(date +%s) - $(/usr/bin/stat -f %m -- "$MUTE_FILE") ))
    file_age_in_minutes=$(( file_age_in_seconds / 60 ))
    file_age_in_hours=$(( file_age_in_minutes / 60 ))

    if (( file_age_in_hours >= MUTE_CONSECUTIVE_ALERTS_HOURS )); then
        logger "removing file $MUTE_FILE"
        /bin/rm -f -- "$MUTE_FILE"
        return 1
    fi

    logger "skip because muting active. file $MUTE_FILE has age ${file_age_in_minutes} m"
    return 0
}

load_device_xml() {
    DEVICE_XML="$({ /usr/sbin/ioreg -r -a -k BatteryPercent 2>/dev/null; } || true)"
}

device_count() {
    /usr/bin/xmllint --xpath "count(//plist/array/dict)" - 2>/dev/null <<< "$DEVICE_XML" || true
}

device_name_at() {
    local device_num="$1"

    /usr/bin/xmllint --xpath "
        /plist/
          array/
            dict[$device_num]/
              key[.='Product']/
              following-sibling::*[1]/
                text()" - 2>/dev/null <<< "$DEVICE_XML" || true
}

device_power_at() {
    local device_num="$1"

    /usr/bin/xmllint --xpath "
        /plist/
          array/
            dict[$device_num]/
              key[.='BatteryPercent']/
              following-sibling::*[1]/
                text()" - 2>/dev/null <<< "$DEVICE_XML" || true
}

device_status_flag_at() {
    local device_num="$1"

    /usr/bin/xmllint --xpath "
        /plist/
          array/
            dict[$device_num]/
              key[.='BatteryStatusFlags']/
              following-sibling::*[1]/
                text()" - 2>/dev/null <<< "$DEVICE_XML" || true
}

collect_messages() {
    local num_devices device_num device power_value status_flag status_suffix

    num_devices="$(device_count)"
    [[ -n "$num_devices" ]] || return 0

    for (( device_num = 1; device_num <= num_devices; device_num++ )); do
        device="$(device_name_at "$device_num")"
        power_value="$(device_power_at "$device_num")"
        status_flag="$(device_status_flag_at "$device_num")"
        status_suffix=""

        [[ -n "$device" ]] || continue

        if [[ "$status_flag" == "3" ]]; then
            status_suffix=" (charging)"
        fi

        [[ "$power_value" =~ ^[0-9]+$ ]] || continue

        if [[ "$GET_STATUS" == true ]]; then
            messages+=("$device at ${power_value}%${status_suffix}")
        elif (( power_value <= THRESHOLD )); then
            messages+=("$device at ${power_value}%")
        fi
    done
}

print_status() {
    local message

    for message in "${messages[@]}"; do
        printf '%s\n' "$message"
    done
}

show_alert() {
    local alert_message message

    alert_message="$MESSAGE"
    for message in "${messages[@]}"; do
        alert_message="${alert_message}\n${message}"
        logger "alerting with $message"
    done

    /usr/bin/touch "$MUTE_FILE"
    logger "created file $MUTE_FILE"

    /usr/bin/osascript -e "
        tell application \"System Events\"
            activate
            display dialog \"$alert_message\" with title \"MagicPowerAlert\" ¬
                buttons \"OK\" default button \"OK\" ¬
                with icon POSIX file \"$MOUSE_ICON\" ¬
                giving up after \"$DIALOG_TIMEOUT\"
        end tell
    " >/dev/null 2>&1
}

main() {
    GET_STATUS=false
    MOUSE_ICON=""
    DEVICE_XML=""

    require_commands
    parse_args "${1:-}"
    resolve_icon

    if should_skip_for_inactivity; then
        exit 0
    fi

    if clear_or_honor_mute; then
        exit 0
    fi

    load_device_xml
    collect_messages

    (( ${#messages[@]} > 0 )) || exit 0

    if [[ "$GET_STATUS" == true ]]; then
        print_status
    else
        show_alert
    fi
}

main "${1:-}"
