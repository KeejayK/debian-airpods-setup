#!/usr/bin/env bash

set -euo pipefail
IFS=$' \t\n'

### ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

if (( EUID != 0 )); then
  echo -e "${RED}[ERROR]${NC} Please run with sudo"
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

print_header() {
  local title="Apple Airpods Connector"
  local len=${#title}
  local border
  border="$(printf '─%.0s' $(seq 1 $((len+2))))"

  echo -e "${CYAN}┌${border}┐${NC}"
  echo -e "${CYAN}│ ${BOLD}${title}${NC}${CYAN} │${NC}"
  echo -e "${CYAN}└${border}┘${NC}"
}

progress_bar() {
  local duration=$1
  local width=30
  local fill='█'
  local empty='░'
  local bar filled rem percent

  tput civis

  for ((sec=0; sec<=duration; sec++)); do
    if (( sec < duration )); then
      percent=$(( sec * 100 / duration ))
      filled=$(( sec * width / duration ))
      rem=$(( duration - sec ))
      bar=''
      for ((i=0; i<filled; i++)); do bar+="$fill"; done
      for ((i=filled; i<width; i++)); do bar+="$empty"; done
      echo -ne "\r${bar} ${percent}% (eta ${rem}s)"
      sleep 1
    else
      bar=''
      for ((i=0; i<width; i++)); do bar+="$fill"; done
      echo -ne "\r${bar} 100%\n"
    fi
  done

  tput cnorm
}


log_info()  {
  echo -e "${YELLOW}[INFO]${NC} $*"
  echo "[INFO] $*" >> "$LOGFILE"
}
log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  echo "[ERROR] $*" >> "$LOGFILE"
}
debug() {
  if (( VERBOSE )); then
    echo -e "${BLUE}[DEBUG]${NC} $*"
    echo "[DEBUG] $*" >> "$LOGFILE"
  fi
}

if command -v systemctl &>/dev/null; then
  BT_RESTART_CMD=(systemctl restart bluetooth)
else
  BT_RESTART_CMD=(/etc/init.d/bluetooth restart)
fi

cleanup() {
  if [[ -f "$BACKUP_FILE" ]]; then
    log_info "Restoring original Bluetooth config…"
    mv "$BACKUP_FILE" "$CONF_FILE"
    log_info "Restarting Bluetooth service…"
    "${BT_RESTART_CMD[@]}"
  fi
  debug "Cleanup complete"
  pkill -P $$ bluetoothctl &>/dev/null || true
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage: sudo $(basename "$0") [options]

Options:
  -v, --verbose           Enable debug output
  --timeout=SECONDS       Scan duration (default: $SCAN_TIMEOUT)
  --config=FILE           Source additional settings
  -h, --help              Show this help and exit
EOF
  exit 1
}

while (( $# )); do
  case "$1" in
    -v|--verbose)  VERBOSE=1; shift ;;
    --timeout=*)   SCAN_TIMEOUT="${1#*=}"; shift ;;
    --config=*)    CONFIG_FILE="${1#*=}"; shift ;;
    -h|--help)     usage ;;
    *) log_error "Unknown option: $1"; usage ;;
  esac
done

if [[ -n "$CONFIG_FILE" ]]; then
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    debug "Loaded config from $CONFIG_FILE"
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
    log_info "Setting ControllerMode = bredr"
    sed -i 's|^[[:space:]]*#\?[[:space:]]*ControllerMode.*|ControllerMode = bredr|' "$CONF_FILE"
  else
    log_info "Appending ControllerMode = bredr"
    echo -e "\nControllerMode = bredr" >> "$CONF_FILE"
  fi
}

restore_conf() {
  if [[ -f "$BACKUP_FILE" ]]; then
    log_info "Restoring ControllerMode to original"
    mv "$BACKUP_FILE" "$CONF_FILE"
  fi
}

