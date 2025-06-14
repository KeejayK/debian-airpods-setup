#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/bluetooth/main.conf"


# forget saved airpods
echo "🗑️  Forgetting any saved AirPods..."
bluetoothctl devices | while read -r _ mac name; do
  if [[ "$name" == *AirPods* ]]; then
    echo "   • Removing $mac ($name)"
    bluetoothctl remove "$mac" || true
  fi
done

# swap ControllerMode = bredr 
if ! grep -q '^ControllerMode = bredr' "$CONF"; then
  echo "☑️  Setting ControllerMode = bredr in $CONF (requires sudo)..."
  sudo sed -i 's|#ControllerMode = dual|ControllerMode = bredr|' "$CONF"
fi

# restart bluetooth
echo "🔄  Restarting bluetooth.service..."
sudo systemctl restart bluetooth

# scan for airpods
echo "🔍  Scanning for AirPods (10s)..."
MAC=$(bluetoothctl --timeout 10 scan on \
    | grep --line-buffered -m1 'AirPods' \
    | awk '{print $2}')

if [[ -z "$MAC" ]]; then
  echo "❌  No AirPods found. Put them in pairing mode (White LED blinking) and retry."
  exit 1
fi
echo "✅  Found AirPods: $MAC"

# pair
echo "🤝  Pairing, trusting, and connecting..."
bluetoothctl <<EOF
power on
agent on
default-agent
pair $MAC
trust $MAC
connect $MAC
quit
EOF

echo "Done: AirPods connected"
