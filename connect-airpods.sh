#!/usr/bin/env bash

set -euo pipefail
IFS=$' \t\n'

if (( EUID != 0 )); then
  echo "[ERROR] Please run with sudo"
  exit 1
fi

CONF_FILE="/etc/bluetooth/main.conf"
BACKUP_FILE="${CONF_FILE}.orig"

LOGFILE="${LOGFILE:-/root/.cache/connect-airpods.log}"
VERBOSE=0
BACKOFF_DELAY=2
MAX_RETRIES=3
SCAN_TIMEOUT=10
MODE="all"
CONFIG_FILE=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -s, --scan-only         scan and list AirPods; exit
  -v, --verbose           enable debug logging
  --timeout=SECONDS       scan duration (default: $SCAN_TIMEOUT)
  --config=FILE           source additional settings
  -h, --help              show this help and exit
EOF
  exit 1
}

log_info()  { echo "[INFO]  $*" | tee -a "$LOGFILE"; }
log_error() { echo "[ERROR] $*" >&2 | tee -a "$LOGFILE"; }
debug()     { (( VERBOSE )) && echo "[DEBUG] $*" | tee -a "$LOGFILE"; }

if command -v systemctl &>/dev/null; then
  BT_RESTART_CMD=(systemctl restart bluetooth)
else
  BT_RESTART_CMD=(/etc/init.d/bluetooth restart)
fi

cleanup() {
  if [[ -f "$BACKUP_FILE" ]]; then
    log_info "Restoring original Bluetooth config…"
    mv "$BACKUP_FILE" "$CONF_FILE"
    log_info "Restarting Bluetooth service after config restore…"
    "${BT_RESTART_CMD[@]}"
  fi
  debug "Cleaning up…"
  pkill -P $$ bluetoothctl &>/dev/null || true
}
trap cleanup EXIT

while (( $# )); do
  case "$1" in
    -s|--scan-only) MODE="scan-only"; shift ;;
    -v|--verbose)  VERBOSE=1; shift ;;
    --timeout=*)   SCAN_TIMEOUT="${1#*=}"; shift ;;
    --config=*)    CONFIG_FILE="${1#*=}"; shift ;;
    -h|--help)     usage ;;
    *) echo "[ERROR] Unknown option: $1"; usage ;;
  esac
done

if [[ -n "$CONFIG_FILE" ]]; then
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    debug "Sourced config: $CONFIG_FILE"
  else
    log_error "Config file not found: $CONFIG_FILE"
    exit 1
  fi
fi

backup_and_patch_conf() {
  if [[ ! -f "$BACKUP_FILE" ]]; then
    log_info "Backing up $CONF_FILE → $BACKUP_FILE"
    cp "$CONF_FILE" "$BACKUP_FILE"
  else
    debug "Backup already exists, skipping"
  fi

  if grep -Eq '^[[:space:]]*#?[[:space:]]*ControllerMode' "$CONF_FILE"; then
    log_info "Patching existing ControllerMode to 'bredr'"
    sed -i 's|^[[:space:]]*#\?[[:space:]]*ControllerMode.*|ControllerMode = bredr|' "$CONF_FILE"
  else
    log_info "Appending ControllerMode = bredr to end of config"
    echo -e "\nControllerMode = bredr" >> "$CONF_FILE"
  fi
}

restore_conf() {
  if [[ -f "$BACKUP_FILE" ]]; then
    log_info "Restoring original Bluetooth config…"
    mv "$BACKUP_FILE" "$CONF_FILE"
  fi
}

with_retry() {
  local fn=$1; shift
  local attempt=1
  until "$fn" "$@"; do
    (( attempt++ ))
    if (( attempt > MAX_RETRIES )); then
      log_error "'$fn' failed after $MAX_RETRIES attempts."
      return 1
    fi
    log_info "Retry $attempt/$MAX_RETRIES in $BACKOFF_DELAY s…"
    sleep "$BACKOFF_DELAY"
  done
}

restart_bt() {
  log_info "Restarting Bluetooth service…"
  "${BT_RESTART_CMD[@]}"
}

ensure_adapter() {
  log_info "Ensuring Bluetooth adapter is powered…"
  bluetoothctl power on &>/dev/null || debug "Failed to power on adapter"
  set +e
  for i in {1..5}; do
    if bluetoothctl show | grep -q "Powered: yes"; then
      set -euo pipefail
      debug "Adapter is powered."
      return 0
    fi
    debug "Waiting for adapter… ($i/5)"
    sleep 1
  done
  set -euo pipefail
  log_error "Bluetooth adapter is not powered. Aborting."
  exit 1
}

forget_airpods() {
  log_info "Removing any known AirPods from device list…"
  mapfile -t KNOWN < <(bluetoothctl devices | grep -i "AirPod" || true)
  for entry in "${KNOWN[@]}"; do
    mac=$(awk '{print $2}' <<<"$entry")
    name=${entry#*"$mac" }
    log_info "Removing $name ($mac)"
    bluetoothctl remove "$mac" &>/dev/null \
      && debug "Removed $mac" \
      || debug "Failed to remove $mac"
  done
}

scan_airpods() {
  log_info "Scanning for AirPods for $SCAN_TIMEOUT seconds…"
  bluetoothctl scan on &>/dev/null &
  SCAN_PID=$!
  sleep "$SCAN_TIMEOUT"
  bluetoothctl scan off &>/dev/null || debug "scan off failed"
  kill "$SCAN_PID" &>/dev/null || true

  mapfile -t RAW < <(bluetoothctl devices | grep -i "AirPod" || true)
  if (( ${#RAW[@]} == 0 )); then
    log_error "No AirPods devices found."
    exit 1
  fi

  MACS=(); NAMES=()
  for line in "${RAW[@]}"; do
    mac=$(awk '{print $2}' <<<"$line")
    name=${line#*"$mac" }
    MACS+=("$mac")
    NAMES+=("$name")
  done

  echo -e "\nFound AirPods:"
  for i in "${!MACS[@]}"; do
    printf "  [%d] %s  (%s)\n" "$((i+1))" "${MACS[$i]}" "${NAMES[$i]}"
  done
  echo
  [[ "$MODE" == "scan-only" ]] && exit 0

  while true; do
    read -rp "Select device [1-${#MACS[@]}]: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<=${#MACS[@]} )); then
      DEVICE_MAC=${MACS[$((sel-1))]}
      DEVICE_NAME=${NAMES[$((sel-1))]}
      debug "Selected $DEVICE_MAC ($DEVICE_NAME)"
      break
    fi
    echo "Invalid selection."
  done
}

pair_device()  { log_info "Pairing       $DEVICE_MAC…"; bluetoothctl pair  "$DEVICE_MAC"; }
trust_device() { log_info "Trusting      $DEVICE_MAC…"; bluetoothctl trust "$DEVICE_MAC"; }

connect_device() {
  log_info "Connecting    $DEVICE_MAC…"
  bluetoothctl connect "$DEVICE_MAC"
}

main() {
  backup_and_patch_conf
  restart_bt
  ensure_adapter
  forget_airpods
  scan_airpods
  with_retry pair_device
  trust_device
  with_retry connect_device

  restore_conf
  restart_bt

  log_info "✔ Successfully connected to $DEVICE_NAME [$DEVICE_MAC]"
}

main
