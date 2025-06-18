#!/usr/bin/env bash

set -euo pipefail
IFS=$' \t\n'

LOGFILE="${LOGFILE:-$HOME/.cache/connect-airpods.log}"
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

cleanup() {
  debug "Cleaning up…"
  pkill -P $$ bluetoothctl &>/dev/null || true
}
trap cleanup EXIT

if command -v systemctl &>/dev/null; then
  BT_RESTART_CMD=(sudo systemctl restart bluetooth)
else
  BT_RESTART_CMD=(sudo /etc/init.d/bluetooth restart)
fi

while (( $# )); do
  case "$1" in
    -s|--scan-only) MODE="scan-only"; shift ;;
    -v|--verbose)  VERBOSE=1; shift ;;
    --timeout=*)   SCAN_TIMEOUT="${1#*=}"; shift ;;
    --config=*)    CONFIG_FILE="${1#*=}"; shift ;;
    -h|--help)     usage ;;
    *) echo "Unknown option: $1"; usage ;;
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
    out=$(bluetoothctl show 2>/dev/null)
    if grep -q "Powered: yes" <<<"$out"; then
      set -euo pipefail
      debug "Adapter is powered."
      return 0
    fi
    debug "Adapter not powered yet; waiting… ($i/5)"
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
    bluetoothctl remove "$mac" \
      && debug "Removed $mac" \
      || debug "Failed to remove $mac (maybe already gone)"
  done
}

scan_airpods() {
  log_info "Scanning for AirPods for $SCAN_TIMEOUT seconds…"
  bluetoothctl scan on &
  SCAN_PID=$!
  sleep "$SCAN_TIMEOUT"

  if ! bluetoothctl scan off; then
    debug "Warning: failed to stop discovery—continuing anyway"
  fi
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

  echo
  echo "Found AirPods:"
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

pair_device()      { log_info "Pairing       $DEVICE_MAC…";   bluetoothctl pair    "$DEVICE_MAC"; }
trust_device()     { log_info "Trusting      $DEVICE_MAC…";   bluetoothctl trust   "$DEVICE_MAC"; }
disconnect_device(){ log_info "Disconnecting $DEVICE_MAC…";   bluetoothctl disconnect "$DEVICE_MAC" \
                         && debug "Disconnected" \
                         || debug "No prior connection to disconnect"; }
connect_device() {
  log_info "Connecting    $DEVICE_MAC…"
  disconnect_device

  for i in {1..5}; do
    if bluetoothctl info "$DEVICE_MAC" | grep -q "ServicesResolved: yes"; then
      debug "ServicesResolved=yes"
      break
    fi
    debug "Waiting for services to resolve… ($i/5)"
    sleep 1
  done

  bluetoothctl connect "$DEVICE_MAC"
}

main() {
  restart_bt
  ensure_adapter
  forget_airpods
  scan_airpods

  with_retry pair_device
  trust_device
  with_retry connect_device

  log_info "✔ Successfully connected to $DEVICE_NAME [$DEVICE_MAC]"
}

main