with_retry() {
  local fn=$1; shift
  local attempt=1
  until "$fn" "$@"; do
    (( attempt++ ))
    if (( attempt > MAX_RETRIES )); then
      log_error "'$fn' failed after $MAX_RETRIES attempts"
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
  log_info "Powering on Bluetooth adapter…"
  bluetoothctl power on &>/dev/null || debug "power on failed"
  set +e
  for i in {1..5}; do
    if bluetoothctl show | grep -q "Powered: yes"; then
      set -euo pipefail
      debug "Adapter is powered"
      return 0
    fi
    debug "Waiting for adapter… ($i/5)"
    sleep 1
  done
  set -euo pipefail
  log_error "Bluetooth adapter not powered — aborting"
  exit 1
}

bt_clean() {
  if (( VERBOSE )); then
    bluetoothctl "$@"
  else
    bluetoothctl "$@" 2>&1 | grep --line-buffered -v '^\['
  fi
}

forget_airpods() {
  log_info "Forgetting any known AirPods…"
  mapfile -t KNOWN < <(bluetoothctl devices | grep -i "AirPod" || true)
  for entry in "${KNOWN[@]}"; do
    mac=$(awk '{print $2}' <<<"$entry")
    name=${entry#*"$mac" }
    log_info "  → Removing $name ($mac)"
    bt_clean remove "$mac"
  done
}

scan_airpods() {
  log_info "Scanning for AirPods (${SCAN_TIMEOUT}s)…"
  echo
  bluetoothctl scan on &>/dev/null &
  SCAN_PID=$!
  progress_bar "$SCAN_TIMEOUT"
  bluetoothctl scan off &>/dev/null || debug "scan off failed"
  kill "$SCAN_PID" &>/dev/null || true

  mapfile -t RAW < <(bluetoothctl devices | grep -i "AirPod" || true)
  if (( ${#RAW[@]} == 0 )); then
    log_error "No AirPods found"
    exit 1
  fi

  MACS=(); NAMES=()
  for entry in "${RAW[@]}"; do
    mac=$(awk '{print $2}' <<<"$entry")
    name=${entry#*"$mac" }
    MACS+=("$mac")
    NAMES+=("$name")
  done

  echo -e "\n${YELLOW}Found AirPods:${NC}"
  for i in "${!MACS[@]}"; do
    printf "  [%d] %s (%s)\n" "$((i+1))" "${MACS[$i]}" "${NAMES[$i]}"
  done
  echo

  while true; do
    read -rp "Select device [1-${#MACS[@]}]: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<=${#MACS[@]} )); then
      DEVICE_MAC=${MACS[$((sel-1))]}
      DEVICE_NAME=${NAMES[$((sel-1))]}
      debug "Selected $DEVICE_NAME ($DEVICE_MAC)"
      break
    fi
    echo -e "${RED}Invalid selection.${NC}"
  done
}

pair_device()  {
  log_info "Pairing ${DEVICE_NAME}…"
  bt_clean pair "$DEVICE_MAC"
}
trust_device() {
  log_info "Trusting ${DEVICE_NAME}…"
  bt_clean trust "$DEVICE_MAC"
}
connect_device() {
  log_info "Connecting ${DEVICE_NAME}…"
  bt_clean connect "$DEVICE_MAC"
}

main() {
  print_header
  echo "The following script connects Apple Airpods to Linux (Debian/Ubuntu/Mint):"
  echo "    - Automates changing the controller mode temporarily to enable BR/EDR only mode"
  echo "    - Scans and connects to any available Airpods,"
  echo "    - Changes the controller mode back to what it was before (dual by default)."
  echo
  read -rp "Press ENTER to continue or Ctrl-C to abort…"

  echo -e "Please follow the instructions:"
  echo -e "   1. Put both AirPods in the case"
  echo -e "   2. Keep the lid open"
  echo -e "   3. Press and hold the rear button until the LED blinks white."
  echo -e "Please remember to CONTINUE HOLDING the button THROUGHOUT the scan"
  echo
  read -rp "Then press ENTER to start the scan…"

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

  echo -e "${GREEN}${BOLD}  [✔]  Finished:${NC} Your AirPods (${DEVICE_NAME}) are now connected."
}

main
